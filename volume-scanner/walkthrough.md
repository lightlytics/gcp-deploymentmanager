# Deploy the Stream Security volume scanner

This guides you through deploying the Stream Security **agentless volume
scanner** into your GCP project. It provisions a least-privilege service
account, a Cloud Run orchestrator (on a daily Cloud Scheduler trigger), and
runs per-VM scans as GCP Batch jobs. Nothing leaves your project except the
package inventory sent to Stream Security.

## Prerequisites

<walkthrough-project-setup></walkthrough-project-setup>

Make sure the project above is the one you want scanned. To change it:

```bash
gcloud config set project <PROJECT_ID>
```

## Step 1 — Paste the values from the Stream console

In the Stream Security console, on the scanner **Deploy** panel, copy the four
values shown and paste them here (they authenticate the install back to your
tenant):

```bash
export STREAM_API_URL="<Environment URL>"
export STREAM_CUSTOMER_ID="<Workspace ID>"
export STREAM_ACK_TOKEN="<Acknowledge token>"
export STREAM_COLLECTION_TOKEN="<Collection token>"
```

Optional — override the region (default `us-central1`) or pin a specific
scanner image:

```bash
export REGION="us-central1"
# export SCANNER_IMAGE="public.ecr.aws/stream-security/volume-scanner:vX.Y.Z"
```

## Step 2 — Run the installer

```bash
bash ./setup.sh
```

This enables the required APIs, creates the `streamsec-volume-scanner` service
account + custom role, deploys the orchestrator Cloud Run Job + Cloud Scheduler
cron, and acknowledges the install.

## Step 3 — (Optional) run a scan now

The scanner runs daily at 02:00 by default. To run immediately:

```bash
gcloud run jobs execute streamsec-volume-scanner-orchestrator --region "${REGION:-us-central1}"
```

## Done

<walkthrough-conclusion-trophy></walkthrough-conclusion-trophy>

Back in the Stream Security console the scanner status will move to
**Deployed**, then **Active** after the first scan completes.
