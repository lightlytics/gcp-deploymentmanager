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

### One-time: create the runner service account

Run once per project (the Stream console's Deploy dialog also shows this). It
needs project IAM-admin, since the blueprint creates a custom role + IAM
binding:

```bash
PROJECT=<PROJECT_ID>
SA=infra-manager@$PROJECT.iam.gserviceaccount.com
PROJNUM=$(gcloud projects describe $PROJECT --format='value(projectNumber)')

gcloud iam service-accounts create infra-manager --display-name="Infra Manager runner" 2>/dev/null || true

for ROLE in roles/editor roles/iam.roleAdmin roles/resourcemanager.projectIamAdmin; do
  gcloud projects add-iam-policy-binding $PROJECT --member="serviceAccount:$SA" --role="$ROLE" --condition=None -q
done

# let the Infrastructure Manager service agent use the runner SA
gcloud iam service-accounts add-iam-policy-binding $SA \
  --member="serviceAccount:service-$PROJNUM@gcp-sa-config.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountTokenCreator" -q
```

Then pass `--service-account=projects/$PROJECT/serviceAccounts/$SA` to the
`apply` command above.

## Inputs

See `variables.tf`.
