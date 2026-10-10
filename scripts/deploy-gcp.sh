#!/usr/bin/env bash
# Sincroniza GCP con los últimos cambios de app/gcp/main.py y/o web/index.html:
# reconstruye la imagen de Cloud Run y la redespliega.
# Usar SIEMPRE después de tocar el frontend (web/index.html) o la app de GCP,
# para que el standby no quede con una versión vieja (nos pasó una vez).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# GCP_PROJECT: tu proyecto GCP. Ej: export GCP_PROJECT=$(gcloud config get-value project)
PROJECT="${GCP_PROJECT:?Debes exportar GCP_PROJECT con tu proyecto GCP (ver README)}"
REGION="${GCP_REGION:-us-central1}"
SERVICE="${CLOUD_RUN_SERVICE:-cafe-quetzal}"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/never-down/cafe-quetzal:latest"

echo "1) Reconstruyendo imagen (main.py + web/index.html)..."
"$ROOT/scripts/build-gcp.sh"

echo "2) Redesplegando Cloud Run..."
gcloud run deploy "$SERVICE" \
  --image "$IMAGE" \
  --region "$REGION" \
  --platform managed \
  --allow-unauthenticated \
  --set-env-vars SERVED_BY=gcp-cloud-run,COLLECTION=never-down-orders \
  --project "$PROJECT" \
  --quiet

echo
echo "3) Verificando..."
URL=$(gcloud run services describe "$SERVICE" --region "$REGION" --project "$PROJECT" --format="value(status.url)")
echo "   Cloud Run URL: $URL"
curl -s "$URL/health"; echo
echo "   API en el front:"
curl -s "$URL/" | grep -o "https://apicafequetzal[a-zA-Z0-9.]*" || echo "   ⚠️  No se encontró la URL de la API en el HTML — revisar web/index.html"

echo
echo "✅ GCP sincronizado."
