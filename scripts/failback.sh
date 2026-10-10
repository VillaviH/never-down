#!/usr/bin/env bash
# Failback CON reconciliación: copia a DynamoDB los pedidos que entraron en
# Firestore mientras el tráfico estaba en GCP, y RECIÉN DESPUÉS devuelve el
# tráfico a AWS. Así el cliente no "pierde" pedidos al volver al primario.
#
# Úsalo en vez de restore.sh cuando el failover SÍ generó pedidos nuevos en GCP
# (o simplemente siempre, es seguro correrlo aunque no haya nada que reconciliar).
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-default}"
REGION="us-east-1"
# ZONE: hosted zone ID de Route 53 para tu dominio. Ej: export ZONE=Z0123456789ABCDEFGHIJ
ZONE="${ZONE:?Debes exportar ZONE con el hosted zone ID de Route 53 (ver README)}"
# AWS_API_URL: invoke URL del API Gateway. Obtenerlo con:
#   terraform output -raw aws_api_endpoint   (dentro de terraform/)
AWS_API_URL="${AWS_API_URL:?Debes exportar AWS_API_URL con el invoke URL del API Gateway (ver README)}"

echo "1) Reconciliando Firestore → DynamoDB (pedidos creados en GCP)..."
OUT=$(aws lambda invoke --function-name never-down-reconcile --region "$REGION" \
  --cli-binary-format raw-in-base64-out --payload '{}' /tmp/reconcile-out.json)
cat /tmp/reconcile-out.json
echo
python3 -c "
import json
d = json.load(open('/tmp/reconcile-out.json'))
print(f\"   → {d.get('reconciled', 0)} pedido(s) reconciliado(s): {d.get('ids', [])}\")
"

echo
echo "2) Revivir Lambda de la app en AWS..."
aws lambda delete-function-concurrency --function-name never-down-app --region "$REGION" >/dev/null
sleep 2
curl -s -o /dev/null -w "   AWS /health -> HTTP %{http_code}\n" \
  "${AWS_API_URL}/health"

echo "3) Devolver pesos de Route 53 a AWS=100 / GCP=0..."
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
(
  cd "$ROOT/terraform"
  export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token 2>/dev/null)
  terraform apply -auto-approve >/tmp/never-down-failback.log 2>&1
)
echo "   listo (log: /tmp/never-down-failback.log)"

echo "4) Resetear estado del AI Monitor..."
aws dynamodb put-item --table-name never-down-monitor --region "$REGION" \
  --item '{"pk":{"S":"state"},"ts":{"N":"0"},"current":{"S":"aws"},"last_failover_ts":{"N":"0"}}' >/dev/null

echo
echo "✅ Failback completo. Esperando TTL (60s) para confirmar..."
sleep 60
echo "== served_by (debe ser aws) =="
curl -s https://apicafequetzal.hvillavicencio.com/health
echo
echo "== Pedidos en AWS (debe incluir los reconciliados) =="
curl -s https://apicafequetzal.hvillavicencio.com/orders | python3 -c 'import sys, json
d = json.load(sys.stdin)
print("count=" + str(d["count"]))'
