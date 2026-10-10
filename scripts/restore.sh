#!/usr/bin/env bash
# Restaura el estado normal tras el demo: revive AWS, vuelve los pesos a AWS=100,
# y resetea el estado del AI Monitor para que pueda decidir un futuro failover.
set -uo pipefail

export AWS_PROFILE="${AWS_PROFILE:-default}"
FN="never-down-app"
REGION="us-east-1"
# ZONE: hosted zone ID de Route 53 para tu dominio. Ej: export ZONE=Z0123456789ABCDEFGHIJ
ZONE="${ZONE:?Debes exportar ZONE con el hosted zone ID de Route 53 (ver README)}"
# AWS_API_URL: invoke URL del API Gateway. Obtenerlo con:
#   terraform output -raw aws_api_endpoint   (dentro de terraform/)
AWS_API_URL="${AWS_API_URL:?Debes exportar AWS_API_URL con el invoke URL del API Gateway (ver README)}"

echo "1) Revivir Lambda de la app..."
aws lambda delete-function-concurrency --function-name "$FN" --region "$REGION" >/dev/null
sleep 2
curl -s -o /dev/null -w "   AWS /health -> HTTP %{http_code}\n" \
  "${AWS_API_URL}/health"

echo "2) Devolver pesos de Route 53 a AWS=100 / GCP=0..."
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
(
  cd "$ROOT/terraform"
  export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token 2>/dev/null)
  terraform apply -auto-approve >/tmp/never-down-restore.log 2>&1
)
echo "   listo (log: /tmp/never-down-restore.log)"

echo "3) Resetear estado del AI Monitor..."
aws dynamodb put-item --table-name never-down-monitor --region "$REGION" \
  --item '{"pk":{"S":"state"},"ts":{"N":"0"},"current":{"S":"aws"},"last_failover_ts":{"N":"0"}}' >/dev/null

echo
echo "✅ Restaurado. Esperando TTL (60s) para confirmar..."
sleep 60
echo "== served_by (debe ser aws) =="
curl -s https://apicafequetzal.hvillavicencio.com/health
echo
