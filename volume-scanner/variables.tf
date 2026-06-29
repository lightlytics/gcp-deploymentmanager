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
  description = "Public scanner container image (orchestrator + worker)."
  default     = "public.ecr.aws/stream-security/volume-scanner:latest"
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
