#!/usr/bin/env bash
#
# Idempotent deployment of "Chat Roulette for Slack" to a single Compute Engine
# VM (Container-Optimized OS) backed by Cloud SQL for PostgreSQL.
#
# Safe to re-run: every step checks for existing resources before creating them,
# and generated secrets/keys are NEVER regenerated (regenerating the encryption
# key would make existing encrypted rows unreadable).
#
# Prerequisites (see deploy/gcp/README.md for the full walkthrough):
#   * gcloud CLI authenticated as a user with Owner/Editor on the project.
#   * A Slack app created via `cmd/app-manifest` which produced ./config.json.
#   * The Bot User OAuth token exported as BOT_AUTH_TOKEN (or present in config.json).
#   * git + python3 available locally.
#
# Usage:
#   export BOT_AUTH_TOKEN=xoxb-...        # if not already in config.json
#   ./deploy/gcp/deploy.sh                # full deploy / re-deploy
#   SKIP_BUILD=1 ./deploy/gcp/deploy.sh   # skip the image build (config/infra only)
#
set -euo pipefail

# --------------------------------------------------------------------------- #
# Operator configuration
#
# Environment-specific values (project, domain, contact email) are NOT hardcoded
# here. Copy deploy.env.example to deploy.env (gitignored) and fill it in, or
# export the variables in your shell. deploy.env is sourced below.
# --------------------------------------------------------------------------- #
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "${SCRIPT_DIR}/deploy.env" ]; then
  # shellcheck disable=SC1091
  . "${SCRIPT_DIR}/deploy.env"
fi

# --------------------------------------------------------------------------- #
# Configuration (override any of these via deploy.env or environment variables)
# --------------------------------------------------------------------------- #
# Required — no defaults (must come from deploy.env or the environment):
PROJECT_ID="${PROJECT_ID:?set PROJECT_ID (GCP project) in deploy/gcp/deploy.env}"
DOMAIN="${DOMAIN:?set DOMAIN (public hostname) in deploy/gcp/deploy.env}"
ACME_EMAIL="${ACME_EMAIL:?set ACME_EMAIL (TLS certificate contact) in deploy/gcp/deploy.env}"

REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"
VM_NAME="${VM_NAME:-chat-roulette}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-small}"
BOOT_DISK_SIZE="${BOOT_DISK_SIZE:-20GB}"

SQL_INSTANCE="${SQL_INSTANCE:-chat-roulette-db}"
SQL_TIER="${SQL_TIER:-db-f1-micro}"
SQL_VERSION="${SQL_VERSION:-POSTGRES_15}"
DB_NAME="${DB_NAME:-chat-roulette}"
DB_USER="${DB_USER:-chat_roulette}"

AR_REPO="${AR_REPO:-cloud-run}"
SA_NAME="${SA_NAME:-chat-roulette-vm}"
IP_NAME="${IP_NAME:-chat-roulette-ip}"
FW_HTTP="${FW_HTTP:-chat-roulette-allow-http}"
FW_SSH="${FW_SSH:-chat-roulette-allow-iap-ssh}"
DNS_MANAGED="${DNS_MANAGED:-1}"   # set 0 to never touch Cloud DNS
NETWORK_TAG="chat-roulette"
CONFIG_JSON="${CONFIG_JSON:-config.json}"

# App feature flags (non-secret env passed to the container). Set to "true" to skip
# the member onboarding questionnaire (one-click Opt In enrolls immediately).
DISABLE_ONBOARDING_FLOW="${DISABLE_ONBOARDING_FLOW:-false}"

# --------------------------------------------------------------------------- #
# Derived values
# --------------------------------------------------------------------------- #
REGION_HOST="${REGION}-docker.pkg.dev"
IMAGE_BASE="${REGION_HOST}/${PROJECT_ID}/${AR_REPO}/chat-roulette"
IMAGE_TAG="$(git rev-parse --short HEAD 2>/dev/null || echo manual)"
IMAGE="${IMAGE_BASE}:${IMAGE_TAG}"
IMAGE_LATEST="${IMAGE_BASE}:latest"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
INSTANCE_CONNECTION_NAME="${PROJECT_ID}:${REGION}:${SQL_INSTANCE}"
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
HERE="${REPO_ROOT}/deploy/gcp"

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
log()  { printf '\n\033[1;34m==>\033[0m [%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# step "Title" "ETA"  -- print a timestamped step header with an expected
# duration, and report how long the PREVIOUS step actually took. If no new step
# line appears well past its expected time, that step is stalled — investigate.
STEP_TS=0
STEP_NAME=""
step() {
  local now=$SECONDS
  [ -n "$STEP_NAME" ] && printf '    \033[2m\xe2\x94\x94 %s finished in %ds\033[0m\n' "$STEP_NAME" "$((now - STEP_TS))"
  STEP_TS=$now
  STEP_NAME="$1"
  printf '\n\033[1;34m==>\033[0m [%s] %s \033[2m(expected ~%s)\033[0m\n' "$(date '+%H:%M:%S')" "$1" "$2"
}
step_end() {
  [ -n "$STEP_NAME" ] && printf '    \033[2m\xe2\x94\x94 %s finished in %ds\033[0m\n' "$STEP_NAME" "$((SECONDS - STEP_TS))"
  STEP_NAME=""
}
G() { gcloud --project "$PROJECT_ID" "$@"; }

# retry CMD...  -- run a command, retrying on failure (handles GCP eventual
# consistency, e.g. a freshly-created service account not yet usable in IAM).
retry() {
  local n=0 max=8 delay=5
  until "$@"; do
    n=$((n + 1))
    [ "$n" -ge "$max" ] && return 1
    sleep "$delay"
  done
}

# Read a dotted key out of config.json, tolerating absence.
cfg() {
  python3 - "$CONFIG_JSON" "$1" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    for k in sys.argv[2].split('.'):
        d = d[k]
    print(d)
except Exception:
    pass
PY
}

# ensure_secret NAME VALUE  -- create the secret with VALUE only if it does not
# already exist. Existing secrets are left untouched (stable keys across re-runs).
ensure_secret() {
  local name="$1" value="$2"
  if G secrets describe "$name" >/dev/null 2>&1; then
    info "secret ${name}: exists (unchanged)"
  else
    printf '%s' "$value" | G secrets create "$name" --replication-policy=automatic --data-file=- >/dev/null
    info "secret ${name}: created"
  fi
}

# --------------------------------------------------------------------------- #
# Preflight
# --------------------------------------------------------------------------- #
command -v gcloud  >/dev/null || die "gcloud not found on PATH"
command -v python3 >/dev/null || die "python3 not found on PATH"
[ -f "$CONFIG_JSON" ] || die "config.json not found at '${CONFIG_JSON}'. Create the Slack app first (see README)."

BOT_AUTH_TOKEN="${BOT_AUTH_TOKEN:-$(cfg bot.auth_token)}"
case "$BOT_AUTH_TOKEN" in
  xoxb-*) : ;;
  *) die "BOT_AUTH_TOKEN must be set to the Slack bot token (xoxb-...). Export it or put it in config.json under bot.auth_token." ;;
esac

CLIENT_ID="$(cfg server.client_id)";        [ -n "$CLIENT_ID" ]      || die "server.client_id missing from ${CONFIG_JSON}"
CLIENT_SECRET="$(cfg server.client_secret)"; [ -n "$CLIENT_SECRET" ]  || die "server.client_secret missing from ${CONFIG_JSON}"
SIGNING_SECRET="$(cfg server.signing_secret)"; [ -n "$SIGNING_SECRET" ] || die "server.signing_secret missing from ${CONFIG_JSON}"
SECRET_KEY="$(cfg server.secret_key)";       [ -n "$SECRET_KEY" ]     || die "server.secret_key missing from ${CONFIG_JSON}"
ENCRYPTION_KEY="$(cfg database.encryption.key)"; [ -n "$ENCRYPTION_KEY" ] || die "database.encryption.key missing from ${CONFIG_JSON}"

log "Deploying chat-roulette → project=${PROJECT_ID} zone=${ZONE} domain=${DOMAIN}"
info "image:   ${IMAGE}"
info "sql:     ${INSTANCE_CONNECTION_NAME} (${SQL_TIER}, ${SQL_VERSION})"
G config set project "$PROJECT_ID" >/dev/null 2>&1 || true

# --------------------------------------------------------------------------- #
# 1. Enable required APIs
# --------------------------------------------------------------------------- #
step "Enabling required APIs" "10s; up to 2m the first time an API is enabled"
G services enable \
  compute.googleapis.com \
  sqladmin.googleapis.com \
  secretmanager.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com

# --------------------------------------------------------------------------- #
# 2. Reserve a static external IP
# --------------------------------------------------------------------------- #
step "Reserving static IP (${IP_NAME})" "5s; but the first Compute call after enabling the API can take 2-5m"
if ! G compute addresses describe "$IP_NAME" --region "$REGION" >/dev/null 2>&1; then
  G compute addresses create "$IP_NAME" --region "$REGION"
fi
STATIC_IP="$(G compute addresses describe "$IP_NAME" --region "$REGION" --format='value(address)')"
info "static IP: ${STATIC_IP}"

# --------------------------------------------------------------------------- #
# 2b. DNS A record (only if a Cloud DNS managed zone covers the domain)
# --------------------------------------------------------------------------- #
step "Ensuring DNS A record (${DOMAIN})" "5s"
if [ "$DNS_MANAGED" != "1" ]; then
  info "DNS management disabled (DNS_MANAGED=0). Set ${DOMAIN} A ${STATIC_IP} manually."
else
  # Find the managed zone whose DNS name is the longest suffix of the domain.
  DNS_ZONE=""
  dns_zone_len=0
  while read -r zname zdns; do
    case "${DOMAIN}." in
      *"$zdns")
        if [ "${#zdns}" -gt "$dns_zone_len" ]; then DNS_ZONE="$zname"; dns_zone_len="${#zdns}"; fi ;;
    esac
  done < <(G dns managed-zones list --format='value(name,dnsName)' 2>/dev/null)

  if [ -z "$DNS_ZONE" ]; then
    info "no Cloud DNS managed zone found for ${DOMAIN} in this project."
    info "create this record manually:  ${DOMAIN}  A  ${STATIC_IP}"
  else
    current_ip="$(G dns record-sets describe "${DOMAIN}." --zone "$DNS_ZONE" --type A \
      --format='value(rrdatas[0])' 2>/dev/null || true)"
    if [ "$current_ip" = "$STATIC_IP" ]; then
      info "DNS A ${DOMAIN} -> ${STATIC_IP} already set (zone ${DNS_ZONE})"
    elif [ -n "$current_ip" ]; then
      G dns record-sets update "${DOMAIN}." --zone "$DNS_ZONE" --type A --ttl 300 --rrdatas "$STATIC_IP" >/dev/null
      info "DNS A ${DOMAIN} updated ${current_ip} -> ${STATIC_IP} (zone ${DNS_ZONE})"
    else
      G dns record-sets create "${DOMAIN}." --zone "$DNS_ZONE" --type A --ttl 300 --rrdatas "$STATIC_IP" >/dev/null
      info "DNS A ${DOMAIN} created -> ${STATIC_IP} (zone ${DNS_ZONE})"
    fi
  fi
fi

# --------------------------------------------------------------------------- #
# 3. Artifact Registry repo + build/push image
# --------------------------------------------------------------------------- #
step "Ensuring Artifact Registry repo (${AR_REPO})" "5s"
if ! G artifacts repositories describe "$AR_REPO" --location "$REGION" >/dev/null 2>&1; then
  G artifacts repositories create "$AR_REPO" --location "$REGION" --repository-format=docker \
    --description="Docker images"
fi

if [ "${SKIP_BUILD:-0}" = "1" ]; then
  step "Skipping image build (SKIP_BUILD=1)" "0s"
else
  step "Building & pushing image via Cloud Build" "2-5m"
  ( cd "$REPO_ROOT" && G builds submit \
      --config "deploy/gcp/cloudbuild.yaml" \
      --substitutions=_IMAGE="${IMAGE}",_IMAGE_LATEST="${IMAGE_LATEST}" \
      . )
fi

# --------------------------------------------------------------------------- #
# 4. Service account + IAM
# --------------------------------------------------------------------------- #
step "Ensuring service account + IAM (${SA_EMAIL})" "20s; longer while waiting for a new SA to propagate"
if ! G iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1; then
  G iam service-accounts create "$SA_NAME" --display-name="Chat Roulette VM"
  info "waiting for service account to propagate..."
  retry G iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1 || die "service account never became visible"
fi
for role in roles/cloudsql.client roles/secretmanager.secretAccessor \
            roles/artifactregistry.reader roles/logging.logWriter roles/monitoring.metricWriter; do
  # Retry: a just-created SA can briefly be rejected as "does not exist" by IAM.
  retry G projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" --role="$role" --condition=None >/dev/null \
    || die "failed to bind ${role}"
  info "bound ${role}"
done

# --------------------------------------------------------------------------- #
# 5. Cloud SQL instance, database, user (+ DB password secret)
# --------------------------------------------------------------------------- #
step "Ensuring Cloud SQL instance (${SQL_INSTANCE})" "5-10m on first create; instant if it already exists"
if ! G sql instances describe "$SQL_INSTANCE" >/dev/null 2>&1; then
  info "creating instance (this can take several minutes)..."
  G sql instances create "$SQL_INSTANCE" \
    --database-version="$SQL_VERSION" \
    --tier="$SQL_TIER" \
    --region="$REGION" \
    --storage-auto-increase \
    --backup --backup-start-time=07:00 \
    --availability-type=zonal
fi

# DB password lives in Secret Manager; generate once, reuse forever.
if G secrets describe chat-roulette-db-password >/dev/null 2>&1; then
  DB_PASSWORD="$(G secrets versions access latest --secret=chat-roulette-db-password)"
  info "db password: reusing existing secret"
else
  DB_PASSWORD="$(openssl rand -hex 24)"
  ensure_secret chat-roulette-db-password "$DB_PASSWORD"
fi

step "Ensuring database (${DB_NAME}) and user (${DB_USER})" "30s"
if ! G sql databases describe "$DB_NAME" --instance="$SQL_INSTANCE" >/dev/null 2>&1; then
  G sql databases create "$DB_NAME" --instance="$SQL_INSTANCE"
fi
if G sql users list --instance="$SQL_INSTANCE" --format='value(name)' | grep -qx "$DB_USER"; then
  info "db user exists; syncing password"
  G sql users set-password "$DB_USER" --instance="$SQL_INSTANCE" --password="$DB_PASSWORD"
else
  G sql users create "$DB_USER" --instance="$SQL_INSTANCE" --password="$DB_PASSWORD"
fi

# --------------------------------------------------------------------------- #
# 6. Application secrets → Secret Manager (create-if-absent only)
# --------------------------------------------------------------------------- #
step "Ensuring application secrets in Secret Manager" "15s"
ensure_secret chat-roulette-bot-auth-token   "$BOT_AUTH_TOKEN"
ensure_secret chat-roulette-encryption-key   "$ENCRYPTION_KEY"
ensure_secret chat-roulette-server-secret-key "$SECRET_KEY"
ensure_secret chat-roulette-client-id        "$CLIENT_ID"
ensure_secret chat-roulette-client-secret    "$CLIENT_SECRET"
ensure_secret chat-roulette-signing-secret   "$SIGNING_SECRET"

# --------------------------------------------------------------------------- #
# 7. Firewall rules
# --------------------------------------------------------------------------- #
step "Ensuring firewall rules" "15s"
if ! G compute firewall-rules describe "$FW_HTTP" >/dev/null 2>&1; then
  G compute firewall-rules create "$FW_HTTP" \
    --direction=INGRESS --action=ALLOW \
    --rules=tcp:80,tcp:443,udp:443 \
    --source-ranges=0.0.0.0/0 --target-tags="$NETWORK_TAG"
fi
if ! G compute firewall-rules describe "$FW_SSH" >/dev/null 2>&1; then
  G compute firewall-rules create "$FW_SSH" \
    --direction=INGRESS --action=ALLOW \
    --rules=tcp:22 \
    --source-ranges=35.235.240.0/20 --target-tags="$NETWORK_TAG"
fi

# --------------------------------------------------------------------------- #
# 8. Render cloud-init and create-or-update the VM
# --------------------------------------------------------------------------- #
step "Rendering cloud-init user-data" "1s"
# Translate feature-flag config vars into docker `-e` flags for the app container.
APP_EXTRA_ENV=""
if [ "$DISABLE_ONBOARDING_FLOW" = "true" ]; then
  APP_EXTRA_ENV="-e DISABLE_ONBOARDING_FLOW=true"
fi
info "app extra env: ${APP_EXTRA_ENV:-<none>}"
RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED"' EXIT
sed \
  -e "s|__PROJECT_ID__|${PROJECT_ID}|g" \
  -e "s|__REGION_HOST__|${REGION_HOST}|g" \
  -e "s|__IMAGE__|${IMAGE}|g" \
  -e "s|__ICN__|${INSTANCE_CONNECTION_NAME}|g" \
  -e "s|__DOMAIN__|${DOMAIN}|g" \
  -e "s|__ACME_EMAIL__|${ACME_EMAIL}|g" \
  -e "s|__DB_USER__|${DB_USER}|g" \
  -e "s|__DB_NAME__|${DB_NAME}|g" \
  -e "s|__APP_EXTRA_ENV__|${APP_EXTRA_ENV}|g" \
  "${HERE}/cloud-init.yaml" > "$RENDERED"

if G compute instances describe "$VM_NAME" --zone "$ZONE" >/dev/null 2>&1; then
  step "VM exists → updating user-data and rolling forward (reset)" "1-2m"
  G compute instances add-metadata "$VM_NAME" --zone "$ZONE" \
    --metadata-from-file user-data="$RENDERED"
  G compute instances reset "$VM_NAME" --zone "$ZONE"
else
  step "Creating VM (${VM_NAME}, ${MACHINE_TYPE}, COS)" "30-60s"
  G compute instances create "$VM_NAME" \
    --zone "$ZONE" \
    --machine-type "$MACHINE_TYPE" \
    --image-family=cos-stable --image-project=cos-cloud \
    --boot-disk-size="$BOOT_DISK_SIZE" \
    --address="$STATIC_IP" \
    --service-account="$SA_EMAIL" \
    --scopes=cloud-platform \
    --tags="$NETWORK_TAG" \
    --metadata-from-file user-data="$RENDERED"
fi

# --------------------------------------------------------------------------- #
# Done
# --------------------------------------------------------------------------- #
step_end
log "Deployment complete in ${SECONDS}s total."
cat <<EOF

  Static IP : ${STATIC_IP}
  Domain    : ${DOMAIN}
  App image : ${IMAGE}

  Next steps:
    1. DNS: ${DOMAIN} -> ${STATIC_IP} (auto-managed if a Cloud DNS zone covers the
       domain; otherwise create this A record yourself). Allow time to propagate.
    2. Wait ~1-2 min for the containers to start and Caddy to obtain a cert, then:
         curl -fsS https://${DOMAIN}/-/healthy   # -> ok
         curl -fsS https://${DOMAIN}/-/ready     # -> ready
    3. In the Slack app's Event Subscriptions page, verify the request URL
       (https://${DOMAIN}/v1/slack/event).
    4. Invite the bot to a channel and configure a round.

  Logs:  gcloud compute ssh ${VM_NAME} --zone ${ZONE} --tunnel-through-iap \\
           --command 'docker logs chat-roulette'
EOF
