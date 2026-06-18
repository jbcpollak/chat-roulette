# Deploying Chat Roulette to GCP (Compute Engine + Cloud SQL)

An idempotent, single-VM deployment of *Chat Roulette for Slack* to the
`your-gcp-project-id` GCP project. One small Container-Optimized OS VM runs three
containers — the app, the Cloud SQL Auth Proxy, and a Caddy reverse proxy that
terminates HTTPS — backed by a managed Cloud SQL for PostgreSQL instance.

```
Internet ──HTTPS──▶ [ GCE VM (COS, e2-small, static IP) ]
 chat.example.com          ├─ caddy           :443/:80  auto Let's Encrypt → app:8080
                           ├─ chat-roulette    :8080     (runs DB migrations on boot)
                           └─ cloudsql-proxy   :5432     IAM-authed tunnel to Cloud SQL
                                                 │
                                                 ▼
                              [ Cloud SQL Postgres 15, db-f1-micro ]
```

All runtime secrets live in **Secret Manager**; the VM fetches them at boot via
its service account. Generated keys (DB password, encryption key, cookie key) are
created once and never regenerated, so re-running the deploy is always safe.

## Files

| File | Purpose |
|------|---------|
| `deploy.sh` | Idempotent driver — provisions everything and creates/updates the VM. |
| `cloud-init.yaml` | COS user-data: docker network + systemd units for the 3 containers. |
| `Caddyfile` | Reference copy of the Caddy config (the live copy is embedded in `cloud-init.yaml`). |
| `cloudbuild.yaml` | Builds `cmd/chat-roulette/Dockerfile` in Cloud Build (linux/amd64). |

## Prerequisites

- `gcloud` authenticated as a user with Owner/Editor on `your-gcp-project-id`.
- `python3`, `git`, and `openssl` available locally.
- Permission to install a Slack app in your workspace.
- You control DNS for `example.com`.

## One-time setup

### 1. Create the Slack app

From the **repo root**:

```bash
# Generate an App Configuration token at https://api.slack.com/apps
# ("Your Apps" → "App Configuration Tokens" → Generate). It looks like xoxe.xoxp-1-...

go run cmd/app-manifest/main.go \
  -u https://chat.example.com \
  -t xoxe.xoxp-1-YOUR-CONFIG-TOKEN \
  -o config.json
```

> ⚠️ **Do NOT put a trailing slash on `-u`.** The manifest template concatenates
> paths as `{{.BaseURL}}/v1/slack/event`, so `-u https://chat.example.com/`
> produces double-slash URLs (`https://chat.example.com//v1/slack/event`) that
> Slack registers verbatim — OIDC sign-in then fails with *"redirect_uri did not
> match any configured URIs."* Use `https://chat.example.com` (no trailing slash).
> If you already created the app with a slash, just delete the stray `/` in the
> four URLs on the app's **App Manifest** / **OAuth & Permissions** pages.

This registers the app from `docs/examples/manifest.yaml` (wiring the event,
interaction, options, and OIDC-callback URLs to `https://chat.example.com`) and
writes `config.json` containing the OIDC `client_id`/`client_secret`, the
`signing_secret`, and freshly generated `secret_key` + `encryption.key`.
`config.json` is gitignored — keep it out of version control.

### 2. Install the app & grab the bot token

Open the app at the URL the tool printed, **Install to Workspace**, accept the
scopes, then copy the **Bot User OAuth Token** (`xoxb-...`):

```bash
export BOT_AUTH_TOKEN=xoxb-...
```

(Alternatively set it as `bot.auth_token` in `config.json`.)

### 3. Deploy

First provide your environment-specific settings. Copy the example and fill it in
(`deploy.env` is gitignored — keep your project/domain/email out of version control):

```bash
cp deploy/gcp/deploy.env.example deploy/gcp/deploy.env
$EDITOR deploy/gcp/deploy.env   # set PROJECT_ID, DOMAIN, ACME_EMAIL
```

Then run:

```bash
./deploy/gcp/deploy.sh
```

The script enables APIs, reserves a static IP, builds & pushes the image, creates
the service account + IAM, Cloud SQL instance/db/user, Secret Manager secrets,
firewall rules, and the VM. On success it prints the **static IP**.

### 4. DNS

`deploy.sh` manages this automatically: if a **Cloud DNS** managed zone in this
project covers the domain (e.g. zone `example-com` for `example.com`), it
idempotently upserts `chat.example.com A <STATIC_IP>`. If no covering zone is
found it prints the record for you to create manually. Set `DNS_MANAGED=0` to
disable DNS management entirely.

Caddy obtains a Let's Encrypt certificate automatically once DNS resolves and
ports 80/443 are reachable (the script opens them).

### 5. Verify Slack URL ownership

In the Slack app's **Event Subscriptions** page, confirm the request URL
(`https://chat.example.com/v1/slack/event`) shows *Verified* once the VM serves
traffic.

## Verify the deployment

```bash
gcloud compute instances describe chat-roulette --zone us-central1-a --format='value(status)'   # RUNNING
gcloud sql instances describe chat-roulette-db --format='value(state)'                            # RUNNABLE

curl -fsS https://chat.example.com/-/healthy   # -> ok
curl -fsS https://chat.example.com/-/ready     # -> ready   (proves DB + Slack connectivity, migrations ran)
```

Logs:

```bash
gcloud compute ssh chat-roulette --zone us-central1-a --tunnel-through-iap \
  --command 'docker logs chat-roulette'
```

## Re-running / rolling out a new version

`deploy.sh` is safe to run repeatedly. To ship new code, commit it (the image is
tagged with the git short SHA) and re-run:

```bash
./deploy/gcp/deploy.sh
```

It rebuilds the image, updates the VM's `user-data` metadata, and resets the VM
(~1–2 min downtime). COS re-applies the user-data on boot, pulling the new image.
Caddy's certificate and the database persist across resets (docker named volume +
managed Cloud SQL). To skip the build and only re-apply config/infra:

```bash
SKIP_BUILD=1 ./deploy/gcp/deploy.sh
```

## Configuration

Set values in `deploy/gcp/deploy.env` (sourced automatically) or as environment
variables, e.g.:

```bash
SQL_TIER=db-g1-small MACHINE_TYPE=e2-medium ./deploy/gcp/deploy.sh
```

| Variable | Default | Notes |
|----------|---------|-------|
| `PROJECT_ID` | — (required) | GCP project; set in `deploy.env` |
| `DOMAIN` | — (required) | public hostname; set in `deploy.env` |
| `ACME_EMAIL` | — (required) | Let's Encrypt contact; set in `deploy.env` |
| `REGION` / `ZONE` | `us-central1` / `us-central1-a` | |
| `MACHINE_TYPE` | `e2-small` | VM size |
| `SQL_TIER` | `db-f1-micro` | bump to `db-g1-small` if the worker is starved |
| `AR_REPO` | `cloud-run` | existing Artifact Registry repo |
| `BOT_AUTH_TOKEN` | — | Slack bot token (or set in `config.json`) |
| `SKIP_BUILD` | `0` | set `1` to skip the image build |
| `DISABLE_ONBOARDING_FLOW` | `false` | set `true` to skip the member onboarding questionnaire (one-click Opt In enrolls immediately) |

## Teardown

```bash
gcloud compute instances delete chat-roulette --zone us-central1-a
gcloud compute addresses delete chat-roulette-ip --region us-central1
gcloud sql instances delete chat-roulette-db
# secrets, SA, firewall rules, and the AR image remain unless explicitly deleted
```

## Cost (rough)

~$25–35/month: `e2-small` (~$13) + Cloud SQL `db-f1-micro` (~$9 + storage) +
static IP. Single VM, no HA — appropriate for a small internal tool; the upgrade
path is vertical (bigger machine/tier) since the app is stateless apart from
Postgres.

## Security notes

A pre-deploy review of the codebase found no hardcoded secrets, no data/key
exfiltration, verified Slack request signatures, parameterized DB queries, and
PII encrypted at rest. This deployment keeps the database off the public network
(reachable only via the IAM-authed Auth Proxy), stores all secrets in Secret
Manager, runs the app as a non-root distroless container, and uses a dedicated,
least-privilege service account.
