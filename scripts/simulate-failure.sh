#!/usr/bin/env bash
# Mata la Lambda de la app en AWS (reserved-concurrent-executions=0).
# Simula una caída total del compute primario. El AI Monitor lo detectará
# en 1-2 ciclos (60-120s) y decidirá el failover.
set -euo pipefail

export AWS_PROFILE=hvillavicencio
FN="never-down-app"
REGION="us-east-1"
# AWS_API_URL: invoke URL del API Gateway. Obtenerlo con:
#   terraform output -raw aws_api_endpoint   (dentro de terraform/)
AWS_API_URL="${AWS_API_URL:?Debes exportar AWS_API_URL con el invoke URL del API Gateway (ver README)}"

echo "💀 Matando $FN (concurrencia=0)..."
aws lambda put-function-concurrency \
  --function-name "$FN" --reserved-concurrent-executions 0 \
  --region "$REGION" >/dev/null

echo "✅ AWS 'caído'. Verificando..."
sleep 2
curl -s -o /dev/null -w "   AWS /health directo -> HTTP %{http_code}\n" \
  "${AWS_API_URL}/health"

echo
echo "⏱️  El AI Monitor corre cada 60s y necesita 2 ciclos sostenidos para actuar."
echo "   Corre ./scripts/watch.sh en otra terminal para ver el cambio en vivo."
