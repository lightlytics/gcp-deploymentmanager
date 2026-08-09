# Stream Security — GCP agentless volume scanner (Infrastructure Manager blueprint inputs).

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
