# Stream Security — GCP agentless volume scanner (Infrastructure Manager blueprint).

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  sa_account_id = "streamsec-volume-scanner"
  job_name      = "streamsec-volume-scanner-orchestrator"
  scheduler     = "streamsec-volume-scanner-cron"
}

# Required APIs.
resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "batch.googleapis.com",
    "run.googleapis.com",
    "cloudscheduler.googleapis.com",
    "secretmanager.googleapis.com",
  ])
  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
}

# Single service account for orchestrator + worker.
resource "google_service_account" "scanner" {
  project      = var.project_id
  account_id   = local.sa_account_id
  display_name = "Stream Security volume scanner"
}

# Least-privilege custom role: discover VMs, snapshot/attach disks, run Batch workers.
resource "google_project_iam_custom_role" "scanner" {
  project     = var.project_id
  role_id     = "streamsecVolumeScanner"
  title       = "Stream Security Volume Scanner"
  description = "Agentless disk scanning: discover VMs, snapshot/attach disks, run Batch workers."
  permissions = [
    "compute.instances.list",
    "compute.instances.get",
    "compute.instances.attachDisk",
    "compute.instances.detachDisk",
    "compute.disks.create",
    "compute.disks.get",
    "compute.disks.use",
    "compute.disks.useReadOnly",
    "compute.disks.delete",
    "compute.disks.list",
    "compute.disks.createSnapshot",
    "compute.snapshots.create",
    "compute.snapshots.setLabels",
    "compute.snapshots.get",
    "compute.snapshots.useReadOnly",
    "compute.snapshots.delete",
    "compute.snapshots.list",
    "compute.zoneOperations.get",
    "compute.globalOperations.get",
    "compute.regionOperations.get",
    "compute.subnetworks.use",
    "batch.jobs.create",
    "batch.jobs.get",
    "batch.jobs.delete",
    "iam.serviceAccounts.actAs",
    "logging.logEntries.create",
  ]
}

resource "google_project_iam_member" "scanner" {
  project = var.project_id
  role    = google_project_iam_custom_role.scanner.id
  member  = "serviceAccount:${google_service_account.scanner.email}"
}

resource "google_project_iam_member" "scanner_agent_reporter" {
  project = var.project_id
  role    = "roles/batch.agentReporter"
  member  = "serviceAccount:${google_service_account.scanner.email}"
}

# Collection + acknowledge tokens in Secret Manager, not plaintext Cloud Run env.
resource "google_secret_manager_secret" "collection_token" {
  project   = var.project_id
  secret_id = "streamsec-volume-scanner-collection-token"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "collection_token" {
  secret      = google_secret_manager_secret.collection_token.id
  secret_data = var.stream_collection_token
}

resource "google_secret_manager_secret" "ack_token" {
  project   = var.project_id
  secret_id = "streamsec-volume-scanner-ack-token"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "ack_token" {
  secret      = google_secret_manager_secret.ack_token.id
  secret_data = var.stream_ack_token
}

resource "google_secret_manager_secret_iam_member" "collection_token_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.collection_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.scanner.email}"
}

resource "google_secret_manager_secret_iam_member" "ack_token_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.ack_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.scanner.email}"
}

# Isolated network + Cloud NAT for the no-external-IP scan workers.
resource "google_compute_network" "scanner" {
  project                 = var.project_id
  name                    = "streamsec-scanner-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "scanner" {
  project                  = var.project_id
  name                     = "streamsec-scanner-subnet"
  region                   = var.region
  network                  = google_compute_network.scanner.id
  ip_cidr_range            = "10.61.0.0/24"
  private_ip_google_access = true
}

resource "google_compute_router" "scanner" {
  project = var.project_id
  name    = "streamsec-scanner-router"
  region  = var.region
  network = google_compute_network.scanner.id
}

resource "google_compute_router_nat" "scanner" {
  project                            = var.project_id
  name                               = "streamsec-scanner-nat"
  router                             = google_compute_router.scanner.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# Orchestrator Cloud Run Job (workers are created at runtime as Batch jobs).
resource "google_cloud_run_v2_job" "orchestrator" {
  name     = local.job_name
  location = var.region
  project  = var.project_id

  template {
    template {
      service_account = google_service_account.scanner.email
      containers {
        image = var.scanner_image
        env {
          name  = "COLLECTOR_PROVIDER"
          value = "gcp"
        }
        env {
          name  = "COLLECTOR_ROLE"
          value = "orchestrator"
        }
        env {
          name  = "COLLECTOR_GCP_PROJECT"
          value = var.project_id
        }
        env {
          name  = "COLLECTOR_GCP_REGION"
          value = var.region
        }
        env {
          name  = "COLLECTOR_GCP_WORKER_IMAGE"
          value = var.scanner_image
        }
        env {
          name  = "COLLECTOR_GCP_WORKER_SA"
          value = google_service_account.scanner.email
        }
        env {
          name  = "COLLECTOR_GCP_WORKER_NETWORK"
          value = google_compute_network.scanner.id
        }
        env {
          name  = "COLLECTOR_GCP_WORKER_SUBNETWORK"
          value = google_compute_subnetwork.scanner.id
        }
        env {
          name  = "COLLECTOR_SCAN_LANGUAGE_PACKAGES"
          value = lower(var.scan_language_packages)
        }
        env {
          name  = "COLLECTOR_SCAN_SECRETS"
          value = lower(var.scan_secrets)
        }
        env {
          name  = "COLLECTOR_SCAN_AI_WORKLOADS"
          value = lower(var.scan_ai_workloads)
        }
        env {
          name  = "COLLECTOR_STREAM_SCAN_URL"
          value = "${var.stream_api_url}/openapi/vulnerabilities/stream_scan/raw"
        }
        env {
          name = "COLLECTOR_STREAM_SCAN_TOKEN"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.collection_token.secret_id
              version = "latest"
            }
          }
        }
        env {
          name  = "COLLECTOR_STREAM_SCAN_WORKSPACE"
          value = var.stream_customer_id
        }
        env {
          name  = "COLLECTOR_STREAM_API_URL"
          value = var.stream_api_url
        }
        env {
          name  = "STREAM_API_URL"
          value = var.stream_api_url
        }
        env {
          name  = "STREAM_CUSTOMER_ID"
          value = var.stream_customer_id
        }
        env {
          name = "STREAM_ACK_TOKEN"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.ack_token.secret_id
              version = "latest"
            }
          }
        }
      }
    }
  }

  depends_on = [
    google_project_service.apis,
    google_secret_manager_secret_version.collection_token,
    google_secret_manager_secret_version.ack_token,
    google_secret_manager_secret_iam_member.collection_token_accessor,
    google_secret_manager_secret_iam_member.ack_token_accessor,
  ]
}

# Cloud Scheduler cron: trigger the orchestrator daily.
resource "google_cloud_scheduler_job" "cron" {
  name      = local.scheduler
  project   = var.project_id
  region    = var.region
  schedule  = "0 2 * * *"
  time_zone = "Etc/UTC"

  http_target {
    http_method = "POST"
    uri         = "https://${var.region}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${var.project_id}/jobs/${local.job_name}:run"
    oauth_token {
      service_account_email = google_service_account.scanner.email
    }
  }

  depends_on = [google_cloud_run_v2_job.orchestrator]
}

# Acknowledge the install back to Stream Security (best-effort).
resource "terraform_data" "acknowledge" {
  triggers_replace = [google_cloud_run_v2_job.orchestrator.uid]

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-c"]
    command     = <<-EOT
      curl -fsS -X POST "${var.stream_api_url}/api/accounts/${var.project_id}/gcp-scanner-acknowledge" \
        -H "Content-Type: application/json" \
        -d '{"customer_id":"${var.stream_customer_id}","project_id":"${var.project_id}","status":"deployed","template_version":"${var.stream_template_version}","acknowledge_token":"${var.stream_ack_token}"}' \
        || echo "ack callback failed (non-fatal); console may show 'pending' until first scan"
    EOT
  }
}
