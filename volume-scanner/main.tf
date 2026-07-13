# Stream Security — GCP agentless volume scanner — Infrastructure Manager
# Terraform blueprint (DEV-20325).
#
# Provisions a single regional orchestrator (Cloud Run Job on a Cloud Scheduler
# cron) that fans out per-shard workers as GCP Batch jobs; workers snapshot each
# VM's boot disk, attach it, read it, and clean up. One scanner per project.

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

# Combined least-privilege custom role (discover + Batch + snapshot/disk).
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
    "compute.disks.delete",
    # Snapshotting a disk is authorized by compute.disks.createSnapshot ON THE
    # SOURCE DISK — not compute.snapshots.create (which alone yields
    # PERMISSION_DENIED on disks.createSnapshot). Both are required: the former
    # to read-snapshot the source boot disk, the latter to create the snapshot
    # resource.
    "compute.disks.createSnapshot",
    "compute.snapshots.create",
    # The snapshot is created with a Purpose label (so the cleanup GC can find
    # its own orphans) — labeling on create requires compute.snapshots.setLabels.
    "compute.snapshots.setLabels",
    "compute.snapshots.get",
    "compute.snapshots.useReadOnly",
    "compute.snapshots.delete",
    # Every snapshot/disk/attach call returns an async operation the worker
    # must poll to completion. Polling needs the *Operations.get permission for
    # the operation's scope (zonal for disk/attach/createSnapshot, global for
    # snapshot delete). Without these the create/attach calls succeed on the
    # server but the client's wait is denied — the scan dies right after
    # createSnapshot and never creates/attaches the disk (the denial is a read,
    # so it doesn't even appear in the admin-activity audit log).
    "compute.zoneOperations.get",
    "compute.globalOperations.get",
    "compute.regionOperations.get",
    # Use the scanner's own subnet (below) for the Batch worker VM. Granted via
    # this project-level role rather than a subnet-scoped IAM binding, so the
    # runner SA only needs its documented roles (editor + projectIamAdmin) and
    # not compute.networkAdmin/subnetworks.setIamPolicy.
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

# The Batch agent on each worker VM runs as the scanner SA and reports task state
# to the Batch control plane; that needs roles/batch.agentReporter. Without it
# the agent starts but can't report, and Batch fails the job with "no VM has
# agent reporting correctly" (misleadingly looks like an egress problem).
resource "google_project_iam_member" "scanner_agent_reporter" {
  project = var.project_id
  role    = "roles/batch.agentReporter"
  member  = "serviceAccount:${google_service_account.scanner.email}"
}

# Dedicated, isolated network for the ephemeral scan workers. They run here with
# NO external IP and reach the Batch control plane, Compute API, and the scanner
# image (Artifact Registry) via Cloud NAT. This makes egress part of the
# integration: a locked-down project (external IPs blocked by org policy, no
# pre-existing Cloud NAT) works out of the box, and nothing touches the
# customer's own VPCs. Without it, Batch VMs fail with "no VM has agent
# reporting correctly" before the container ever starts.
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

# Orchestrator Cloud Run Job. Workers are created at runtime as Batch jobs, so
# there is no standing worker resource to declare here.
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
        # Subnet (with Cloud NAT, above) the Batch worker runs in — no external
        # IP; egress via NAT. Makes locked-down projects work without customer
        # networking changes.
        # Batch requires BOTH network and subnetwork when the worker has no
        # external IP. Pass the relative form (projects/..) — Batch rejects the
        # full https self_link.
        env {
          name  = "COLLECTOR_GCP_WORKER_NETWORK"
          value = google_compute_network.scanner.id
        }
        env {
          name  = "COLLECTOR_GCP_WORKER_SUBNETWORK"
          value = google_compute_subnetwork.scanner.id
        }
        # Stream scan ingest — the collector config reads these COLLECTOR_STREAM_*
        # names (LoadFromEnv); the worker inherits them via the launcher so it can
        # upload SBOMs + heartbeat.
        env {
          name  = "COLLECTOR_STREAM_SCAN_URL"
          value = "${var.stream_api_url}/openapi/vulnerabilities/stream_scan/raw"
        }
        env {
          name  = "COLLECTOR_STREAM_SCAN_TOKEN"
          value = var.stream_collection_token
        }
        env {
          name  = "COLLECTOR_STREAM_SCAN_WORKSPACE"
          value = var.stream_customer_id
        }
        env {
          name  = "COLLECTOR_STREAM_API_URL"
          value = var.stream_api_url
        }
        # For the orchestrator's first-run "deployed" acknowledgement (read
        # directly from env by ackGCPDeployedBestEffort, not via config).
        env {
          name  = "STREAM_API_URL"
          value = var.stream_api_url
        }
        env {
          name  = "STREAM_CUSTOMER_ID"
          value = var.stream_customer_id
        }
        env {
          name  = "STREAM_ACK_TOKEN"
          value = var.stream_ack_token
        }
      }
    }
  }

  depends_on = [google_project_service.apis]
}

# Cloud Scheduler cron -> trigger the orchestrator daily.
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

# Acknowledge the install back to Stream Security so the console flips the
# scanner to "deployed". Best-effort: a failure here must not fail the
# deployment (the orchestrator's first run also re-acks).
resource "terraform_data" "acknowledge" {
  triggers_replace = [google_cloud_run_v2_job.orchestrator.uid]

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-c"]
    command     = <<-EOT
      curl -fsS -X POST "${var.stream_api_url}/api/accounts/${var.project_id}/gcp-scanner-acknowledge" \
        -H "Content-Type: application/json" \
        -d '{"customer_id":"${var.stream_customer_id}","project_id":"${var.project_id}","status":"deployed","acknowledge_token":"${var.stream_ack_token}"}' \
        || echo "ack callback failed (non-fatal); console may show 'pending' until first scan"
    EOT
  }
}
