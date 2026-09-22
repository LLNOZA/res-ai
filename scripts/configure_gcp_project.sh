#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${RESAI_VERTEX_PROJECT_ID:?Set RESAI_VERTEX_PROJECT_ID to your GCP project ID}"
PROJECT_NUMBER="${RESAI_GCP_PROJECT_NUMBER:?Set RESAI_GCP_PROJECT_NUMBER to your GCP project number}"
LOCATION="${RESAI_VERTEX_LOCATION:-global}"
MODEL="${RESAI_VERTEX_MODEL:-gemini-3.5-flash}"
BUNDLE_ID="ai.res.resai"

defaults write "$BUNDLE_ID" vertex.projectID "$PROJECT_ID"
defaults write "$BUNDLE_ID" vertex.location "$LOCATION"
defaults write "$BUNDLE_ID" vertex.model "$MODEL"
defaults write "$BUNDLE_ID" vertex.regionalEndpoint "false"

if command -v gcloud >/dev/null 2>&1; then
  gcloud config set project "$PROJECT_ID" >/dev/null
fi

cat <<EOF
Configured ResponseAi Vertex defaults:
  project_id:     $PROJECT_ID
  project_number: $PROJECT_NUMBER
  location:       $LOCATION
  model:          $MODEL

Token auth is still separate. For development:
  export VERTEX_AI_ACCESS_TOKEN="\$(gcloud auth print-access-token)"
  ./scripts/run_app.sh
EOF
