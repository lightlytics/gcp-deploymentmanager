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
API_TOKEN=YOUR_COLLECTION_TOKEN

# Deploy the function
gcloud functions deploy StreamSecFlowLogsCollection \
  --region $REGION \
  --runtime $RUNTIME \
  --trigger-resource $BUCKET_NAME \
  --trigger-event google.storage.object.finalize \
  --trigger-location=$TRIGGER_LOCATION \
  --entry-point StorageFlowlogsCollection \
  --source $SOURCE_DIR \
  --project $PROJECT_ID \
  --set-env-vars API_URL=$API_URL,API_TOKEN=$API_TOKEN