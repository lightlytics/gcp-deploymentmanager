#!/bin/bash

# Variables
PROJECT_ID=YOUR_PROJECT_ID # Your GCP Project ID
BUCKET_NAME=YOUR_BUCKET # Where the flowlogs are stored
REGION=us-central1 # Region where the function will be deployed
TRIGGER_LOCATION=us # {us|eu|asia} - Location of the bucket
SOURCE_URL=gs://streamsec-production-public-artifacts/gcp-log-collection.zip # URL of the public GCS file
RUNTIME=nodejs22

# Environment Variables
API_URL=https://YOUR_ENV.streamsec.io
SECRET_NAME=YOUR_SECRET_NAME # Name of the secret in Secret Manager containing the API token
SECRET_LOCATION= # Leave empty for global secrets, or set to region (e.g., us-central1) for regional secrets

if [ -z "$SECRET_LOCATION" ]; then
  SECRET_PATH="projects/$PROJECT_ID/secrets/$SECRET_NAME/versions/latest"
else
  SECRET_PATH="projects/$PROJECT_ID/locations/$SECRET_LOCATION/secrets/$SECRET_NAME/versions/latest"
fi

# Deploy the function
gcloud functions deploy StreamSecFlowLogsCollection \
  --region $REGION \
  --runtime $RUNTIME \
  --trigger-resource $BUCKET_NAME \
  --trigger-event google.storage.object.finalize \
  --trigger-location=$TRIGGER_LOCATION \
  --entry-point StorageFlowlogsCollection \
  --source $SOURCE_URL \
  --project $PROJECT_ID \
  --set-env-vars API_URL=$API_URL,SECRET_NAME=$SECRET_PATH