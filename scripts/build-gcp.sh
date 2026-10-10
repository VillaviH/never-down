#!/usr/bin/env bash
# Construye la imagen de Cloud Run (app + front) y la sube a Artifact Registry.
# Arma un contexto de build temporal con main.py, requirements.txt, Dockerfile y web/.
set -euo pipefail

# GCP_PROJECT: tu proyecto GCP. Ej: export GCP_PROJECT=$(gcloud config get-value project)
GCP_PROJECT="${GCP_PROJECT:?Debes exportar GCP_PROJECT con tu proyecto GCP (ver README)}"
PROJECT="$GCP_PROJECT"
REGION="${GCP_REGION:-us-central1}"
REPO="${AR_REPO:-never-down}"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${REPO}/cafe-quetzal:latest"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp "$ROOT/app/gcp/main.py" "$ROOT/app/gcp/requirements.txt" "$ROOT/app/gcp/Dockerfile" "$STAGE/"
mkdir -p "$STAGE/web"
cp "$ROOT/web/index.html" "$STAGE/web/"

echo "🏗️  Building $IMAGE"
gcloud builds submit "$STAGE" --tag "$IMAGE" --project "$PROJECT" --quiet

echo "✅ Imagen lista: $IMAGE"
