@echo off

set PROJECT_ID=YOUR_PROJECT_ID
set BUCKET_NAME=YOUR_BUCKET
set REGION=us-central1
set TRIGGER_LOCATION=us
set SOURCE_URL=gs://streamsec-public-artifacts/gcp-gke-logs-collection.zip
set RUNTIME=nodejs22

set API_URL=https://YOUR_ENV.streamsec.io
set API_TOKEN=YOUR_COLLECTION_TOKEN

gcloud functions deploy stream-sec-gke-logs-collection ^
  --region %REGION% ^
  --runtime %RUNTIME% ^
  --trigger-resource %BUCKET_NAME% ^
  --trigger-event google.storage.object.finalize ^
  --trigger-location=%TRIGGER_LOCATION% ^
  --entry-point StorageGKELogsCollection ^
  --source %SOURCE_URL% ^
  --project %PROJECT_ID% ^
  --set-env-vars API_URL=%API_URL%,API_TOKEN=%API_TOKEN%