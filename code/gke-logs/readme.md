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
2. API token stored in [Secret Manager](https://console.cloud.google.com/security/secret-manager)

### Create a Secret for the API Token

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

### Pub/Sub setup (recommended)

Fill in the variables specified in one of files below and run.

1. Linux (`deploy-pubsub.sh`)
2. Windows (`deploy-pubsub.bat`)

The script:

1. Creates the Pub/Sub topic `streamsec-gke-audit-logs`
2. Creates the Log Router sink `streamsec-gke-audit-logs-pubsub` that publishes to the topic, with the filter:
    ```
    resource.type="k8s_cluster"
    -protoPayload.authenticationInfo.principalEmail=~"system:"
    -protoPayload.authenticationInfo.principalEmail=~"@container-engine-robot.iam.gserviceaccount.com"
    -protoPayload.methodName="io.k8s.coordination.v1.leases.update"
    -protoPayload.methodName="io.k8s.networking.gateway.v1beta1.gatewayclasses.update"
    -(protoPayload.methodName="io.k8s.networking.gateway.v1beta1.gatewayclasses.status.update")
    protoPayload.methodName=~""
    ```
3. Grants the sink's writer identity the `Pub/Sub Publisher` role on the topic
4. Deploys the `stream-sec-gke-logs-pubsub` function, triggered by the topic (entry point `PubSubGKELogsCollection`)

The function runs once per audit log entry. Failed deliveries are logged and not retried.

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
