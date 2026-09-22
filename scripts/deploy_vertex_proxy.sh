#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROJECT_ID="${RESAI_VERTEX_PROJECT_ID:?Set RESAI_VERTEX_PROJECT_ID to your GCP project ID}"
PROJECT_NUMBER="${RESAI_GCP_PROJECT_NUMBER:?Set RESAI_GCP_PROJECT_NUMBER to your GCP project number}"
REGION="${RESAI_CLOUD_RUN_REGION:-asia-northeast1}"
VERTEX_LOCATION="${RESAI_VERTEX_LOCATION:-global}"
VERTEX_MODEL="${RESAI_VERTEX_MODEL:-gemini-3.5-flash}"
SERVICE_NAME="${RESAI_CLOUD_RUN_SERVICE:?Set RESAI_CLOUD_RUN_SERVICE to your Cloud Run service name}"
SERVICE_ACCOUNT_NAME="${RESAI_CLOUD_RUN_SA:?Set RESAI_CLOUD_RUN_SA to your service account name}"
SECRET_NAME="${RESAI_PROXY_SECRET_NAME:?Set RESAI_PROXY_SECRET_NAME to your Secret Manager secret name}"
SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
APP_BUNDLE_ID="ai.res.resai"
DRY_RUN="${RESAI_DRY_RUN:-0}"
PENDING_PROXY_SECRET=""

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

need_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

service_enabled() {
  gcloud services list \
    --enabled \
    --project "$PROJECT_ID" \
    --filter "config.name=$1" \
    --format "value(config.name)" | grep -qx "$1"
}

enable_service_once() {
  local api="$1"
  if service_enabled "$api"; then
    echo "API already enabled: $api"
  else
    echo "Enabling API: $api"
    run gcloud services enable "$api" --project "$PROJECT_ID"
  fi
}

iam_binding_exists() {
  local role="$1"
  local member="$2"
  gcloud projects get-iam-policy "$PROJECT_ID" \
    --flatten "bindings[].members" \
    --filter "bindings.role=$role AND bindings.members=$member" \
    --format "value(bindings.members)" | grep -qx "$member"
}

ensure_project_iam_binding() {
  local role="$1"
  local member="$2"
  if iam_binding_exists "$role" "$member"; then
    echo "IAM binding already exists: $role $member"
  else
    echo "Adding IAM binding: $role $member"
    run gcloud projects add-iam-policy-binding "$PROJECT_ID" \
      --member "$member" \
      --role "$role" \
      --condition=None \
      --quiet >/dev/null
  fi
}

secret_binding_exists() {
  local member="$1"
  gcloud secrets get-iam-policy "$SECRET_NAME" \
    --project "$PROJECT_ID" \
    --flatten "bindings[].members" \
    --filter "bindings.role=roles/secretmanager.secretAccessor AND bindings.members=$member" \
    --format "value(bindings.members)" | grep -qx "$member"
}

ensure_secret_accessor() {
  local member="$1"
  if ! gcloud secrets describe "$SECRET_NAME" --project "$PROJECT_ID" >/dev/null 2>&1; then
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "[dry-run] Secret accessor binding would be added after secret creation: $member"
      return
    fi
  fi

  if secret_binding_exists "$member"; then
    echo "Secret accessor binding already exists: $member"
  else
    echo "Adding secret accessor binding: $member"
    run gcloud secrets add-iam-policy-binding "$SECRET_NAME" \
      --project "$PROJECT_ID" \
      --member "$member" \
      --role "roles/secretmanager.secretAccessor" \
      --quiet >/dev/null
  fi
}

ensure_secret() {
  local secret_value=""
  if gcloud secrets describe "$SECRET_NAME" --project "$PROJECT_ID" >/dev/null 2>&1; then
    echo "Secret already exists: $SECRET_NAME"
    if [[ "${RESAI_ROTATE_PROXY_SECRET:-0}" == "1" ]]; then
      secret_value="${RESAI_PROXY_SHARED_SECRET:-$(openssl rand -hex 32)}"
      echo "Adding new secret version for: $SECRET_NAME"
      if [[ "$DRY_RUN" == "1" ]]; then
        echo "[dry-run] gcloud secrets versions add $SECRET_NAME --data-file=-"
      else
        printf '%s' "$secret_value" | gcloud secrets versions add "$SECRET_NAME" \
          --project "$PROJECT_ID" \
          --data-file=- >/dev/null
      fi
    fi
  else
    secret_value="${RESAI_PROXY_SHARED_SECRET:-$(openssl rand -hex 32)}"
    echo "Creating secret: $SECRET_NAME"
    run gcloud secrets create "$SECRET_NAME" \
      --project "$PROJECT_ID" \
      --replication-policy="automatic" >/dev/null
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "[dry-run] gcloud secrets versions add $SECRET_NAME --data-file=-"
    else
      printf '%s' "$secret_value" | gcloud secrets versions add "$SECRET_NAME" \
        --project "$PROJECT_ID" \
        --data-file=- >/dev/null
    fi
  fi

  if [[ -n "$secret_value" && "$DRY_RUN" != "1" ]]; then
    # Keep the new value in memory only. Do not update the local app until the
    # Cloud Run deployment has completed successfully.
    PENDING_PROXY_SECRET="$secret_value"
  fi
}

need_command gcloud
need_command openssl

echo "Target project: $PROJECT_ID ($PROJECT_NUMBER)"
echo "Cloud Run service: $SERVICE_NAME / $REGION"
echo "Service account: $SERVICE_ACCOUNT_EMAIL"
echo "Secret: $SECRET_NAME"

run gcloud config set project "$PROJECT_ID" >/dev/null

enable_service_once "run.googleapis.com"
enable_service_once "cloudbuild.googleapis.com"
enable_service_once "artifactregistry.googleapis.com"
enable_service_once "aiplatform.googleapis.com"
enable_service_once "secretmanager.googleapis.com"

if gcloud iam service-accounts describe "$SERVICE_ACCOUNT_EMAIL" --project "$PROJECT_ID" >/dev/null 2>&1; then
  echo "Service account already exists: $SERVICE_ACCOUNT_EMAIL"
else
  echo "Creating service account: $SERVICE_ACCOUNT_EMAIL"
  run gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" \
    --project "$PROJECT_ID" \
    --display-name "ResponseAi Vertex Proxy" >/dev/null
fi

ensure_project_iam_binding "roles/aiplatform.user" "serviceAccount:${SERVICE_ACCOUNT_EMAIL}"
ensure_secret
ensure_secret_accessor "serviceAccount:${SERVICE_ACCOUNT_EMAIL}"

DEPLOY_ARGS=(
  run deploy "$SERVICE_NAME"
  --project "$PROJECT_ID"
  --region "$REGION"
  --source "$ROOT_DIR/services/vertex-proxy"
  --service-account "$SERVICE_ACCOUNT_EMAIL"
  --allow-unauthenticated
  --min-instances "0"
  --max-instances "2"
  --memory "256Mi"
  --cpu "1"
  --set-env-vars "VERTEX_PROJECT_ID=${PROJECT_ID},VERTEX_LOCATION=${VERTEX_LOCATION},VERTEX_MODEL=${VERTEX_MODEL}"
  --set-secrets "RESAI_PROXY_SHARED_SECRET=${SECRET_NAME}:latest"
  --quiet
)

if gcloud run services describe "$SERVICE_NAME" \
  --project "$PROJECT_ID" \
  --region "$REGION" >/dev/null 2>&1; then
  echo "Updating existing Cloud Run service: $SERVICE_NAME"
else
  echo "Creating Cloud Run service: $SERVICE_NAME"
fi

run gcloud "${DEPLOY_ARGS[@]}"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Dry-run complete."
  exit 0
fi

SERVICE_URL="$(gcloud run services describe "$SERVICE_NAME" \
  --project "$PROJECT_ID" \
  --region "$REGION" \
  --format "value(status.url)")"

if [[ -n "$PENDING_PROXY_SECRET" ]]; then
  security add-generic-password -U -s ai.res.resai -a vertex.proxyAuthToken -w "$PENDING_PROXY_SECRET"
  defaults delete "$APP_BUNDLE_ID" vertex.proxyAuthToken 2>/dev/null || true
  PENDING_PROXY_SECRET=""
fi

defaults write "$APP_BUNDLE_ID" vertex.proxyURL "$SERVICE_URL/v1/rewrite"
defaults write "$APP_BUNDLE_ID" vertex.projectID "$PROJECT_ID"
defaults write "$APP_BUNDLE_ID" vertex.location "$VERTEX_LOCATION"
defaults write "$APP_BUNDLE_ID" vertex.model "$VERTEX_MODEL"

cat <<EOF
Deployed ResponseAi Vertex proxy without duplicating existing resources.

Cloud Run URL:
  $SERVICE_URL/v1/rewrite

Local app defaults updated for:
  $APP_BUNDLE_ID
EOF
