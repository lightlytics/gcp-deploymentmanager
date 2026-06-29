#!/usr/bin/env bash
#
# Stream Security — GCP agentless volume scanner — Cloud Shell installer
# (DEV-20325).
#
# Parameterized counterpart of the server-rendered scanner-setup.sh.jinja2.
# Designed to run from the "Open in Cloud Shell" tutorial: the user exports a
# few values shown in the Stream console (mirroring the GCP project onboarding
# flow), then runs this. Idempotent: re-running updates in place.
#
# Required (exported by the walkthrough; shown in the Stream console):
#   STREAM_API_URL          e.g. https://<tenant>.<domain>
#   STREAM_ACK_TOKEN        per-deployment acknowledge token
#   STREAM_COLLECTION_TOKEN per-customer collection token
#   STREAM_CUSTOMER_ID      workspace (customer) id
# Optional (sensible defaults):
#   PROJECT_ID              defaults to the active Cloud Shell project
#   REGION                  defaults to us-central1
#   SCANNER_IMAGE           defaults to the public scanner image :latest
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-us-central1}"
SCANNER_IMAGE="${SCANNER_IMAGE:-public.ecr.aws/stream-security/volume-scanner:latest}"

: "${STREAM_API_URL:?export STREAM_API_URL (from the Stream console)}"
: "${STREAM_ACK_TOKEN:?export STREAM_ACK_TOKEN (from the Stream console)}"
: "${STREAM_COLLECTION_TOKEN:?export STREAM_COLLECTION_TOKEN (from the Stream console)}"
: "${STREAM_CUSTOMER_ID:?export STREAM_CUSTOMER_ID (from the Stream console)}"
: "${PROJECT_ID:?no active project — run: gcloud config set project <PROJECT_ID>}"

SA_NAME="streamsec-volume-scanner"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
ROLE_ID="streamsec.volumeScanner"
JOB_NAME="streamsec-volume-scanner-orchestrator"
SCHEDULER_NAME="streamsec-volume-scanner-cron"

echo "Stream Security volume scanner -> project ${PROJECT_ID}, region ${REGION}"

# 1. Enable the APIs the scanner uses.
gcloud services enable \
  compute.googleapis.com batch.googleapis.com run.googleapis.com cloudscheduler.googleapis.com \
  --project "${PROJECT_ID}"

# 2. Service account (single SA for orchestrator + worker).
gcloud iam service-accounts describe "${SA_EMAIL}" --project "${PROJECT_ID}" >/dev/null 2>&1 || \
  gcloud iam service-accounts create "${SA_NAME}" \
    --display-name="Stream Security volume scanner" --project "${PROJECT_ID}"

# 3. Custom least-privilege role (discover + Batch + snapshot/disk).
cat > /tmp/streamsec-scanner-role.yaml <<'ROLE'
title: "Stream Security Volume Scanner"
description: "Agentless disk scanning: discover VMs, snapshot/attach disks, run Batch workers."
stage: "GA"
includedPermissions:
- compute.instances.list
- compute.instances.get
- compute.instances.attachDisk
- compute.instances.detachDisk
- compute.disks.create
- compute.disks.get
- compute.disks.use
- compute.disks.delete
- compute.snapshots.create
- compute.snapshots.get
- compute.snapshots.useReadOnly
- compute.snapshots.delete
- batch.jobs.create
- batch.jobs.get
- batch.jobs.delete
- iam.serviceAccounts.actAs
- logging.logEntries.create
ROLE

if gcloud iam roles describe "${ROLE_ID}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud iam roles update "${ROLE_ID}" --project "${PROJECT_ID}" --file=/tmp/streamsec-scanner-role.yaml
else
  gcloud iam roles create "${ROLE_ID}" --project "${PROJECT_ID}" --file=/tmp/streamsec-scanner-role.yaml
fi

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="projects/${PROJECT_ID}/roles/${ROLE_ID}" --condition=None

# 4. Orchestrator Cloud Run Job (workers are created at runtime as Batch jobs).
gcloud run jobs deploy "${JOB_NAME}" \
  --image="${SCANNER_IMAGE}" --region="${REGION}" --service-account="${SA_EMAIL}" \
  --set-env-vars="COLLECTOR_PROVIDER=gcp,COLLECTOR_ROLE=orchestrator,COLLECTOR_GCP_PROJECT=${PROJECT_ID},COLLECTOR_GCP_REGION=${REGION},COLLECTOR_GCP_WORKER_IMAGE=${SCANNER_IMAGE},COLLECTOR_GCP_WORKER_SA=${SA_EMAIL},STREAM_SCAN_URL=${STREAM_API_URL}/openapi/vulnerabilities/stream_scan/raw,COLLECTION_TOKEN=${STREAM_COLLECTION_TOKEN}" \
  --project "${PROJECT_ID}"

# 5. Cloud Scheduler cron -> trigger the orchestrator daily.
RUN_URI="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT_ID}/jobs/${JOB_NAME}:run"
if gcloud scheduler jobs describe "${SCHEDULER_NAME}" --location="${REGION}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
  SCHED_VERB="update http"
else
  SCHED_VERB="create http"
fi
gcloud scheduler jobs ${SCHED_VERB} "${SCHEDULER_NAME}" \
  --location="${REGION}" --schedule="0 2 * * *" --uri="${RUN_URI}" \
  --http-method=POST --oauth-service-account-email="${SA_EMAIL}" --project "${PROJECT_ID}"

# 6. Acknowledge the install back to Stream Security.
curl -fsS -X POST "${STREAM_API_URL}/api/accounts/${PROJECT_ID}/gcp-scanner-acknowledge" \
  -H "Content-Type: application/json" \
  -d "{\"customer_id\":\"${STREAM_CUSTOMER_ID}\",\"project_id\":\"${PROJECT_ID}\",\"status\":\"deployed\",\"acknowledge_token\":\"${STREAM_ACK_TOKEN}\"}" \
  || echo "WARNING: acknowledge callback failed; scanner deployed but console may show 'pending'."

echo "Done. Stream Security volume scanner deployed to ${PROJECT_ID}."
