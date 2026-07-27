# Stream Security — GCP agentless volume scanner — Infrastructure Manager
# Terraform blueprint inputs (DEV-20325).
#
# Deployed via Infrastructure Manager (the successor to Deployment Manager,
# which is EOL), matching how the Stream GCP integration onboards. The Stream
# console renders a `gcloud infra-manager deployments apply ...` command
# pre-filled with these values.

variable "project_id" {
  type        = string
  description = "GCP project to scan."
}

variable "region" {
  type        = string
  description = "Region for the orchestrator Cloud Run Job + Cloud Scheduler."
  default     = "us-central1"
}

variable "scanner_image" {
  type        = string
  # GCP Cloud Run only pulls from Artifact Registry / gcr.io / docker.io, NOT
  # public.ecr.aws — so the GCP image is hosted in a Stream-owned public AR
  # (mirrored there by the cloud-volume-scanner-build release pipeline). The
  # console always passes an explicit value; this default is just a fallback.
  description = "Public scanner container image (orchestrator + worker), in a GCP-pullable registry."
  default     = "us-docker.pkg.dev/stream-secops-project/streamsec-public/volume-scanner:latest"
}

variable "stream_api_url" {
  type        = string
  description = "Stream Security tenant API URL, e.g. https://<tenant>.<domain>."
}

variable "stream_customer_id" {
  type        = string
  description = "Stream Security workspace (customer) id."
}

variable "stream_ack_token" {
  type        = string
  description = "Per-deployment acknowledge token (authenticates install callback)."
  sensitive   = true
}

variable "stream_collection_token" {
  type        = string
  description = "Per-customer collection token (authenticates scan reports)."
  sensitive   = true
}

# Per-integration scan-feature toggles (DEV-21073). The Stream console passes
# these from the scanner deploy dialog as `--input-values scan_*=<true|false>`
# (lowercase strings, like the other inputs); they become the orchestrator's
# COLLECTOR_SCAN_* env, which the Batch worker inherits (childlauncher forwards
# every COLLECTOR_* var). Defaults match the console + AWS/Azure templates:
# CVEs on, Secrets and AI Workloads opt-in.
variable "scan_language_packages" {
  type        = string
  description = "Scan OS/language packages for CVEs (COLLECTOR_SCAN_LANGUAGE_PACKAGES). \"true\" or \"false\" (case-insensitive)."
  default     = "true"
  validation {
    condition     = contains(["true", "false"], lower(var.scan_language_packages))
    error_message = "scan_language_packages must be \"true\" or \"false\" (case-insensitive)."
  }
}

variable "scan_secrets" {
  type        = string
  description = "Scan for secrets/credentials on the volume (COLLECTOR_SCAN_SECRETS). \"true\" or \"false\" (case-insensitive)."
  default     = "false"
  validation {
    condition     = contains(["true", "false"], lower(var.scan_secrets))
    error_message = "scan_secrets must be \"true\" or \"false\" (case-insensitive)."
  }
}

variable "scan_ai_workloads" {
  type        = string
  description = "Scan for AI/ML models, frameworks, and workloads (COLLECTOR_SCAN_AI_WORKLOADS). \"true\" or \"false\" (case-insensitive)."
  default     = "false"
  validation {
    condition     = contains(["true", "false"], lower(var.scan_ai_workloads))
    error_message = "scan_ai_workloads must be \"true\" or \"false\" (case-insensitive)."
  }
}
