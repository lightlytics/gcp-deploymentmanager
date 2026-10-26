## GKE audit logs integration

This document explains how to integrate GKE audit logs to our product

There are two ways to deliver the logs:

1. **Pub/Sub (recommended)** - a Log Router sink publishes every audit log entry to a Pub/Sub topic and the cloud
   function sends it to Stream Security within seconds.
2. **Cloud Storage bucket (legacy)** - Cloud Logging writes the logs to the bucket in hourly files, so events reach
   Stream Security 10-70 minutes after they happen. Existing setups keep working; see
   [Migrating from the bucket setup](#migrating-from-the-bucket-setup).

### Requirements:

1. GKE cluster with "**Cloud Monitoring**" enabled (_API Server logging_)
2. Your Stream Security collection token

### Pub/Sub setup (recommended)

Run `setup-realtime.sh` in [Cloud Shell](https://shell.cloud.google.com). It sets up everything for one project, or
with `--organization`, for every project in your organization ([below](#every-project-in-an-organization-or-folder)).
It asks for the project, your Stream Security URL and the collection token:

```bash
curl -fsSLO https://raw.githubusercontent.com/lightlytics/gcp-deploymentmanager/master/code/gke-logs/setup-realtime.sh
bash setup-realtime.sh
```

The script:

1. Checks that you can make every change it needs, and stops before changing anything if not
2. Enables the APIs (Cloud Functions, Cloud Run, Cloud Build, Artifact Registry, Eventarc, Pub/Sub, Cloud Logging,
   Secret Manager, IAM)
3. Stores the collection token in the secret `streamsec-gke-logs-token`, or reuses that secret if it exists
4. Creates the service account `streamsec-gke-audit`, which can read only that secret and invoke only the function
5. Creates the topic, the sink and the sink's publisher grant, and deploys the function, as listed below
6. Checks that the function is `ACTIVE` and prints how to test it

Running it again is safe: it reuses what exists and applies the current settings. `bash setup-realtime.sh --help`
lists the options: `--region`, a regional secret (`--secret-location`), collecting only some clusters (`--cluster`,
repeatable), and `--yes` with `STREAMSEC_COLLECTION_TOKEN` for unattended runs. To remove the setup:

```bash
bash setup-realtime.sh --project PROJECT_ID --uninstall              # keeps the secret
bash setup-realtime.sh --project PROJECT_ID --uninstall --delete-secret
```

#### Every project in an organization or folder

Run the script once with `--organization` (or `--folder`) and one collection token, and it collects from every project
under it, including projects created later:

```bash
bash setup-realtime.sh --organization ORGANIZATION_ID
```

- The sink goes on the organization (or folder) and includes its child projects. The secret, service account, topic
  and function are created once, in your current gcloud project; `--project` picks another. That project needs
  billing enabled.
- Besides the permissions in that project, you need Logs Configuration Writer (`roles/logging.configWriter`) on the
  organization or folder. The script checks both before changing anything.
- Before you confirm, it lists the GKE clusters it finds there, through Cloud Asset Inventory (Cloud Asset Viewer on
  the organization). The list is only informational: without it, the script says why and continues.
- `--projects p1,p2` collects only those projects, and `--cluster` works too.
- Use the collection token of a GCP project connected to Stream Security. Every project's events go to that
  token's workspace. Clusters in projects that are not connected to Stream Security are collected too, but are not
  linked to the inventory.
- A per-project setup elsewhere would send its project's events a second time: remove it with
  `bash setup-realtime.sh --project THAT_PROJECT --uninstall`. In the project that holds the collector, the script
  replaces the per-project sink itself, and that project's per-project `--uninstall` would remove the organization's
  function and topic too.

To remove it, pass the same options with `--uninstall`:

```bash
bash setup-realtime.sh --organization ORGANIZATION_ID --project PROJECT_ID --uninstall
```

What it creates in the project:

1. The Pub/Sub topic `streamsec-gke-audit-logs`
2. The Log Router sink `streamsec-gke-audit-logs-pubsub` that publishes to the topic, on the project or, with
   `--organization` or `--folder`, on the organization or folder. Its filter is `LOG_FILTER` in `setup-realtime.sh`
   (plus `resource.labels.project_id` and `resource.labels.cluster_name` clauses for `--projects` and `--cluster`).
   It forwards:
    - everything done by people and other non-system identities
    - successful anonymous requests
    - for workload service accounts outside the system namespaces: exec, attach, port-forward and proxy, secret reads
      and writes, token requests, DaemonSet and CronJob creation, and denied requests
    - changes to secrets, service accounts, RBAC, webhooks, admission policies and CRDs by anyone, except kubelet token
      requests

   It drops leases, Kubernetes events, status updates, GKE's own service account, denied anonymous requests,
   unauthenticated requests, and anonymous health and version checks (`healthz`, `livez`, `readyz`, `version`) that
   probes make constantly.
3. The `Pub/Sub Publisher` role on the topic for the sink's writer identity
4. The `stream-sec-gke-logs-pubsub` function (2nd gen, entry point `PubSubGKELogsCollection`), triggered by the topic
   and running as `streamsec-gke-audit`

The function runs once per audit log entry, and one instance runs up to 1000 at once. Entries that arrive together
are sent to Stream Security in one gzipped request: up to `--batch-size` entries (default 500), or what has arrived
`--batch-max-wait-ms` after the first (default 2000). A batch over the collection API's size limit is split. Failed
deliveries are logged and not retried.

The function reads these as `BATCH_SIZE` and `BATCH_MAX_WAIT_MS`. Without `BATCH_SIZE` it sends each entry on its own,
which is right for 1st gen functions and others that run one invocation at a time.

### Migrating from the bucket setup

1. Run the [Pub/Sub setup](#pubsub-setup-recommended). It uses new names, so it runs side by side with the bucket
   setup.
2. Wait for the next hourly file to be written to the bucket and processed.
3. Delete the old Log Router sink (`streamsec-gke-audit-logs`) and the `stream-sec-gke-logs-collection` function.
   Delete the bucket too if nothing else uses it.

Events logged while both setups run (up to an hour) may be sent twice.

### Cloud Storage bucket setup (legacy)

Requires:

1. Configured **Log Router** Sink to Cloud Storage Bucket
2. Cloud Storage service agent
   permission ([as specified here](https://cloud.google.com/functions/docs/calling/storage#permissions))
3. The collection token stored in [Secret Manager](https://console.cloud.google.com/security/secret-manager)

#### Steps to create a Secret for the collection token:

1. Go to [Secret Manager](https://console.cloud.google.com/security/secret-manager)
2. Click "Create Secret"
3. Fill in the details:
   - Name: Choose a name (e.g., `streamsec-gke-logs-token`)
   - Secret value: Paste your Stream Security collection token
   - For regional secrets: Select a region under "Replication policy" → "User managed" (optional)
4. Click "Create"
5. Grant the Cloud Function's service account the `Secret Manager Secret Accessor` role:
   - Service account (2nd gen, the gcloud default): `PROJECT_NUMBER-compute@developer.gserviceaccount.com`
   - Service account (1st gen): `PROJECT_ID@appspot.gserviceaccount.com`
   - You can grant via [IAM](https://console.cloud.google.com/iam-admin/iam) or on the secret's "Permissions" tab

#### Steps to create a Log Router Sink:

1. Go to the Logging page → [Logs Router](https://console.cloud.google.com/logs/router)
2. Click on "Create Sink"
3. Fill in the details:
    - Name: `streamsec-gke-audit-logs`
    - Sink Service: `Cloud Storage`
    - Sink Destination: `Select a bucket`
        - if you have a bucket, select it
        - Otherwise click on the icon of `Create New Bucket` and fill in the details
    - Sink Filter:
         ```
        resource.type="k8s_cluster"
        -protoPayload.authenticationInfo.principalEmail=~"system:"
        -protoPayload.authenticationInfo.principalEmail=~"@container-engine-robot.iam.gserviceaccount.com"
        -protoPayload.methodName="io.k8s.coordination.v1.leases.update"
        -protoPayload.methodName="io.k8s.networking.gateway.v1beta1.gatewayclasses.update"
        -(protoPayload.methodName="io.k8s.networking.gateway.v1beta1.gatewayclasses.status.update")
        protoPayload.methodName=~""
        ```
    - Click on "Create Sink"

#### Steps to Grant Access for Cloud Storage service agent:

1. Go to the IAM & Admin page → [IAM](https://console.cloud.google.com/iam-admin/iam)
2. Click on Grant Access
3. Use the following link
   to [Get the Cloud Storage service agent](https://cloud.google.com/storage/docs/getting-service-agent#get_the_email_address_of_a_projects_service_agent)
4. In the "New principals" field, paste the output from 'c' step or use this pattern (Replace \[PROJECT\_NUMBER\] with
   your project number):
   `service-[PROJECT_NUMBER]@gs-project-accounts.iam.gserviceaccount.com`
5. Assign Role:
    - In the "Select a role" dropdown, choose "Pub/Sub Publisher".
6. Click "Save".

#### Deploy the cloud function

Fill in the variables specified in one of files below and run.

1. Linux (`deploy.sh`)
2. Windows (`deploy.bat`)
