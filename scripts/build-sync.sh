#!/usr/bin/env bash
# Construye la imagen de la Lambda de sync (arm64) y la sube a ECR.
set -euo pipefail

PROFILE="${AWS_PROFILE:-default}"
REGION="${AWS_REGION:-us-east-1}"
# ACCOUNT: tu AWS account ID. Ej: export ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ACCOUNT="${ACCOUNT:?Debes exportar ACCOUNT con tu AWS account ID (ver README)}"
REPO="never-down-sync"
IMAGE="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/${REPO}:latest"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "🔐 Login a ECR"
aws ecr get-login-password --region "$REGION" --profile "$PROFILE" \
  | docker login --username AWS --password-stdin "${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

echo "🏗️  Building $IMAGE (linux/arm64)"
docker buildx build --platform linux/arm64 --provenance=false \
  -t "$IMAGE" "$ROOT/app/sync" --push

echo "✅ Imagen lista: $IMAGE"
