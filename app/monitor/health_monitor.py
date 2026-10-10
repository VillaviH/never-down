"""
Never Down — AI Health Monitor (AWS Lambda, cada 60s)

El cerebro del DRP. Cada ciclo:
  1. Sondea la salud de AWS (primario) y GCP (standby) — probes HTTP + CloudWatch.
  2. Le pregunta a Amazon Bedrock (Claude) si debe hacer failover — con razonamiento.
  3. Si Bedrock decide FAILOVER (sostenido y con confianza), cambia los pesos de
     Route 53 (AWS=0, GCP=100) vía API, registra la decisión y avisa por SNS.

No usa reglas booleanas rígidas: Bedrock analiza el contexto como lo haría un SRE.
"""

import json
import os
import time
import urllib.request
import urllib.error
from datetime import datetime, timedelta, timezone

import boto3

REGION       = os.environ.get("AWS_REGION", "us-east-1")
MODEL_ID     = os.environ["BEDROCK_MODEL_ID"]
ZONE         = os.environ["HOSTED_ZONE_ID"]
FRONT_DOMAIN = os.environ["FRONT_DOMAIN"]
API_DOMAIN   = os.environ["API_DOMAIN"]
AWS_HEALTH   = os.environ["AWS_HEALTH_URL"]   # endpoint directo AWS (siempre AWS)
GCP_HEALTH   = os.environ["GCP_HEALTH_URL"]   # endpoint directo GCP (siempre GCP)
TABLE        = os.environ["MONITOR_TABLE"]
SNS_TOPIC    = os.environ.get("SNS_TOPIC_ARN", "")
APP_FN       = os.environ.get("APP_FUNCTION_NAME", "never-down-app")
AUTO         = os.environ.get("AUTO_FAILOVER", "true").lower() == "true"
CONF_MIN     = float(os.environ.get("CONFIDENCE_MIN", "0.8"))
SUSTAINED    = int(os.environ.get("SUSTAINED_CYCLES", "2"))

bedrock  = boto3.client("bedrock-runtime", region_name=REGION)
route53  = boto3.client("route53")
cw       = boto3.client("cloudwatch", region_name=REGION)
sns      = boto3.client("sns", region_name=REGION)
_table   = boto3.resource("dynamodb").Table(TABLE)


# --------------------------------------------------------------------------- #
# Recolección de salud
# --------------------------------------------------------------------------- #
def probe(url):
    t0 = time.time()
    try:
        req = urllib.request.Request(url, headers={"Cache-Control": "no-cache"})
        with urllib.request.urlopen(req, timeout=5) as r:
            body = r.read().decode()
            ms = int((time.time() - t0) * 1000)
            served = None
            try:
                served = json.loads(body).get("served_by")
            except Exception:  # noqa: BLE001
                pass
            return {"ok": r.status == 200, "status": r.status, "latency_ms": ms, "served_by": served}
    except urllib.error.HTTPError as e:
        return {"ok": False, "status": e.code, "latency_ms": int((time.time() - t0) * 1000), "error": f"HTTP {e.code}"}
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "status": 0, "latency_ms": int((time.time() - t0) * 1000), "error": str(e)[:120]}


def lambda_metrics():
    end = datetime.now(timezone.utc)
    start = end - timedelta(minutes=5)

    def total(metric):
        r = cw.get_metric_statistics(
            Namespace="AWS/Lambda", MetricName=metric,
            Dimensions=[{"Name": "FunctionName", "Value": APP_FN}],
            StartTime=start, EndTime=end, Period=300, Statistics=["Sum"],
        )
        return int(sum(d["Sum"] for d in r.get("Datapoints", [])))

    inv = total("Invocations")
    err = total("Errors")
    thr = total("Throttles")
    denom = inv + thr
    rate = round(100.0 * (err + thr) / denom, 1) if denom > 0 else 0.0
    return {"invocations": inv, "errors": err, "throttles": thr, "error_rate_pct": rate}


# --------------------------------------------------------------------------- #
# Estado / historia (DynamoDB)
# --------------------------------------------------------------------------- #
def get_state():
    r = _table.get_item(Key={"pk": "state", "ts": 0})
    return r.get("Item", {"pk": "state", "ts": 0, "current": "aws", "last_failover_ts": 0})


def put_state(current, last_failover_ts):
    _table.put_item(Item={"pk": "state", "ts": 0, "current": current, "last_failover_ts": last_failover_ts})


def recent_cycles(limit=5):
    r = _table.query(
        KeyConditionExpression=boto3.dynamodb.conditions.Key("pk").eq("cycle"),
        ScanIndexForward=False, Limit=limit,
    )
    return r.get("Items", [])


def log_cycle(item):
    item["pk"] = "cycle"
    item["ts"] = int(time.time() * 1000)
    # TTL de 7 días para no acumular
    item["expires"] = int(time.time()) + 7 * 86400
    _table.put_item(Item=item)


# --------------------------------------------------------------------------- #
# Bedrock: la decisión con razonamiento
# --------------------------------------------------------------------------- #
def ask_bedrock(aws_h, gcp_h, metrics, state, bad_streak):
    last_fo = state.get("last_failover_ts", 0)
    mins_since_fo = int((time.time() - last_fo) / 60) if last_fo else 9999

    prompt = f"""Eres el sistema de recuperación ante desastres (DRP) de "Café Quetzal", una aplicación crítica en producción. AWS es el cloud primario y GCP el standby tibio. Tu trabajo es decidir si hay que ejecutar failover del tráfico de AWS a GCP.

## Salud de AWS (primario)
- Probe /health: ok={aws_h['ok']}, status_http={aws_h['status']}, latencia={aws_h['latency_ms']}ms {('- error: ' + aws_h['error']) if aws_h.get('error') else ''}
- Lambda (últimos 5 min): invocaciones={metrics['invocations']}, errores={metrics['errors']}, throttles={metrics['throttles']}, tasa_error={metrics['error_rate_pct']}%

## Salud de GCP (standby)
- Probe /health: ok={gcp_h['ok']}, status_http={gcp_h['status']}, latencia={gcp_h['latency_ms']}ms

## Contexto histórico
- Tráfico sirviéndose actualmente desde: {state.get('current', 'aws')}
- Ciclos consecutivos con AWS no-saludable: {bad_streak}
- Minutos desde el último failover: {mins_since_fo}

## Reglas de decisión
- FAILOVER solo si AWS está claramente caído o gravemente degradado de forma SOSTENIDA (>= {SUSTAINED} ciclos) Y GCP está healthy.
- DEGRADED si hay señales preocupantes pero aún no confirmadas.
- OK si todo está dentro de parámetros normales.
- Evita el flapping: si hubo un failover hace pocos minutos, sé conservador.

Responde EXCLUSIVAMENTE con un objeto JSON válido, sin texto adicional:
{{"decision": "OK|DEGRADED|FAILOVER", "confidence": 0.0-1.0, "reasoning": "máximo 2 oraciones en español"}}"""

    body = {
        "messages": [{"role": "user", "content": [{"text": prompt}]}],
        "inferenceConfig": {"maxTokens": 300, "temperature": 0.0},
    }
    resp = bedrock.invoke_model(modelId=MODEL_ID, body=json.dumps(body))
    payload = json.loads(resp["body"].read())
    text = payload["output"]["message"]["content"][0]["text"].strip()
    # Extraer el JSON aunque venga con texto alrededor
    start = text.find("{")
    end = text.rfind("}")
    decision = json.loads(text[start:end + 1])
    return decision


# --------------------------------------------------------------------------- #
# Ejecución del failover (cambio de pesos en Route 53)
# --------------------------------------------------------------------------- #
def set_weights(aws_weight, gcp_weight):
    for name in (FRONT_DOMAIN, API_DOMAIN):
        resp = route53.list_resource_record_sets(
            HostedZoneId=ZONE, StartRecordName=name + ".", StartRecordType="A", MaxItems="10"
        )
        changes = []
        for rr in resp["ResourceRecordSets"]:
            if rr["Name"].rstrip(".") == name and rr.get("Type") == "A" and "SetIdentifier" in rr:
                rr["Weight"] = aws_weight if rr["SetIdentifier"] == "aws" else gcp_weight
                changes.append({"Action": "UPSERT", "ResourceRecordSet": rr})
        if changes:
            route53.change_resource_record_sets(HostedZoneId=ZONE, ChangeBatch={"Changes": changes})


def notify(decision, aws_h, metrics):
    if not SNS_TOPIC:
        return
    sns.publish(
        TopicArn=SNS_TOPIC,
        Subject="🚨 Café Quetzal — FAILOVER ejecutado a GCP",
        Message=(
            f"El AI Monitor ejecutó failover a GCP.\n\n"
            f"Razón (Bedrock): {decision['reasoning']}\n"
            f"Confianza: {decision['confidence']}\n\n"
            f"AWS /health: {aws_h}\n"
            f"AWS error_rate: {metrics['error_rate_pct']}%\n"
        ),
    )


# --------------------------------------------------------------------------- #
# Handler
# --------------------------------------------------------------------------- #
def handler(event, context):
    aws_h = probe(AWS_HEALTH)
    gcp_h = probe(GCP_HEALTH)
    metrics = lambda_metrics()
    state = get_state()

    # racha de ciclos con AWS no saludable (incluye el actual)
    prev = recent_cycles(limit=SUSTAINED - 1) if SUSTAINED > 1 else []
    bad_streak = (0 if aws_h["ok"] else 1) + sum(1 for c in prev if not c.get("aws_ok", True))

    decision = ask_bedrock(aws_h, gcp_h, metrics, state, bad_streak)
    print(f"[BEDROCK] {decision['decision']} (conf {decision['confidence']}) — {decision['reasoning']}")

    executed = False
    current = state.get("current", "aws")

    if (decision["decision"] == "FAILOVER"
            and float(decision["confidence"]) >= CONF_MIN
            and bad_streak >= SUSTAINED
            and gcp_h["ok"]
            and current != "gcp"):
        if AUTO:
            print("[ACTION] Ejecutando failover → GCP (peso AWS=0, GCP=100)")
            set_weights(0, 100)
            put_state("gcp", int(time.time()))
            notify(decision, aws_h, metrics)
            executed = True
        else:
            print("[ACTION] FAILOVER recomendado pero AUTO_FAILOVER=off — no se ejecuta")

    log_cycle({
        "decision": decision["decision"],
        "confidence": str(decision["confidence"]),
        "reasoning": decision["reasoning"],
        "aws_ok": aws_h["ok"],
        "gcp_ok": gcp_h["ok"],
        "aws_latency_ms": aws_h["latency_ms"],
        "error_rate_pct": str(metrics["error_rate_pct"]),
        "bad_streak": bad_streak,
        "executed_failover": executed,
        "serving": "gcp" if executed else current,
    })

    return {"decision": decision["decision"], "executed_failover": executed, "aws_ok": aws_h["ok"], "gcp_ok": gcp_h["ok"]}
