# Gamblock-AI Infrastructure

Ansible deployment for the Gamblock-AI backend, website, PostgreSQL, and Caddy
on one Ubuntu VPS.

AI workflow context version: `2026-09-13.3`. Start with [`AGENTS.md`](AGENTS.md)
and [`docs/ai/README.md`](docs/ai/README.md).

## Environment shape

One VPS hosts two environments through one Docker stack:

| Environment | Website | API | Database |
|---|---|---|---|
| production | `https://gamblock-ai.com` | `https://api.gamblock-ai.com` | `gamblock` |
| staging | `https://staging.gamblock-ai.com` | `https://api-staging.gamblock-ai.com` | `gamblock_staging` |

- `https://www.gamblock-ai.com` → permanent apex redirect
- Cloudflare proxied DNS in Full (strict) mode
- one Caddy `2.11.4-alpine` serving all five hosts
- one PostgreSQL 16 container with two databases
- separate application containers per environment
  (`gamblock-ai-backend[-staging]`, `gamblock-ai-website[-staging]`; identical
  internal ports 8080/3000 because each container has its own network
  namespace; the staging website image
  `ghcr.io/gamblock-ai/gamblock-ai-website:staging` carries its own baked
  staging API origin)
- one SSH account: `root`, password authentication, port 22

The inventory pins the VPS ED25519 host identity. UFW permits only SSH, HTTP,
HTTPS, and HTTP/3; fail2ban protects SSH; unattended upgrades, Docker log
rotation, and a 2 GiB swapfile suit the current small VPS. This remains a
single-host operational deployment, not a high-availability claim.

## Environment contract

Production and staging use the same backend runtime behavior and the same
provider credentials. Both run `APP_ENV=production`,
`NOTIFICATION_MODE=production`, `ENABLE_DEV_LOGIN=false`, and
`ENABLE_DEMO_DATA=false`. Both use the same `FONNTE_TOKEN` and
`DEEPSEEK_API_KEY` from the encrypted Ansible Vault; they are not separate
provider accounts. The environments are isolated at the database and
application-container level, not at the provider-credential level.

The local backend intentionally uses the same Fonnte and DeepSeek token values
in its gitignored `.env`. Local is therefore capable of sending real WhatsApp
messages and making real DeepSeek API requests. This is intentional for local
integration work, not a fallback to demo mode. DeepSeek-backed paths still obey
the backend privacy and per-user SPK-personalization rules; raw DOM, URLs,
domains, screenshots, and browsing history must never be sent to the provider.

| Surface | Runtime | Provider behavior | Database / endpoints |
|---|---|---|---|
| Local | `APP_ENV=development` | Real Fonnte and DeepSeek when configured/invoked | Local PostgreSQL and loopback URLs |
| Production | `APP_ENV=production` | Real Fonnte and DeepSeek | `gamblock`, public production domains |
| Staging | `APP_ENV=production` | Real Fonnte and DeepSeek | `gamblock_staging`, public staging domains |

The `.env.example` files retain safe starter defaults. The local checkout may
override those defaults intentionally, but real values must remain only in the
gitignored local `.env` or an approved secret store and must never be copied
into documentation, source control, or Flutter client configuration.

## Files

```text
ansible.cfg
inventory/hosts.ini
inventory/known_hosts
group_vars/all/{vars.yml,apps.yml,vault.yml,vault.yml.example}
group_vars/environments/{production,staging}.yml
playbooks/server-setup.yml
roles/system/base-setup/
roles/infrastructure/{docker-setup,caddy-setup}/
roles/databases/postgres-setup/
roles/applications/
roles/common/files/update.sh
scripts/{init-vault,update-vault-integrations,github-secrets,cloudflare-dns,verify-production}.sh
scripts/verify-credentials.py
```

## Local setup and validation

```sh
python -m pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml
cp .vault_pass.example .vault_pass
chmod 600 .vault_pass
make lint
scripts/verify-ai-context.sh --allow-untracked
```

`.vault_pass` is ignored and must contain the password for the tracked encrypted
`group_vars/all/vault.yml`. For a deliberately new environment, `make
vault-init` prompts for the current VPS root password, generates independent
PostgreSQL/JWT/AES values plus a dedicated P-256 protection-grant signing key,
and encrypts the result immediately. It refuses to
overwrite an existing vault. Add remaining credentials with `make vault-edit`,
or update GHCR, Cloudflare, Fonnte, and DeepSeek tokens without opening an
editor using `make vault-integrations`; blank interactive input preserves the
current value. Never keep a plaintext vault.

`make credential-check` decrypts the vault only in memory and reports field
status without values. `make credential-check-online` additionally makes
read-only calls to GHCR, Cloudflare, Fonnte, and DeepSeek. The complete
`make deploy` path runs that online gate before any DNS or server mutation.

`make lint` uses only `vault.yml.example`. `make check` is local syntax
validation. `make ping`, `make check-mode`, `make bootstrap`, deployment,
remote shell, vault access, GitHub mutation, and Cloudflare mutation require
the authorization described in `AGENTS.md`.

## Local application runbook

The infrastructure repository manages the VPS deployment; local application
processes are started from their component repositories. Use a local
PostgreSQL instance only—never point a local `.env` at the production or
staging database.

Backend:

```sh
cd ../gamblock-ai-backend
# Create .env from .env.example only when .env does not exist.
make key-generate       # only for a new .env without a valid key
make migrate-up
make run                 # http://127.0.0.1:8080
```

Before starting the backend locally, keep `APP_ENV=development`,
`NOTIFICATION_MODE=production`, and the intentional local copies of
`FONNTE_TOKEN` and `DEEPSEEK_API_KEY` in the private `.env`. With this setting,
registration, verification, password reset, export/deletion, and emergency
flows that use Fonnte can send real WhatsApp messages. DeepSeek translation or
SPK personalization can make real API calls when the corresponding feature is
invoked; SPK personalization remains controlled by the user's privacy
preference.

Website:

```sh
cd ../gamblock-ai-website
npm ci
# Create .env.local from .env.example when needed, using the local API URL.
npm run dev             # http://localhost:3000
```

Flutter Android emulator:

```sh
cd ../gamblock_ai_apps
flutter pub get
flutter run --flavor play
```

The current local Flutter `.env` targets `http://10.0.2.2:8080` for the host
backend and `http://10.0.2.2:3000` for the host website. `10.0.2.2` is the
Android-emulator alias for host loopback. For Chrome, Windows, or another
desktop target, change only the local `.env` URLs to `localhost` or the
appropriate host address; do not publish those local values as GitHub
variables.

## Readiness gates

Normal application deployment intentionally stops before remote changes until
all of these are configured in the encrypted vault:

- a GitHub PAT with `read:packages` for private GHCR pulls;
- valid PostgreSQL, JWT, and AES-256 journal encryption values;
- a P-256 protection-grant private key whose public key matches the configured
  client trust store;
- a connected Fonnte device token;
- a VAPID private key matching the configured public key; and
- a DeepSeek API key that can access the configured model whenever
  `spk_llm_enrichment` is enabled.

Fonnte is the production transactional notification adapter. Without a
`FONNTE_TOKEN`, production validation fails and WhatsApp verification/reset/export
notifications remain unavailable; demo codes stay disabled. The
Cloudflare helper separately requires a token
with Zone Read, DNS Edit, and Zone Settings Edit for `gamblock-ai.com`.

## Authorized operation sequence

```sh
make ping
make bootstrap
make deploy                 # production, then staging
make deploy ENV=production  # production only
make deploy ENV=staging     # staging only
make app APP=gamblock-ai-backend
make app APP=gamblock-ai-backend ENV=staging
make app APP=gamblock-ai-website ENV=staging
make ssh
```

`bootstrap` provisions the host, Docker, PostgreSQL (both databases), and Caddy
without the third-party application gates. `deploy` updates Cloudflare
DNS/strict SSL once, provisions the selected stack, creates a pre-deploy
PostgreSQL backup, runs `migrate-up` and the environment's seeding plan, starts
the applications and Caddy, and waits until the environment's public website
and API health endpoints both answer. `app` selects the requested role for the
selected environment.

The default `make deploy` performs that complete flow sequentially for
production and then staging. `make deploy ENV=production` performs only the
production flow, while `make deploy ENV=staging` performs only the staging
flow. The two environments use the same playbook and shared
PostgreSQL/Caddy services, but the backend backup and migration target the
selected database (`gamblock` or `gamblock_staging`). If production fails, the
default command stops and does not start staging; if staging fails after
production succeeds, the command returns failure without automatically
rolling production back. Neither flow resets its selected database.

Seeding plans per environment:

- **production** — `migrate-up` + `seed-accounts` only (the four demo accounts
  with **no** fixture content), gated on an empty database
  (`seed_only_when_empty: true`). Once any account exists the automatic seed
  plan is skipped and the populated database is left exactly as-is on deploy.
  The users-only seeder still fails closed when invoked manually against a
  database that contains accounts outside the approved fixture, and it never
  seeds education, Learning Hub, social, activity, support, or operational
  fixtures.
- **staging** — `migrate-up`, `seeder`, and `seed-learning-hub` run on every
  deploy. `demo-seeder` runs only when the users table is empty or contains
  exactly the four approved demo accounts. If unrelated/real accounts exist,
  the demo seeder is skipped and those accounts are preserved while the
  baseline seeders still run. Staging is **not** reset:
  `fresh_reset_before_deploy` is `false`, so staging keeps its data between
  deploys like production. An empty or valid-demo staging database receives the
  full fixture set; this asymmetry vs production is by design.

The seeder difference is the main database-flow difference after migration:
production uses the users-only `seed-accounts` path and skips it once the
`users` table already contains an account; staging always runs the safe
baseline/content seeders, while its full demo sequence is conditional on the
database target. An empty database or the exact four-account fixture runs
`demo-seeder`; a staging database containing unrelated accounts skips it rather
than silently mixing those accounts with the demo fixture. The same target
gate is rendered into `update.env`, so the Ansible deploy and a later CI
`update.sh` follow the same rule.

Runtime behavior is identical between staging and production: both run
`APP_ENV=production`, `NOTIFICATION_MODE=production` (real Fonnte
OTP/WhatsApp, no demo preview codes), dev login disabled, and fail closed
like production. Only the database (`gamblock` vs `gamblock_staging`),
domains, CORS origin, and seeding data volume differ. A single `FONNTE_TOKEN`
is shared, so staging and production use the same WhatsApp delivery device.

The backend template keeps production development login/demo data disabled,
mounts artifact, export, education-media, and avatar storage, and renders the
guarded confirmation variables for the one-shot tools. `update.sh` sources the
Ansible-rendered `update.env` (database name/user, container, seeding plan),
stays non-destructive, and never performs a fresh reset. Pre-deploy, pre-update,
and nightly scheduled backups are retained for 14 days. The nightly scheduled
backup (`roles/system/backup-setup`) archives both PostgreSQL databases and the
dynamic file volumes (education media, exports, artifacts, avatars) of every
backend container into `{{ docker_stack_base }}/backups`. The website's public
API, app URL, and VAPID
public key are Docker build-time GitHub variables; the staging website image is
built by website CI with the staging variables. The backend template renders
the matching `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` (from the encrypted
vault), and `VAPID_SUBJECT` for the opt-in daily Web Push reminder.

An owner-approved manual demo reset on a running environment is performed only
from the rendered backend application directory while the API is stopped. Use
`demo-seeder` (accounts plus fixture content) for a full demo environment and
`seed-accounts` (the four accounts only, no fixtures) for the production shape:

```sh
docker compose stop <backend-container>
docker compose --profile tools run --rm --no-deps -e CONFIRM_MIGRATE_DOWN=DROP_ALL_DATA migrate-down
docker compose --profile tools run --rm --no-deps -e CONFIRM_RESET_STORAGE=DELETE_DYNAMIC_STORAGE reset-storage
docker compose --profile tools run --rm --no-deps migrate-up
# Full demo environment (staging shape):
docker compose --profile tools run --rm --no-deps -e CONFIRM_DEMO_SEED=CREATE_FOUR_DEMO_ACCOUNTS demo-seeder
# OR accounts-only (production shape):
docker compose --profile tools run --rm --no-deps -e CONFIRM_SEED_ACCOUNTS=CREATE_FOUR_DEMO_ACCOUNTS seed-accounts
docker compose up -d --no-deps <backend-container>
```

Keep the API stopped if any one-shot service fails. Both account seeders accept
an empty database or the exact four known fixtures only; they reject unrelated
accounts. Production's users-only seeder runs automatically only for an empty
database, while staging's full demo seeder runs for an empty or exact-demo
database and is skipped for unrelated accounts. The safe baseline seeders still
run on populated staging, and no automatic path resets or deletes the existing
database.

## GitHub and Cloudflare helpers

```sh
make github-secrets-dry
make github-secrets
make cloudflare-dry
make cloudflare
```

GitHub configuration stores only `VPS_PASSWORD` as an Actions secret. Host,
pinned SSH fingerprint, public URLs, and enable/disable gates are Actions
variables. The Website repository receives production and staging public build
URLs; the Flutter repository receives `PROD_API_BASE_URL`, `WEB_BASE_URL`,
`STAGING_API_BASE_URL`, `STAGING_WEB_BASE_URL`, and the public protection-grant
trust store. Local Flutter development uses the component `.env` and is not
published as a GitHub variable. Android/Windows signing material is provisioned
separately through protected release environments and is never read from the
deployment vault. CI auto-deploy is enabled (`ENABLE_VPS_DEPLOY=true`): a push
to `main` on the backend or website repository pulls the new image and runs the
environment-aware, non-destructive `update.sh` for both production and staging.
The SSH deploy script fails fast if production fails before staging runs, and
each image pull retries transient registry/network failures before giving up.
The authorized local `make deploy` path remains available for full deploys.
Cloudflare dry-run is local-only and does not
require or contact the API.

All classification remains on-device. This stack must never receive or log raw
DOM, URLs, domains, screenshots, or browsing history.
