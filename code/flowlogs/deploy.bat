@echo off

:: Variables
set PROJECT_ID=YOUR_PROJECT_ID :: Your GCP Project ID
set BUCKET_NAME=YOUR_BUCKET_NAME :: Name of the GCP bucket where flow logs are stored
set REGION=us-central1 :: Region where the function will be deployed
set TRIGGER_LOCATION=us :: Location of the bucket (us, eu, asia)
set SOURCE_URL=gs://streamsec-production-public-artifacts/gcp-flow-logs-collection.zip
set RUNTIME=nodejs20

:: Environment Variables
set API_URL=https://YOUR_ENV.streamsec.io
set API_TOKEN=YOUR_COLLECTION_TOKEN

:: Deploy the function
gcloud functions deploy StreamSecFlowLogsCollection ^
  --region %REGION% ^
  --runtime %RUNTIME% ^
  --trigger-resource %BUCKET_NAME% ^
  --trigger-event google.storage.object.finalize ^
  --trigger-location=%TRIGGER_LOCATION% ^
  --entry-point StorageFlowlogsCollection ^
  --source %SOURCE_URL% ^
  --project %PROJECT_ID% ^
  --set-env-vars API_URL=%API_URL%,API_TOKEN=%API_TOKEN%