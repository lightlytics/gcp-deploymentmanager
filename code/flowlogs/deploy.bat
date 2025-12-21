@echo off

set PROJECT_ID=YOUR_PROJECT_ID
set BUCKET_NAME=YOUR_BUCKET
set REGION=us-central1
set TRIGGER_LOCATION=us
set SOURCE_URL=gs://streamsec-public-artifacts/gcp-flow-logs-collection.zip
set RUNTIME=nodejs22

set API_URL=https://YOUR_ENV.streamsec.io
REM Name of the secret in Secret Manager containing the API token
set SECRET_NAME=YOUR_SECRET_NAME
REM Leave SECRET_LOCATION empty for global secrets, or set to region (e.g., us-central1) for regional secrets
set SECRET_LOCATION=

if "%SECRET_LOCATION%"=="" (
  set SECRET_PATH=projects/%PROJECT_ID%/secrets/%SECRET_NAME%/versions/latest
) else (
  set SECRET_PATH=projects/%PROJECT_ID%/locations/%SECRET_LOCATION%/secrets/%SECRET_NAME%/versions/latest
)

gcloud functions deploy prod-stream-sec-flowlogs-collection --region %REGION% --runtime %RUNTIME% --trigger-resource %BUCKET_NAME% --trigger-event google.storage.object.finalize --trigger-location=%TRIGGER_LOCATION% --entry-point StorageFlowlogsCollection --source %SOURCE_URL% --project %PROJECT_ID% --set-env-vars API_URL=%API_URL%,SECRET_NAME=%SECRET_PATH%