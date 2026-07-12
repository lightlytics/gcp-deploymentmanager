#!/usr/bin/env bash
#
# Stream Security — StreamForce custom-plugin deploy for GCP.
#
# Deploys a customer's plugin as a PRIVATE (IAM-gated) Cloud Run service in the
# current project, grants the Stream Security service account run.invoker, and
# acknowledges the service URL back to the platform. The plugin's env values are
# passed on the command line (from the Stream wizard) straight into the Cloud Run
# service — they never pass through the Stream platform.
#
# Usage (copy the exact command from the Stream Security plugin wizard):
#   bash streamforce-plugin-deploy.sh \
#     --plugin-id <id> --region <region> --artifact-url <url> \
#     --plugin-token <token> --platform-url <url> --sa-email <sa> \
#     --env '{"KEY":"value"}'
#
set -euo pipefail

PLUGIN_ID=""
REGION="us-central1"
ARTIFACT_URL=""
PLUGIN_TOKEN=""
PLATFORM_URL=""
SA_EMAIL=""
PLUGIN_ENV="{}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plugin-id)    PLUGIN_ID="$2"; shift 2 ;;
    --region)       REGION="$2"; shift 2 ;;
    --artifact-url) ARTIFACT_URL="$2"; shift 2 ;;
    --plugin-token) PLUGIN_TOKEN="$2"; shift 2 ;;
    --platform-url) PLATFORM_URL="$2"; shift 2 ;;
    --sa-email)     SA_EMAIL="$2"; shift 2 ;;
    --env)          PLUGIN_ENV="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

for var in PLUGIN_ID ARTIFACT_URL PLUGIN_TOKEN PLATFORM_URL SA_EMAIL; do
  if [[ -z "${!var}" ]]; then
    echo "Missing required argument for ${var}" >&2
    exit 1
  fi
done

SERVICE="sfplugin-${PLUGIN_ID:0:8}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "==> Downloading plugin artifact"
curl -fsSL "$ARTIFACT_URL" -o "$WORKDIR/plugin.zip"
mkdir -p "$WORKDIR/src"
unzip -q "$WORKDIR/plugin.zip" -d "$WORKDIR/src"

echo "==> Deploying private Cloud Run service: $SERVICE (region $REGION)"
# `^@@^` sets @@ as the env-var delimiter so commas inside PLUGIN_ENV_JSON are
# not misread as separators. PLUGIN_ENV_JSON is expanded into process.env by the
# plugin's entrypoint at startup.
gcloud run deploy "$SERVICE" \
  --source "$WORKDIR/src" \
  --region "$REGION" \
  --no-allow-unauthenticated \
  --set-env-vars "^@@^PLUGIN_ID=${PLUGIN_ID}@@PLUGIN_TOKEN=${PLUGIN_TOKEN}@@PLATFORM_URL=${PLATFORM_URL}@@PLUGIN_ENV_JSON=${PLUGIN_ENV}" \
  --quiet

echo "==> Granting ${SA_EMAIL} the run.invoker role on ${SERVICE}"
gcloud run services add-iam-policy-binding "$SERVICE" \
  --region "$REGION" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/run.invoker" \
  --quiet

URL="$(gcloud run services describe "$SERVICE" --region "$REGION" --format='value(status.url)')"
echo "==> Service URL: $URL"

echo "==> Acknowledging to Stream Security"
curl -fsS -X POST "${PLATFORM_URL%/}/api/accounts/streamforce-plugins/acknowledge" \
  -H "Authorization: Bearer ${PLUGIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"function_url\": \"${URL}\"}"

echo
echo "✅ Plugin deployed. It will show as Active in Stream Security once its tools are reachable."
