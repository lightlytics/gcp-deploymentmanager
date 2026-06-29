# Stream Security volume scanner — Infrastructure Manager blueprint

Terraform blueprint for the Stream Security agentless volume scanner, deployed
via **GCP Infrastructure Manager** (the successor to the now-EOL Deployment
Manager), matching how the Stream GCP integration onboards.

It provisions a least-privilege service account + custom role, an orchestrator
Cloud Run Job on a daily Cloud Scheduler trigger, and acknowledges the install
back to Stream. Per-VM scans run as GCP Batch jobs created at runtime.

## Deploy

The Stream console (scanner **Deploy** dialog) renders a pre-filled command.
It looks like:

```bash
gcloud infra-manager deployments apply \
  projects/<PROJECT_ID>/locations/<REGION>/deployments/streamsec-volume-scanner \
  --service-account=projects/<PROJECT_ID>/serviceAccounts/<INFRA_MANAGER_SA> \
  --git-source-repo=https://github.com/lightlytics/gcp-deploymentmanager \
  --git-source-directory=volume-scanner \
  --git-source-ref=master \
  --input-values=project_id=<PROJECT_ID>,region=<REGION>,scanner_image=<IMAGE>,stream_api_url=<API_URL>,stream_customer_id=<CUSTOMER_ID>,stream_ack_token=<ACK_TOKEN>,stream_collection_token=<COLLECTION_TOKEN>
```

`<INFRA_MANAGER_SA>` is a service account Infrastructure Manager runs Terraform
as; it needs permission to create the resources above (e.g. roles/editor +
roles/resourcemanager.projectIamAdmin, or a scoped equivalent). See the Stream
docs for the recommended setup.

## Inputs

See `variables.tf`.
