## GCP Flow logs integration

This document explains how to integrate GCP Flow logs to our product

### Requirements:

1. Flow logs enabled ([How to](https://cloud.google.com/vpc/docs/using-flow-logs))
    1. Output to Cloud Storage Bucket
    2. Metadata annotations enabled (this
       will [add necessary](https://cloud.google.com/vpc/docs/about-flow-logs-records#record_format) information such as
       VPC
       ID)
2. Configured Log Router Sink to Cloud Storage Bucket
3. Storage Trigger for Cloud Function
   Permission ([as specified here](https://cloud.google.com/functions/docs/calling/storage#permissions))

### Steps to Grant Access:

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

### Deploy the cloud function

Fill in the variables specified in one of files below and run.

1. Linux (`deploy.sh`)
2. Windows (`deploy.bat`)