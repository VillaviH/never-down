#!/usr/bin/env bash
# Configura Workload Identity Federation en GCP para que la Lambda de sync de AWS
# escriba en Firestore SIN llaves. Idempotente-ish: re-ejecutar puede dar errores
# "already exists" que se pueden ignorar.
set -uo pipefail

# PROJECT / PROJECT_NUMBER / AWS_ACCOUNT: valores de tu propio proyecto GCP y cuenta AWS.
# Ej: export PROJECT=mi-proyecto-gcp
#     export PROJECT_NUMBER=$(gcloud projects describe mi-proyecto-gcp --format='value(projectNumber)')
#     export AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
PROJECT="${PROJECT:?Debes exportar PROJECT con tu proyecto GCP (ver README)}"
PROJECT_NUMBER="${PROJECT_NUMBER:?Debes exportar PROJECT_NUMBER con el número de tu proyecto GCP (ver README)}"
AWS_ACCOUNT="${AWS_ACCOUNT:?Debes exportar AWS_ACCOUNT con tu AWS account ID (ver README)}"
POOL="never-down-aws"
PROVIDER="aws-lambda"
SA="never-down-sync@${PROJECT}.iam.gserviceaccount.com"
SYNC_ROLE="never-down-sync-role"   # nombre EXACTO del rol IAM de la Lambda en AWS

echo "1) Workload Identity Pool"
gcloud iam workload-identity-pools create "$POOL" --location=global \
  --display-name="Never Down AWS" --project "$PROJECT" || true

echo "2) Provider AWS en el pool"
gcloud iam workload-identity-pools providers create-aws "$PROVIDER" \
  --location=global --workload-identity-pool="$POOL" \
  --account-id="$AWS_ACCOUNT" \
  --attribute-mapping="google.subject=assertion.arn,attribute.aws_role=assertion.arn.contains('assumed-role') ? assertion.arn.extract('{account_arn}assumed-role/') + 'assumed-role/' + assertion.arn.extract('assumed-role/{role_name}/') : assertion.arn" \
  --project "$PROJECT" || true

echo "3) Service account de sync"
gcloud iam service-accounts create never-down-sync \
  --display-name="Never Down sync (AWS→Firestore)" --project "$PROJECT" || true

echo "4) Permiso de escritura en Firestore (datastore.user)"
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:${SA}" --role="roles/datastore.user" --condition=None

echo "5) Permitir que el rol de la Lambda impersone la SA (workloadIdentityUser)"
gcloud iam service-accounts add-iam-policy-binding "$SA" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.aws_role/arn:aws:sts::${AWS_ACCOUNT}:assumed-role/${SYNC_ROLE}" \
  --project "$PROJECT"

echo "6) Generar cred-config (sin secretos) para la Lambda"
gcloud iam workload-identity-pools create-cred-config \
  "projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}" \
  --service-account="$SA" --aws \
  --output-file="$(dirname "$0")/../app/sync/gcp-cred-config.json"

echo "✅ WIF configurado."
