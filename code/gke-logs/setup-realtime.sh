#!/bin/bash
# Sets up real-time GKE audit log collection for Stream Security in one GCP
# project: checks permissions, enables the APIs, stores the collection token in
# Secret Manager, creates a service account, a Pub/Sub topic and a Log Router
# sink, and deploys the function that forwards each audit event.
# Run with --uninstall to remove it. Run with --help for the options.
set -euo pipefail

TOPIC=streamsec-gke-audit-logs
SINK=streamsec-gke-audit-logs-pubsub
FUNCTION=stream-sec-gke-logs-pubsub
SERVICE_ACCOUNT_ID=streamsec-gke-audit
RUNTIME=nodejs22
DEFAULT_SOURCE=gs://streamsec-production-public-artifacts/gcp-gke-logs-collection.zip

APIS=(
  cloudfunctions.googleapis.com
  run.googleapis.com
  cloudbuild.googleapis.com
  artifactregistry.googleapis.com
  eventarc.googleapis.com
  pubsub.googleapis.com
  logging.googleapis.com
  secretmanager.googleapis.com
  iam.googleapis.com
)

INSTALL_PERMISSIONS=(
  serviceusage.services.enable
  secretmanager.secrets.create
  secretmanager.secrets.get
  secretmanager.secrets.setIamPolicy
  secretmanager.versions.add
  iam.serviceAccounts.create
  iam.serviceAccounts.get
  iam.serviceAccounts.actAs
  pubsub.topics.create
  pubsub.topics.get
  pubsub.topics.setIamPolicy
  logging.sinks.create
  logging.sinks.get
  logging.sinks.update
  cloudfunctions.functions.create
  cloudfunctions.functions.get
  cloudfunctions.functions.update
  run.services.setIamPolicy
)

UNINSTALL_PERMISSIONS=(
  logging.sinks.delete
  cloudfunctions.functions.delete
  pubsub.topics.delete
  iam.serviceAccounts.delete
)

LOG_FILTER='resource.type="k8s_cluster"
-protoPayload.authenticationInfo.principalEmail=~"system:"
-protoPayload.authenticationInfo.principalEmail=~"@container-engine-robot.iam.gserviceaccount.com"
-protoPayload.methodName="io.k8s.coordination.v1.leases.update"
-protoPayload.methodName="io.k8s.networking.gateway.v1beta1.gatewayclasses.update"
-(protoPayload.methodName="io.k8s.networking.gateway.v1beta1.gatewayclasses.status.update")
protoPayload.methodName=~""'

PROJECT_ID=
API_URL=
REGION=us-central1
SECRET_NAME=streamsec-gke-logs-token
SECRET_LOCATION=
CLUSTERS=()
SOURCE=$DEFAULT_SOURCE
UNINSTALL=false
DELETE_SECRET=false
ASSUME_YES=false

usage() {
  cat <<EOF
Usage: bash setup-realtime.sh [options]

Sends the GKE audit logs of one GCP project to Stream Security in real time.
Anything required and not given as an option is asked for.

Options:
  --project ID            GCP project that holds the GKE clusters
  --api-url URL           The URL you open Stream Security at, e.g. https://app.streamsec.io
  --region REGION         Region of the function (default: $REGION)
  --secret-name NAME      Secret Manager secret with the collection token (default: $SECRET_NAME).
                          An existing secret is reused; otherwise it is created and the token
                          is read from STREAMSEC_COLLECTION_TOKEN or asked for without echo.
  --secret-location LOC   Region of a regional secret (default: a global secret)
  --cluster NAME          Collect only this cluster's audit logs; repeat for more clusters
                          (default: every cluster in the project)
  --source URL            Function source (default: $DEFAULT_SOURCE)
  --uninstall             Remove the sink, function, topic and service account
  --delete-secret         With --uninstall, also delete the secret
  --yes                   Do not ask for confirmation
  -h, --help              Show this help
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

step() {
  echo
  echo "==> $*"
}

info() {
  echo "    $*"
}

interactive() {
  [ -t 0 ]
}

confirm() {
  local answer
  "$ASSUME_YES" && return 0
  interactive || die "Nothing changed. Run with --yes to continue without a prompt."
  read -r -p "$1 [y/N] " answer
  case "$answer" in
    [Yy]*) return 0 ;;
    *) die "Cancelled, nothing changed." ;;
  esac
}

# Retries a command a few times: IAM changes on a new service account can fail
# until the account has propagated
retry() {
  local attempt=1
  until "$@"; do
    [ "$attempt" -ge 6 ] && return 1
    info "Not ready yet, retrying in 10 seconds..."
    sleep 10
    attempt=$((attempt + 1))
  done
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --project) PROJECT_ID=${2:?--project needs a value}; shift ;;
      --api-url) API_URL=${2:?--api-url needs a value}; shift ;;
      --region) REGION=${2:?--region needs a value}; shift ;;
      --secret-name) SECRET_NAME=${2:?--secret-name needs a value}; shift ;;
      --secret-location) SECRET_LOCATION=${2:?--secret-location needs a value}; shift ;;
      --cluster) CLUSTERS+=("${2:?--cluster needs a value}"); shift ;;
      --source) SOURCE=${2:?--source needs a value}; shift ;;
      --uninstall) UNINSTALL=true ;;
      --delete-secret) DELETE_SECRET=true ;;
      --yes) ASSUME_YES=true ;;
      -h | --help) usage; exit 0 ;;
      *) usage >&2; die "Unknown option: $1" ;;
    esac
    shift
  done
}

ask_for_missing() {
  local default
  if [ -z "$PROJECT_ID" ]; then
    interactive || die "Pass --project (the GCP project that holds the GKE clusters)."
    default=$(gcloud config get-value project 2>/dev/null || true)
    read -r -p "GCP project ID${default:+ [$default]}: " PROJECT_ID
    PROJECT_ID=${PROJECT_ID:-$default}
    [ -n "$PROJECT_ID" ] || die "A project ID is required."
  fi
  if ! "$UNINSTALL" && [ -z "$API_URL" ]; then
    interactive || die "Pass --api-url (the URL you open Stream Security at)."
    read -r -p "Stream Security URL (e.g. https://app.streamsec.io): " API_URL
    [ -n "$API_URL" ] || die "The Stream Security URL is required."
  fi
}

check_account_and_project() {
  step "Checking your access"
  ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n 1)
  [ -n "$ACCOUNT" ] || die "gcloud is not logged in. Run: gcloud auth login"
  PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)' 2>/dev/null) ||
    die "Project $PROJECT_ID was not found, or $ACCOUNT cannot see it."
  SERVICE_ACCOUNT="$SERVICE_ACCOUNT_ID@$PROJECT_ID.iam.gserviceaccount.com"
  info "Account: $ACCOUNT"
  info "Project: $PROJECT_ID ($PROJECT_NUMBER)"
}

role_for() {
  case "$1" in
    serviceusage.*) echo roles/serviceusage.serviceUsageAdmin ;;
    secretmanager.*) echo roles/secretmanager.admin ;;
    iam.serviceAccounts.actAs) echo roles/iam.serviceAccountUser ;;
    iam.serviceAccounts.*) echo roles/iam.serviceAccountAdmin ;;
    pubsub.*) echo roles/pubsub.admin ;;
    logging.*) echo roles/logging.configWriter ;;
    cloudfunctions.*) echo roles/cloudfunctions.developer ;;
    run.*) echo roles/run.admin ;;
    *) echo roles/owner ;;
  esac
}

# Asks Cloud Resource Manager which of the permissions the account holds on the
# project, and stops before any change if one is missing
check_permissions() {
  local body response granted permission missing=()
  body=$(printf '"%s",' "$@")
  body="{\"permissions\":[${body%,}]}"
  if ! response=$(curl -sS -X POST \
    -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    -H "Content-Type: application/json" \
    "https://cloudresourcemanager.googleapis.com/v1/projects/$PROJECT_ID:testIamPermissions" \
    -d "$body" 2>&1) || [[ "$response" == *'"error"'* ]]; then
    info "Could not check permissions, continuing. Response: $response"
    return 0
  fi
  granted=$(printf '%s' "$response" | grep -oE '"[a-z]+(\.[A-Za-z]+)+"' | tr -d '"' || true)
  for permission in "$@"; do
    printf '%s\n' "$granted" | grep -qxF "$permission" || missing+=("$permission")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: $ACCOUNT is missing these permissions on project $PROJECT_ID:" >&2
    for permission in "${missing[@]}"; do
      printf '         %-40s in %s\n' "$permission" "$(role_for "$permission")" >&2
    done
    echo "       Project Owner includes all of them. Nothing was changed." >&2
    exit 1
  fi
  info "You have the permissions this needs."
}

secret_flags() {
  printf '%s\n' --project "$PROJECT_ID"
  if [ -n "$SECRET_LOCATION" ]; then printf '%s\n' --location "$SECRET_LOCATION"; fi
}

secret_exists() {
  # shellcheck disable=SC2046
  gcloud secrets describe "$SECRET_NAME" $(secret_flags) >/dev/null 2>&1
}

sink_filter() {
  local filter=$LOG_FILTER cluster clause=
  for cluster in ${CLUSTERS[@]+"${CLUSTERS[@]}"}; do
    clause="${clause:+$clause OR }resource.labels.cluster_name=\"$cluster\""
  done
  [ -n "$clause" ] && filter="$filter
($clause)"
  printf '%s' "$filter"
}

install() {
  local secret_path secret_state token writer state clusters_text
  check_account_and_project
  check_permissions "${INSTALL_PERMISSIONS[@]}"

  if [ -n "$SECRET_LOCATION" ]; then
    secret_path="projects/$PROJECT_ID/locations/$SECRET_LOCATION/secrets/$SECRET_NAME/versions/latest"
  else
    secret_path="projects/$PROJECT_ID/secrets/$SECRET_NAME/versions/latest"
  fi
  if secret_exists; then secret_state="exists, will be reused"; else secret_state="will be created"; fi
  clusters_text="all clusters in the project"
  [ ${#CLUSTERS[@]} -gt 0 ] && clusters_text="${CLUSTERS[*]}"

  step "This will set up, in project $PROJECT_ID:"
  info "Secret:          $SECRET_NAME ${SECRET_LOCATION:+in $SECRET_LOCATION }($secret_state)"
  info "Service account: $SERVICE_ACCOUNT"
  info "Pub/Sub topic:   $TOPIC"
  info "Log Router sink: $SINK (collects: $clusters_text)"
  info "Function:        $FUNCTION in $REGION, sending to $API_URL"
  confirm "Continue?"

  step "Enabling APIs"
  gcloud services enable "${APIS[@]}" --project "$PROJECT_ID"

  step "Collection token"
  if [ "$secret_state" = "will be created" ]; then
    token=${STREAMSEC_COLLECTION_TOKEN:-}
    if [ -z "$token" ]; then
      interactive || die "Secret $SECRET_NAME does not exist. Set STREAMSEC_COLLECTION_TOKEN or run interactively to enter the token."
      read -r -s -p "Stream Security collection token (not shown): " token
      echo
    fi
    [ -n "$token" ] || die "The collection token is empty."
    if [ -n "$SECRET_LOCATION" ]; then
      printf '%s' "$token" | gcloud secrets create "$SECRET_NAME" --project "$PROJECT_ID" \
        --location "$SECRET_LOCATION" --data-file=- >/dev/null
    else
      printf '%s' "$token" | gcloud secrets create "$SECRET_NAME" --project "$PROJECT_ID" \
        --replication-policy automatic --data-file=- >/dev/null
    fi
    token=
    info "Created secret $SECRET_NAME"
  else
    info "Using existing secret $SECRET_NAME"
  fi

  step "Service account"
  if gcloud iam service-accounts describe "$SERVICE_ACCOUNT" --project "$PROJECT_ID" >/dev/null 2>&1; then
    info "Using existing $SERVICE_ACCOUNT"
  else
    gcloud iam service-accounts create "$SERVICE_ACCOUNT_ID" --project "$PROJECT_ID" \
      --display-name "Stream Security GKE audit logs" >/dev/null
    info "Created $SERVICE_ACCOUNT"
  fi
  # shellcheck disable=SC2046
  retry gcloud secrets add-iam-policy-binding "$SECRET_NAME" $(secret_flags) \
    --member "serviceAccount:$SERVICE_ACCOUNT" --role roles/secretmanager.secretAccessor >/dev/null
  info "It can read secret $SECRET_NAME"

  step "Pub/Sub topic"
  if gcloud pubsub topics describe "$TOPIC" --project "$PROJECT_ID" >/dev/null 2>&1; then
    info "Using existing topic $TOPIC"
  else
    gcloud pubsub topics create "$TOPIC" --project "$PROJECT_ID" >/dev/null
    info "Created topic $TOPIC"
  fi

  step "Log Router sink"
  if gcloud logging sinks describe "$SINK" --project "$PROJECT_ID" >/dev/null 2>&1; then
    gcloud logging sinks update "$SINK" "pubsub.googleapis.com/projects/$PROJECT_ID/topics/$TOPIC" \
      --log-filter "$(sink_filter)" --project "$PROJECT_ID" >/dev/null 2>&1
    info "Updated sink $SINK"
  else
    gcloud logging sinks create "$SINK" "pubsub.googleapis.com/projects/$PROJECT_ID/topics/$TOPIC" \
      --log-filter "$(sink_filter)" --project "$PROJECT_ID" >/dev/null 2>&1
    info "Created sink $SINK"
  fi
  writer=$(gcloud logging sinks describe "$SINK" --project "$PROJECT_ID" --format='value(writerIdentity)')
  retry gcloud pubsub topics add-iam-policy-binding "$TOPIC" --project "$PROJECT_ID" \
    --member "$writer" --role roles/pubsub.publisher >/dev/null
  info "The sink can publish to $TOPIC"

  step "Deploying function $FUNCTION (takes a few minutes)"
  gcloud functions deploy "$FUNCTION" --gen2 --project "$PROJECT_ID" --region "$REGION" \
    --runtime "$RUNTIME" --source "$SOURCE" --entry-point PubSubGKELogsCollection \
    --trigger-topic "$TOPIC" \
    --service-account "$SERVICE_ACCOUNT" --trigger-service-account "$SERVICE_ACCOUNT" \
    --set-env-vars "API_URL=$API_URL,SECRET_NAME=$secret_path" --quiet --format none
  retry gcloud functions add-invoker-policy-binding "$FUNCTION" --project "$PROJECT_ID" \
    --region "$REGION" --member "serviceAccount:$SERVICE_ACCOUNT" >/dev/null
  info "Only $SERVICE_ACCOUNT can invoke the function"

  step "Checking the result"
  state=$(gcloud functions describe "$FUNCTION" --project "$PROJECT_ID" --region "$REGION" --format='value(state)')
  [ "$state" = ACTIVE ] || die "Function $FUNCTION is $state, expected ACTIVE."
  info "Function $FUNCTION is ACTIVE"

  cat <<EOF

Done. GKE audit events in $PROJECT_ID now reach Stream Security within seconds.

To check, make a change in a cluster as yourself, for example:
  kubectl create configmap streamsec-test -n default && kubectl delete configmap streamsec-test -n default
Within a minute the function shows one run per change, with status 200:
  gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="$FUNCTION" AND httpRequest.requestMethod="POST"' --project $PROJECT_ID --freshness 10m --limit 5 --format "table(timestamp,httpRequest.status)"
On a first install, runs in the first minutes can show status 403 while Google applies the new
service account's permissions. Pub/Sub retries them, so those events arrive a little later.
A few minutes later the events show in Stream Security under Log Explorer > Kubernetes.

To remove this setup: bash setup-realtime.sh --project $PROJECT_ID --region $REGION --uninstall
EOF
}

uninstall() {
  local permissions=("${UNINSTALL_PERMISSIONS[@]}")
  check_account_and_project
  "$DELETE_SECRET" && permissions+=(secretmanager.secrets.delete)
  check_permissions "${permissions[@]}"

  step "This will remove from project $PROJECT_ID:"
  info "Log Router sink $SINK, function $FUNCTION in $REGION, topic $TOPIC"
  info "Service account $SERVICE_ACCOUNT"
  "$DELETE_SECRET" && info "Secret $SECRET_NAME"
  confirm "Continue?"

  step "Removing"
  if gcloud logging sinks describe "$SINK" --project "$PROJECT_ID" >/dev/null 2>&1; then
    gcloud logging sinks delete "$SINK" --project "$PROJECT_ID" --quiet >/dev/null 2>&1
    info "Deleted sink $SINK"
  else
    info "Sink $SINK not found, skipping"
  fi
  if gcloud functions describe "$FUNCTION" --project "$PROJECT_ID" --region "$REGION" >/dev/null 2>&1; then
    gcloud functions delete "$FUNCTION" --project "$PROJECT_ID" --region "$REGION" --quiet
    info "Deleted function $FUNCTION"
  else
    info "Function $FUNCTION not found in $REGION, skipping"
  fi
  if gcloud pubsub topics describe "$TOPIC" --project "$PROJECT_ID" >/dev/null 2>&1; then
    gcloud pubsub topics delete "$TOPIC" --project "$PROJECT_ID" --quiet >/dev/null 2>&1
    info "Deleted topic $TOPIC"
  else
    info "Topic $TOPIC not found, skipping"
  fi
  if gcloud iam service-accounts describe "$SERVICE_ACCOUNT" --project "$PROJECT_ID" >/dev/null 2>&1; then
    gcloud iam service-accounts delete "$SERVICE_ACCOUNT" --project "$PROJECT_ID" --quiet >/dev/null 2>&1
    info "Deleted service account $SERVICE_ACCOUNT"
  else
    info "Service account $SERVICE_ACCOUNT not found, skipping"
  fi
  if "$DELETE_SECRET"; then
    if secret_exists; then
      # shellcheck disable=SC2046
      gcloud secrets delete "$SECRET_NAME" $(secret_flags) --quiet >/dev/null 2>&1
      info "Deleted secret $SECRET_NAME"
    else
      info "Secret $SECRET_NAME not found, skipping"
    fi
  else
    info "Kept secret $SECRET_NAME (add --delete-secret to remove it)"
  fi
  echo
  echo "Done."
}

parse_args "$@"
# A regional secret is only reachable through its regional endpoint; the
# override applies to this script's gcloud calls, not the user's gcloud config
if [ -n "$SECRET_LOCATION" ]; then
  export CLOUDSDK_API_ENDPOINT_OVERRIDES_SECRETMANAGER="https://secretmanager.$SECRET_LOCATION.rep.googleapis.com/"
fi
ask_for_missing
if "$UNINSTALL"; then uninstall; else install; fi
