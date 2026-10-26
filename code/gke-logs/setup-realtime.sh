#!/bin/bash
# Sets up real-time GKE audit log collection for Stream Security: checks
# permissions, enables the APIs, stores the collection token in Secret Manager,
# creates a service account, a Pub/Sub topic and a Log Router sink, and deploys
# the function that forwards each audit event. The sink covers one project or,
# with --organization or --folder, every project under it, so one collection
# token and one function serve them all.
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
  cloudfunctions.functions.create
  cloudfunctions.functions.get
  cloudfunctions.functions.update
  run.services.setIamPolicy
)

UNINSTALL_PERMISSIONS=(
  cloudfunctions.functions.delete
  pubsub.topics.delete
  iam.serviceAccounts.delete
)

# Checked where the sink goes: the project, or the organization or folder
SINK_INSTALL_PERMISSIONS=(
  logging.sinks.create
  logging.sinks.get
  logging.sinks.update
)
SINK_UNINSTALL_PERMISSIONS=(
  logging.sinks.delete
)

# Kubernetes audit entries worth forwarding: anything done by people, successful
# anonymous requests, high-risk actions and denied requests by workload service
# accounts, and changes to secrets, RBAC, webhooks, admission policies and CRDs by
# anyone. Leases, events, status updates, denied anonymous and unauthenticated
# requests are noise, and so are anonymous health and version checks: probes make
# them constantly, allowed by the default system:public-info-viewer role.
LOG_FILTER='resource.type="k8s_cluster"
protoPayload.methodName=~""
-protoPayload.authenticationInfo.principalEmail=~"@container-engine-robot.iam.gserviceaccount.com$"
-protoPayload.methodName=~"coordination.v1.leases"
-protoPayload.methodName=~"events.(create|update|patch)$"
-protoPayload.methodName=~"status.(update|patch)$"
-protoPayload.methodName=~"gatewayclasses"
-protoPayload.status.code=16
-(protoPayload.authenticationInfo.principalEmail="system:anonymous" AND protoPayload.status.code=7)
-(protoPayload.authenticationInfo.principalEmail="system:anonymous" AND protoPayload.resourceName=~"^(healthz|livez|readyz|version)(/|$)")
(
  NOT protoPayload.authenticationInfo.principalEmail=~"^system:"
  OR protoPayload.authenticationInfo.principalEmail="system:anonymous"
  OR (
    protoPayload.authenticationInfo.principalEmail=~"^system:serviceaccount:"
    AND NOT protoPayload.authenticationInfo.principalEmail=~"^system:serviceaccount:(kube-system|kube-public|kube-node-lease|gke-managed-[a-z0-9-]+|gmp-system|gmp-public|streamsec-agent):"
    AND (
      protoPayload.methodName=~"(pods.(exec|attach|portforward|proxy|ephemeralcontainers)|secrets.(get|create|update|patch|delete)$|serviceaccounts.token.create$|(daemonsets|cronjobs).create$)"
      OR protoPayload.status.code=7
    )
  )
  OR (
    protoPayload.methodName=~"(secrets|serviceaccounts|roles|rolebindings|webhookconfigurations|validatingadmissionpolic|customresourcedefinitions|pods.(exec|attach|portforward|proxy|ephemeralcontainers)|nodes.proxy)"
    AND protoPayload.methodName=~"(create|update|patch|delete|deletecollection)$"
    AND NOT (
      protoPayload.authenticationInfo.principalEmail=~"^system:node:"
      AND protoPayload.methodName=~"serviceaccounts.token.create$"
    )
  )
)'

PROJECT_ID=
ORGANIZATION_ID=
FOLDER_ID=
PROJECTS=()
API_URL=
REGION=us-central1
SECRET_NAME=streamsec-gke-logs-token
SECRET_LOCATION=
CLUSTERS=()
BATCH_SIZE=500
BATCH_MAX_WAIT_MS=2000
SOURCE=$DEFAULT_SOURCE
UNINSTALL=false
DELETE_SECRET=false
ASSUME_YES=false

usage() {
  cat <<EOF
Usage: bash setup-realtime.sh [options]

Sends GKE audit logs to Stream Security in real time, from one GCP project or,
with --organization or --folder, from every project under it.
Anything required and not given as an option is asked for.

Options:
  --project ID            GCP project that holds the GKE clusters. With --organization or
                          --folder, the project that holds the collector (default: the
                          current gcloud project)
  --organization ID       Collect from every project in this organization (numeric ID),
                          including projects added later
  --folder ID             Collect from every project in this folder (numeric ID)
  --projects P1,P2        With --organization or --folder, collect only these projects
  --api-url URL           The URL you open Stream Security at, e.g. https://app.streamsec.io
  --region REGION         Region of the function (default: $REGION)
  --secret-name NAME      Secret Manager secret with the collection token (default: $SECRET_NAME).
                          An existing secret is reused; otherwise it is created and the token
                          is read from STREAMSEC_COLLECTION_TOKEN or asked for without echo.
  --secret-location LOC   Region of a regional secret (default: a global secret)
  --cluster NAME          Collect only this cluster's audit logs; repeat for more clusters
                          (default: every cluster)
  --batch-size N          Send up to N audit entries per request to Stream Security, 1 to 1000
                          (default: $BATCH_SIZE)
  --batch-max-wait-ms MS  Send the entries waiting this long after the first, even if fewer
                          than --batch-size, 1 to 30000 (default: $BATCH_MAX_WAIT_MS)
  --source URL            Function source (default: $DEFAULT_SOURCE)
  --uninstall             Remove the sink, function, topic and service account. Pass the
                          same --organization or --folder as the install
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

# Retries a command a few times, quietly: IAM changes on a new service account
# can fail until the account has propagated. The command's error is shown only
# if every attempt fails.
retry() {
  local attempt=1 output
  until output=$("$@" 2>&1); do
    if [ "$attempt" -ge 6 ]; then
      printf '%s\n' "$output" >&2
      return 1
    fi
    info "The new identity is not visible to Google yet, retrying in 10 seconds..."
    sleep 10
    attempt=$((attempt + 1))
  done
}

# Runs a command without its chatter, showing its output only if it fails
quiet() {
  local output
  output=$("$@" 2>&1) || { printf '%s\n' "$output" >&2; return 1; }
}

org_wide() {
  [ -n "$ORGANIZATION_ID$FOLDER_ID" ]
}

parse_args() {
  local value projects project
  while [ $# -gt 0 ]; do
    case "$1" in
      --project) PROJECT_ID=${2:?--project needs a value}; shift ;;
      --organization) ORGANIZATION_ID=${2:?--organization needs a value}; shift ;;
      --folder) FOLDER_ID=${2:?--folder needs a value}; shift ;;
      --projects)
        # project IDs have no spaces: "a, b," is a and b
        value=${2:?--projects needs a value}
        IFS=, read -r -a projects <<< "${value// /}"
        for project in ${projects[@]+"${projects[@]}"}; do
          if [ -n "$project" ]; then PROJECTS+=("$project"); fi
        done
        shift
        ;;
      --api-url) API_URL=${2:?--api-url needs a value}; shift ;;
      --region) REGION=${2:?--region needs a value}; shift ;;
      --secret-name) SECRET_NAME=${2:?--secret-name needs a value}; shift ;;
      --secret-location) SECRET_LOCATION=${2:?--secret-location needs a value}; shift ;;
      --cluster) CLUSTERS+=("${2:?--cluster needs a value}"); shift ;;
      --batch-size) BATCH_SIZE=${2:?--batch-size needs a value}; shift ;;
      --batch-max-wait-ms) BATCH_MAX_WAIT_MS=${2:?--batch-max-wait-ms needs a value}; shift ;;
      --source) SOURCE=${2:?--source needs a value}; shift ;;
      --uninstall) UNINSTALL=true ;;
      --delete-secret) DELETE_SECRET=true ;;
      --yes) ASSUME_YES=true ;;
      -h | --help) usage; exit 0 ;;
      *) usage >&2; die "Unknown option: $1" ;;
    esac
    shift
  done
  if [ -n "$ORGANIZATION_ID" ] && [ -n "$FOLDER_ID" ]; then
    die "Pass either --organization or --folder, not both."
  fi
  case "$ORGANIZATION_ID$FOLDER_ID" in
    *[!0-9]*) die "Organization and folder IDs are numeric, e.g. --organization 123456789012." ;;
  esac
  if [ ${#PROJECTS[@]} -gt 0 ] && ! org_wide; then
    die "--projects works with --organization or --folder. For one project, use --project."
  fi
  # A batch fills only with invocations one instance runs at once, at most the
  # function's concurrency (1000), and the wait has to end well within its timeout
  in_range "$BATCH_SIZE" 1000 || die "--batch-size takes a whole number from 1 to 1000."
  in_range "$BATCH_MAX_WAIT_MS" 30000 || die "--batch-max-wait-ms takes a whole number from 1 to 30000."
}

# True when the value is a whole number from 1 to the maximum
in_range() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le "$2" ]
}

# Where the sink goes: the project, or the organization or folder whose projects
# it collects from
set_scope() {
  if [ -n "$ORGANIZATION_ID" ]; then
    SCOPE_RESOURCE=organizations/$ORGANIZATION_ID
    SCOPE_LABEL="organization $ORGANIZATION_ID"
    SINK_FLAGS=(--organization "$ORGANIZATION_ID")
  elif [ -n "$FOLDER_ID" ]; then
    SCOPE_RESOURCE=folders/$FOLDER_ID
    SCOPE_LABEL="folder $FOLDER_ID"
    SINK_FLAGS=(--folder "$FOLDER_ID")
  else
    SCOPE_RESOURCE=projects/$PROJECT_ID
    SCOPE_LABEL="project $PROJECT_ID"
    SINK_FLAGS=(--project "$PROJECT_ID")
  fi
  SINK_WRITE_FLAGS=("${SINK_FLAGS[@]}")
  if org_wide; then
    SINK_WRITE_FLAGS+=(--include-children)
    SCOPE_OPTION="${SINK_FLAGS[*]} "
  else
    SCOPE_OPTION=
  fi
}

ask_for_missing() {
  local default
  # Organization-wide, the project only holds the collector, so the current one
  # is a fine default
  if [ -z "$PROJECT_ID" ] && org_wide; then
    PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
    if [ -z "$PROJECT_ID" ]; then
      interactive || die "Pass --project (the project that will hold the collector)."
      read -r -p "GCP project to hold the collector: " PROJECT_ID
      [ -n "$PROJECT_ID" ] || die "A project ID is required."
    fi
  fi
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
  # The collection API is at the root of the host: keep the scheme (https:// when
  # none is given) and the host, and drop the path a URL copied from the browser has
  if [ -n "$API_URL" ]; then
    [[ "$API_URL" =~ ^https?:// ]] || API_URL="https://$API_URL"
    if [[ "$API_URL" =~ ^(https?://[^/?#]+) ]]; then API_URL=${BASH_REMATCH[1]}; fi
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

# Asks Cloud Resource Manager which of the permissions the account holds on a
# resource (projects/ID, organizations/ID or folders/ID), and lists the missing
# ones. Fails if one is missing.
check_permissions() {
  local resource=$1 kind body response granted permission missing=()
  shift
  kind=${resource%%s/*}
  body=$(printf '"%s",' "$@")
  body="{\"permissions\":[${body%,}]}"
  if ! response=$(curl -sS -X POST \
    -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    -H "Content-Type: application/json" \
    "https://cloudresourcemanager.googleapis.com/v3/$resource:testIamPermissions" \
    -d "$body" 2>&1) || [[ "$response" == *'"error"'* ]]; then
    # The project was found already. Checking an organization or folder takes no
    # permission, so failing means a wrong ID.
    if [ "$kind" = project ]; then
      info "Could not check permissions on $kind ${resource#*/}, continuing. Response: $response"
      return 0
    fi
    echo "ERROR: Could not check permissions on $kind ${resource#*/}. Is the ID right? Response: $response" >&2
    return 1
  fi
  granted=$(printf '%s' "$response" | grep -oE '"[a-z]+(\.[A-Za-z]+)+"' | tr -d '"' || true)
  for permission in "$@"; do
    printf '%s\n' "$granted" | grep -qxF "$permission" || missing+=("$permission")
  done
  [ ${#missing[@]} -eq 0 ] && return 0
  echo "ERROR: $ACCOUNT is missing these permissions on $kind ${resource#*/}:" >&2
  for permission in "${missing[@]}"; do
    printf '         %-40s in %s\n' "$permission" "$(role_for "$permission")" >&2
  done
  if [ "$kind" = project ]; then
    echo "       Project Owner includes all of them." >&2
  else
    echo "       Logs Configuration Writer on the $kind includes them." >&2
  fi
  return 1
}

# Takes the sink's permissions, then --, then the host project's. Checks the
# sink's where the sink goes, and stops before any change if one is missing.
check_all_permissions() {
  local sink=() ok=true
  while [ "$1" != -- ]; do sink+=("$1"); shift; done
  shift
  if org_wide; then
    check_permissions "$SCOPE_RESOURCE" "${sink[@]}" || ok=false
    check_permissions "projects/$PROJECT_ID" "$@" || ok=false
  else
    check_permissions "projects/$PROJECT_ID" "${sink[@]}" "$@" || ok=false
  fi
  "$ok" || { echo "       Nothing was changed." >&2; exit 1; }
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

# Prints (field="a" OR field="b") for the values given, or nothing
any_of() {
  local field=$1 value clause=
  shift
  for value in "$@"; do
    clause="${clause:+$clause OR }$field=\"$value\""
  done
  if [ -n "$clause" ]; then printf '(%s)' "$clause"; fi
}

sink_filter() {
  local filter=$LOG_FILTER clause
  for clause in "$(any_of resource.labels.project_id ${PROJECTS[@]+"${PROJECTS[@]}"})" \
    "$(any_of resource.labels.cluster_name ${CLUSTERS[@]+"${CLUSTERS[@]}"})"; do
    [ -n "$clause" ] && filter="$filter
$clause"
  done
  printf '%s' "$filter"
}

# True when the value is one of the others, or when there are no others
listed() {
  local value=$1 other
  shift
  [ $# -eq 0 ] && return 0
  for other in "$@"; do
    [ "$other" = "$value" ] && return 0
  done
  return 1
}

# Shows the GKE clusters under the organization or folder now, limited to
# --projects and --cluster. The list only informs: the sink also covers clusters
# created later. Cloud Asset Inventory bills the search to the host project.
show_clusters() {
  local names name lines=
  if ! names=$(gcloud asset search-all-resources --scope "$SCOPE_RESOURCE" \
    --asset-types container.googleapis.com/Cluster --billing-project "$PROJECT_ID" \
    --format 'value(name)' 2>&1); then
    info "Could not list the clusters: $(printf '%s\n' "$names" | head -n 1)"
    if [[ "$names" == *SERVICE_DISABLED* || "$names" == *"has not been used"* ]]; then
      info "This setup turns on the Cloud Asset API in $PROJECT_ID, so the next run lists them."
    fi
    info "The sink collects from every cluster either way."
    return 0
  fi
  # //container.googleapis.com/projects/P/locations/L/clusters/C (zones/Z for zonal clusters)
  while IFS= read -r name; do
    [[ "$name" =~ /projects/([^/]+)/[a-z]+/([^/]+)/clusters/([^/]+)$ ]] || continue
    listed "${BASH_REMATCH[1]}" ${PROJECTS[@]+"${PROJECTS[@]}"} || continue
    listed "${BASH_REMATCH[3]}" ${CLUSTERS[@]+"${CLUSTERS[@]}"} || continue
    lines="$lines${BASH_REMATCH[1]}: ${BASH_REMATCH[3]} (${BASH_REMATCH[2]})
"
  done <<< "$names"
  if [ -z "$lines" ]; then
    info "None yet. The sink collects from clusters created later."
    return 0
  fi
  printf '%s' "$lines" | sort | while IFS= read -r name; do info "  $name"; done
}

install() {
  local secret_path secret_state token writer state clusters_text covered apis=("${APIS[@]}")
  local replace_project_sink=false project_permissions=("${INSTALL_PERMISSIONS[@]}")
  check_account_and_project
  # A per-project setup in the host project shares the topic and function, so its
  # sink would send that project's events a second time
  if org_wide && gcloud logging sinks describe "$SINK" --project "$PROJECT_ID" >/dev/null 2>&1; then
    replace_project_sink=true
    project_permissions+=(logging.sinks.delete)
  fi
  check_all_permissions "${SINK_INSTALL_PERMISSIONS[@]}" -- "${project_permissions[@]}"

  if [ -n "$SECRET_LOCATION" ]; then
    secret_path="projects/$PROJECT_ID/locations/$SECRET_LOCATION/secrets/$SECRET_NAME/versions/latest"
  else
    secret_path="projects/$PROJECT_ID/secrets/$SECRET_NAME/versions/latest"
  fi
  if secret_exists; then secret_state="exists, will be reused"; else secret_state="will be created"; fi
  clusters_text="all clusters"
  [ ${#CLUSTERS[@]} -gt 0 ] && clusters_text="clusters ${CLUSTERS[*]}"
  covered="the project"
  if [ ${#PROJECTS[@]} -gt 0 ]; then
    covered="projects ${PROJECTS[*]}"
  elif org_wide; then
    covered="every project in it, including projects added later"
  fi

  step "This will set up:"
  info "Log Router sink: $SINK on $SCOPE_LABEL, collecting $clusters_text in $covered"
  info "In project $PROJECT_ID:"
  info "  Secret:          $SECRET_NAME ${SECRET_LOCATION:+in $SECRET_LOCATION }($secret_state)"
  info "  Service account: $SERVICE_ACCOUNT"
  info "  Pub/Sub topic:   $TOPIC"
  info "  Function:        $FUNCTION in $REGION, sending to $API_URL"
  info "                   up to $BATCH_SIZE entries per request, within ${BATCH_MAX_WAIT_MS}ms"
  if "$replace_project_sink"; then
    info "  Per-project sink $SINK in $PROJECT_ID will be removed: the sink on $SCOPE_LABEL covers it"
  fi
  if org_wide; then
    step "GKE clusters in $SCOPE_LABEL now"
    show_clusters
    # so later runs can list the clusters
    apis+=(cloudasset.googleapis.com)
  fi
  confirm "Continue?"

  step "Enabling APIs"
  gcloud services enable "${apis[@]}" --project "$PROJECT_ID"

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
    --member "serviceAccount:$SERVICE_ACCOUNT" --role roles/secretmanager.secretAccessor
  info "It can read secret $SECRET_NAME"

  step "Pub/Sub topic"
  if gcloud pubsub topics describe "$TOPIC" --project "$PROJECT_ID" >/dev/null 2>&1; then
    info "Using existing topic $TOPIC"
  else
    gcloud pubsub topics create "$TOPIC" --project "$PROJECT_ID" >/dev/null
    info "Created topic $TOPIC"
  fi

  step "Log Router sink"
  if gcloud logging sinks describe "$SINK" "${SINK_FLAGS[@]}" >/dev/null 2>&1; then
    quiet gcloud logging sinks update "$SINK" "pubsub.googleapis.com/projects/$PROJECT_ID/topics/$TOPIC" \
      --log-filter "$(sink_filter)" "${SINK_WRITE_FLAGS[@]}"
    info "Updated sink $SINK on $SCOPE_LABEL"
  else
    quiet gcloud logging sinks create "$SINK" "pubsub.googleapis.com/projects/$PROJECT_ID/topics/$TOPIC" \
      --log-filter "$(sink_filter)" "${SINK_WRITE_FLAGS[@]}"
    info "Created sink $SINK on $SCOPE_LABEL"
  fi
  writer=$(gcloud logging sinks describe "$SINK" "${SINK_FLAGS[@]}" --format='value(writerIdentity)')
  retry gcloud pubsub topics add-iam-policy-binding "$TOPIC" --project "$PROJECT_ID" \
    --member "$writer" --role roles/pubsub.publisher
  info "The sink can publish to $TOPIC"
  # only now that the new sink is in place, so that no event is missed
  if "$replace_project_sink"; then
    quiet gcloud logging sinks delete "$SINK" --project "$PROJECT_ID" --quiet
    info "Removed the per-project sink $SINK in $PROJECT_ID"
  fi

  step "Deploying function $FUNCTION (takes a few minutes)"
  # Entries share a batch only when one instance runs many invocations at once,
  # which takes a whole CPU, and memory for a burst of large entries
  gcloud functions deploy "$FUNCTION" --gen2 --project "$PROJECT_ID" --region "$REGION" \
    --runtime "$RUNTIME" --source "$SOURCE" --entry-point PubSubGKELogsCollection \
    --trigger-topic "$TOPIC" \
    --service-account "$SERVICE_ACCOUNT" --trigger-service-account "$SERVICE_ACCOUNT" \
    --concurrency 1000 --cpu 1 --memory 1Gi --timeout 120s \
    --set-env-vars "API_URL=$API_URL,SECRET_NAME=$secret_path,BATCH_SIZE=$BATCH_SIZE,BATCH_MAX_WAIT_MS=$BATCH_MAX_WAIT_MS" \
    --quiet --format none
  retry gcloud functions add-invoker-policy-binding "$FUNCTION" --project "$PROJECT_ID" \
    --region "$REGION" --member "serviceAccount:$SERVICE_ACCOUNT"
  info "Only $SERVICE_ACCOUNT can invoke the function"

  step "Checking the result"
  state=$(gcloud functions describe "$FUNCTION" --project "$PROJECT_ID" --region "$REGION" --format='value(state)')
  [ "$state" = ACTIVE ] || die "Function $FUNCTION is $state, expected ACTIVE."
  info "Function $FUNCTION is ACTIVE"

  cat <<EOF

Done. GKE audit events in $SCOPE_LABEL now reach Stream Security within seconds.

To check, make a change in a cluster as yourself, for example:
  kubectl create configmap streamsec-test -n default && kubectl delete configmap streamsec-test -n default
Within a minute the function shows one run per change, with status 200:
  gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="$FUNCTION" AND httpRequest.requestMethod="POST"' --project $PROJECT_ID --freshness 10m --limit 5 --format "table(timestamp,httpRequest.status)"
On a first install, runs in the first minutes can show status 403 while Google applies the new
service account's permissions. Pub/Sub retries them, so those events arrive a little later.
A few minutes later the events show in Stream Security under Log Explorer > Kubernetes.

To remove this setup: bash setup-realtime.sh $SCOPE_OPTION--project $PROJECT_ID --region $REGION --uninstall
EOF
}

uninstall() {
  local permissions=("${UNINSTALL_PERMISSIONS[@]}")
  check_account_and_project
  "$DELETE_SECRET" && permissions+=(secretmanager.secrets.delete)
  check_all_permissions "${SINK_UNINSTALL_PERMISSIONS[@]}" -- "${permissions[@]}"

  step "This will remove:"
  info "Log Router sink $SINK from $SCOPE_LABEL"
  info "From project $PROJECT_ID: function $FUNCTION in $REGION, topic $TOPIC, service account $SERVICE_ACCOUNT"
  "$DELETE_SECRET" && info "  and secret $SECRET_NAME"
  confirm "Continue?"

  step "Removing"
  if gcloud logging sinks describe "$SINK" "${SINK_FLAGS[@]}" >/dev/null 2>&1; then
    gcloud logging sinks delete "$SINK" "${SINK_FLAGS[@]}" --quiet >/dev/null 2>&1
    info "Deleted sink $SINK from $SCOPE_LABEL"
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
set_scope
if "$UNINSTALL"; then uninstall; else install; fi
