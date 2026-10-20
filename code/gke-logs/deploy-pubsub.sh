#!/bin/bash

# Variables
PROJECT_ID=YOUR_PROJECT_ID # Your GCP Project ID
REGION=us-central1 # Region where the function will be deployed
TOPIC_NAME=streamsec-gke-audit-logs # Pub/Sub topic the Log Router sink publishes to
SINK_NAME=streamsec-gke-audit-logs-pubsub # Log Router sink that publishes the GKE audit logs
SOURCE_URL=gs://streamsec-production-public-artifacts/gcp-gke-logs-collection.zip
RUNTIME=nodejs22

# Environment Variables
API_URL=https://YOUR_ENV.streamsec.io
SECRET_NAME=YOUR_SECRET_NAME # Name of the secret in Secret Manager containing the API token
SECRET_LOCATION= # Leave empty for global secrets, or set to region (e.g., us-central1) for regional secrets

LOG_FILTER='resource.type="k8s_cluster"
-protoPayload.authenticationInfo.principalEmail=~"system:"
-protoPayload.authenticationInfo.principalEmail=~"@container-engine-robot.iam.gserviceaccount.com"
-protoPayload.methodName="io.k8s.coordination.v1.leases.update"
-protoPayload.methodName="io.k8s.networking.gateway.v1beta1.gatewayclasses.update"
-(protoPayload.methodName="io.k8s.networking.gateway.v1beta1.gatewayclasses.status.update")
protoPayload.methodName=~""'

if [ -z "$SECRET_LOCATION" ]; then
  SECRET_PATH="projects/$PROJECT_ID/secrets/$SECRET_NAME/versions/latest"
else
  SECRET_PATH="projects/$PROJECT_ID/locations/$SECRET_LOCATION/secrets/$SECRET_NAME/versions/latest"
fi

# Create the topic and the Log Router sink that publishes each GKE audit log entry to it
gcloud pubsub topics create $TOPIC_NAME --project $PROJECT_ID

gcloud logging sinks create $SINK_NAME pubsub.googleapis.com/projects/$PROJECT_ID/topics/$TOPIC_NAME \
  --log-filter="$LOG_FILTER" \
  --project $PROJECT_ID

# Allow the sink to publish to the topic
WRITER_IDENTITY=$(gcloud logging sinks describe $SINK_NAME --project $PROJECT_ID --format "value(writerIdentity)")

gcloud pubsub topics add-iam-policy-binding $TOPIC_NAME \
  --member $WRITER_IDENTITY \
  --role roles/pubsub.publisher \
  --project $PROJECT_ID

# Deploy the function
gcloud functions deploy stream-sec-gke-logs-pubsub \
  --region $REGION \
  --runtime $RUNTIME \
  --trigger-topic $TOPIC_NAME \
  --entry-point PubSubGKELogsCollection \
  --source $SOURCE_URL \
  --project $PROJECT_ID \
  --set-env-vars API_URL=$API_URL,SECRET_NAME=$SECRET_PATH
