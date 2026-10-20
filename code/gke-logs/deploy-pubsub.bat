@echo off

set PROJECT_ID=YOUR_PROJECT_ID
set REGION=us-central1
REM Pub/Sub topic the Log Router sink publishes to
set TOPIC_NAME=streamsec-gke-audit-logs
REM Log Router sink that publishes the GKE audit logs
set SINK_NAME=streamsec-gke-audit-logs-pubsub
set SOURCE_URL=gs://streamsec-production-public-artifacts/gcp-gke-logs-collection.zip
set RUNTIME=nodejs22

set API_URL=https://YOUR_ENV.streamsec.io
REM Name of the secret in Secret Manager containing the API token
set SECRET_NAME=YOUR_SECRET_NAME
REM Leave SECRET_LOCATION empty for global secrets, or set to region (e.g., us-central1) for regional secrets
set SECRET_LOCATION=

set LOG_FILTER=resource.type=\"k8s_cluster\" -protoPayload.authenticationInfo.principalEmail=~\"system:\" -protoPayload.authenticationInfo.principalEmail=~\"@container-engine-robot.iam.gserviceaccount.com\" -protoPayload.methodName=\"io.k8s.coordination.v1.leases.update\" -protoPayload.methodName=\"io.k8s.networking.gateway.v1beta1.gatewayclasses.update\" -(protoPayload.methodName=\"io.k8s.networking.gateway.v1beta1.gatewayclasses.status.update\") protoPayload.methodName=~\"\"

if "%SECRET_LOCATION%"=="" (
  set SECRET_PATH=projects/%PROJECT_ID%/secrets/%SECRET_NAME%/versions/latest
) else (
  set SECRET_PATH=projects/%PROJECT_ID%/locations/%SECRET_LOCATION%/secrets/%SECRET_NAME%/versions/latest
)

REM Create the topic and the Log Router sink that publishes each GKE audit log entry to it
call gcloud pubsub topics create %TOPIC_NAME% --project %PROJECT_ID%

call gcloud logging sinks create %SINK_NAME% pubsub.googleapis.com/projects/%PROJECT_ID%/topics/%TOPIC_NAME% ^
  --log-filter="%LOG_FILTER%" ^
  --project %PROJECT_ID%

REM Allow the sink to publish to the topic
for /f "delims=" %%i in ('gcloud logging sinks describe %SINK_NAME% --project %PROJECT_ID% --format "value(writerIdentity)"') do set WRITER_IDENTITY=%%i

call gcloud pubsub topics add-iam-policy-binding %TOPIC_NAME% ^
  --member %WRITER_IDENTITY% ^
  --role roles/pubsub.publisher ^
  --project %PROJECT_ID%

call gcloud functions deploy stream-sec-gke-logs-pubsub ^
  --region %REGION% ^
  --runtime %RUNTIME% ^
  --trigger-topic %TOPIC_NAME% ^
  --entry-point PubSubGKELogsCollection ^
  --source %SOURCE_URL% ^
  --project %PROJECT_ID% ^
  --set-env-vars API_URL=%API_URL%,SECRET_NAME=%SECRET_PATH%
