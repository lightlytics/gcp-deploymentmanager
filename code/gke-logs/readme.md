## GKE audit logs integration

Sends the audit logs of your GKE clusters, the record of who did what in Kubernetes, to Stream Security.

### Choose a setup

**How the logs are delivered:**

| | Pub/Sub (recommended) | Cloud Storage bucket (legacy) |
|---|---|---|
| Logs reach Stream Security | Within seconds | 10-70 minutes later, in hourly files |
| Setup | One script: [Pub/Sub setup](#pubsub-setup-recommended) | Manual steps: [bucket setup](#cloud-storage-bucket-setup-legacy) |

Existing bucket setups keep working. To move one to Pub/Sub, see
[Migrating from the bucket setup](#migrating-from-the-bucket-setup).

**Which projects the Pub/Sub setup covers:**

| | One project | Organization or folder |
|---|---|---|
| Command | `bash setup-realtime.sh` | `bash setup-realtime.sh --organization ORG_ID`<br>or `--folder FOLDER_ID` |
| Collects from | That project's clusters | The clusters of every project under it |
| Collection token | That project's token | One token for all projects |
| Events go to | That project's workspace | The token's workspace, for every project |
| A new project | Needs its own run | Is collected automatically, unless you limited it with `--projects` |
| Choose it when | You connect a few projects, your projects belong to different workspaces, or you don't have permissions on the organization | All your projects belong to one workspace and you want one setup for all of them |

Use one or the other for each project: a project covered by both sends its events twice.

### Before you start

- GKE clusters with **Cloud Monitoring** enabled (_API Server logging_)
- Your Stream Security collection token
- Billing enabled in the project that will run the function
- For the Pub/Sub setup, Project Owner in that project covers every permission the script needs. For an organization or
  folder you also need Logs Configuration Writer (`roles/logging.configWriter`) on it. The script checks before
  changing anything and lists anything missing.

### Pub/Sub setup (recommended)

Open [Cloud Shell](https://shell.cloud.google.com) and download the script:

```bash
curl -fsSLO https://raw.githubusercontent.com/lightlytics/gcp-deploymentmanager/master/code/gke-logs/setup-realtime.sh
```

The script asks for anything you don't pass as an option: the project, the URL you open Stream Security at, and the
collection token (hidden as you type). It shows what it will set up and asks you to confirm before changing anything.

#### One project

```bash
bash setup-realtime.sh
```

Run it in each project you want to collect from.

#### Every project in an organization or folder

```bash
bash setup-realtime.sh --organization ORGANIZATION_ID
# or
bash setup-realtime.sh --folder FOLDER_ID
```

- **Where it installs.** The Log Router sink goes on the organization or folder and covers every project under it,
  including projects created later. Everything else (the secret, service account, topic and function) is created once,
  in your current gcloud project. Use `--project` to pick another one.
- **Which token.** Use the collection token of any GCP project connected to Stream Security. Every project's events go
  to that token's workspace. Clusters in projects that aren't connected to Stream Security are collected too, but
  aren't linked to your inventory.
- **Cluster list.** Before you confirm, the script lists the GKE clusters it finds, using Cloud Asset Inventory (Cloud
  Asset Viewer on the organization or folder). The list is only for your information: if the script can't get it, it
  says why and continues.
- **Only some projects.** `--projects p1,p2` collects only those projects.
- **Replacing per-project setups.** Once this setup is running, remove each per-project setup with
  `bash setup-realtime.sh --project THAT_PROJECT --uninstall`, or its events are sent twice. The exception is the
  project that runs the function: the script replaces its per-project sink itself, and an `--uninstall` there without
  `--organization` would remove the function the whole organization uses.

#### What the script does

1. Checks that you can make every change it needs. If not, it lists what's missing and stops before changing anything.
2. Enables the APIs it needs: Cloud Functions, Cloud Run, Cloud Build, Artifact Registry, Eventarc, Pub/Sub, Cloud
   Logging, Secret Manager and IAM, plus Cloud Asset for an organization or folder.
3. Stores the collection token in the secret `streamsec-gke-logs-token`, or reuses that secret if it exists.
4. Creates the service account `streamsec-gke-audit`. It can only read that secret and invoke the function.
5. Creates the Pub/Sub topic `streamsec-gke-audit-logs`, and the Log Router sink `streamsec-gke-audit-logs-pubsub`
   that publishes the audit logs to it.
6. Deploys the function `stream-sec-gke-logs-pubsub` (2nd gen), which sends the logs to Stream Security.
7. Checks that the function is active, and prints how to test it.

Running it again is safe: it reuses what exists and applies the current settings.

#### Options

`bash setup-realtime.sh --help` lists every option. The most common:

| Option | What it does |
|---|---|
| `--project ID` | The project to collect from. With `--organization` or `--folder`, the project that runs the function |
| `--projects P1,P2` | With `--organization` or `--folder`, collect only these projects |
| `--cluster NAME` | Collect only this cluster. Repeat it for more clusters |
| `--api-url URL` | The URL you open Stream Security at |
| `--region REGION` | Where the function runs (default `us-central1`) |
| `--secret-location LOC` | Store the token in a regional secret in this region |
| `--batch-size N` | Send up to N log entries per request, 1 to 1000 (default 500) |
| `--batch-max-wait-ms MS` | Send a batch this long after its first entry even if it isn't full, 1 to 30000 (default 2000) |
| `--yes` | Don't ask for confirmation |

To run it unattended, pass every value as an option, add `--yes`, and put the token in the environment variable
`STREAMSEC_COLLECTION_TOKEN`.

#### Check that it works

Make a change in a cluster as yourself, for example:

```bash
kubectl create configmap streamsec-test -n default && kubectl delete configmap streamsec-test -n default
```

A few minutes later the events appear in Stream Security under **Log Explorer > Kubernetes**. The script's last
message shows how to see the function's runs. Right after a first install, runs can fail with status 403 for a minute
or two while Google applies the new service account's permissions. Pub/Sub retries them, so those events arrive a
little later.

#### Remove it

Run the script with the options you installed with, plus `--uninstall`:

```bash
bash setup-realtime.sh --project PROJECT_ID --uninstall
bash setup-realtime.sh --organization ORGANIZATION_ID --project PROJECT_ID --uninstall
```

This removes the sink, function, topic and service account. It keeps the secret unless you add `--delete-secret`. If
you installed with `--region`, pass the same region.

#### How it works

The Log Router sink publishes each audit log entry to the topic, and the function sends the entries to Stream
Security.

**Which entries are sent.** The sink's filter is `LOG_FILTER` in `setup-realtime.sh`, plus a clause for `--projects`
or `--cluster` if you used them. It sends:

- everything done by people and other non-system identities
- successful anonymous requests
- for workload service accounts outside the system namespaces: exec, attach, port-forward and proxy, secret reads and
  writes, token requests, DaemonSet and CronJob creation, and denied requests
- changes to secrets, service accounts, RBAC, webhooks, admission policies and CRDs by anyone, except kubelet token
  requests

It leaves out routine noise: leases, Kubernetes events, status updates, GKE's own service account, denied anonymous
requests, unauthenticated requests, and the anonymous health and version checks (`healthz`, `livez`, `readyz`,
`version`) that probes make constantly.

**Batching.** Entries that arrive together are sent in one gzipped request: up to `--batch-size` entries, or whatever
has arrived `--batch-max-wait-ms` after the first. A batch over the collection API's size limit is split. Failed
deliveries are logged and not retried.

The function reads these settings from the environment variables `BATCH_SIZE` and `BATCH_MAX_WAIT_MS`. Without
`BATCH_SIZE` it sends each entry on its own, which is right for 1st gen functions and others that run one invocation
at a time.

### Migrating from the bucket setup

1. Run the [Pub/Sub setup](#pubsub-setup-recommended). It uses different names, so it runs side by side with the
   bucket setup.
2. Wait until the next hourly file is written to the bucket and processed.
3. Delete the old Log Router sink (`streamsec-gke-audit-logs`) and the `stream-sec-gke-logs-collection` function.
   Delete the bucket too if nothing else uses it.

Events logged while both setups run (up to an hour) may be sent twice.

### Cloud Storage bucket setup (legacy)

Cloud Logging writes the audit logs to a bucket in hourly files, and a function sends each new file to Stream
Security. Setting it up takes four steps.

#### 1. Store the collection token in Secret Manager

1. Go to [Secret Manager](https://console.cloud.google.com/security/secret-manager) and click **Create Secret**.
2. Fill in:
   - **Name:** for example `streamsec-gke-logs-token`
   - **Secret value:** your Stream Security collection token
   - **Replication policy:** for a regional secret, choose **User managed** and a region (optional)
3. Click **Create**.
4. Give the function's service account the **Secret Manager Secret Accessor** role, in
   [IAM](https://console.cloud.google.com/iam-admin/iam) or on the secret's **Permissions** tab:
   - 2nd gen (the gcloud default): `PROJECT_NUMBER-compute@developer.gserviceaccount.com`
   - 1st gen: `PROJECT_ID@appspot.gserviceaccount.com`

#### 2. Create the Log Router sink

1. Go to [Logs Router](https://console.cloud.google.com/logs/router) and click **Create Sink**.
2. Fill in:
   - **Name:** `streamsec-gke-audit-logs`
   - **Sink service:** Cloud Storage
   - **Sink destination:** select your bucket, or click **Create New Bucket**
   - **Filter:**
     ```
     resource.type="k8s_cluster"
     -protoPayload.authenticationInfo.principalEmail=~"system:"
     -protoPayload.authenticationInfo.principalEmail=~"@container-engine-robot.iam.gserviceaccount.com"
     -protoPayload.methodName="io.k8s.coordination.v1.leases.update"
     -protoPayload.methodName="io.k8s.networking.gateway.v1beta1.gatewayclasses.update"
     -(protoPayload.methodName="io.k8s.networking.gateway.v1beta1.gatewayclasses.status.update")
     protoPayload.methodName=~""
     ```
3. Click **Create Sink**.

#### 3. Let Cloud Storage trigger the function

Give the Cloud Storage service agent the **Pub/Sub Publisher** role
([why](https://cloud.google.com/functions/docs/calling/storage#permissions)):

1. Find the service agent's email
   ([how](https://cloud.google.com/storage/docs/getting-service-agent#get_the_email_address_of_a_projects_service_agent)).
   It looks like `service-PROJECT_NUMBER@gs-project-accounts.iam.gserviceaccount.com`.
2. Go to [IAM](https://console.cloud.google.com/iam-admin/iam) and click **Grant Access**.
3. Paste the email under **New principals**, choose the **Pub/Sub Publisher** role, and click **Save**.

#### 4. Deploy the function

Fill in the variables at the top of `deploy.sh` (Linux) or `deploy.bat` (Windows), then run it.
