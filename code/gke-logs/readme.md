## GKE audit logs integration

This document explains how to integrate GKE audit logs to our product

### Requirements:

1. GKE cluster with "**Cloud Monitoring**" enabled (_API Server logging_)
2. Configured **Log Router** Sink to Cloud Storage Bucket
3. Cloud Storage service agent
   permission ([as specified here](https://cloud.google.com/functions/docs/calling/storage#permissions))
4. API token stored in [Secret Manager](https://console.cloud.google.com/security/secret-manager)

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

### Create a Secret for the API Token

1. Go to [Secret Manager](https://console.cloud.google.com/security/secret-manager)
2. Click "Create Secret"
3. Fill in the details:
   - Name: Choose a name (e.g., `streamsec-gke-logs-token`)
   - Secret value: Paste your Stream Security collection token
   - For regional secrets: Select a region under "Replication policy" → "User managed" (optional)
4. Click "Create"
5. Grant the Cloud Function's service account the `Secret Manager Secret Accessor` role:
   - Service account: `PROJECT_ID@appspot.gserviceaccount.com`
   - You can grant via [IAM](https://console.cloud.google.com/iam-admin/iam) or on the secret's "Permissions" tab

### Deploy the cloud function

Fill in the variables specified in one of files below and run.

1. Linux (`deploy.sh`)
2. Windows (`deploy.bat`)