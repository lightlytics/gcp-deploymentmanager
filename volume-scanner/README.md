# Moved

The Stream Security agentless volume scanner now lives in the Terraform module
repo, alongside every other GCP capability:

**https://github.com/streamsec-terraform/terraform-streamsec-google-integration**

- `modules/volume-scanner` — the module. Call it from your own root and pin
  `version` if you manage Stream Security as code.
- `infrastructure-manager/volume-scanner` — the root Stream applies with
  `gcloud infra-manager deployments apply`. Infra Manager applies a Terraform
  *root*, not a module, which is why that wrapper exists.

Nothing here deploys the scanner any more. If you reached this because a saved
`gcloud infra-manager deployments apply` command failed, generate a fresh one
from the Stream console — Integrations → Vulnerability Scanners — and it will
point at the new location.

Released tags of this repo (1.5.1 and earlier) still contain the old blueprint,
so an existing deployment pinned to a tag keeps working until you re-apply.

Why it moved: this repo is for Google Deployment Manager, whose support ended
2026-04-01. The scanner never used Deployment Manager — it has always been
Terraform via Infrastructure Manager — but it should not live in a repo named
for a retired product. See DEV-21196.
