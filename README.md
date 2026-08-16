# Gamblock-AI Infrastructure

Ansible deployment for the Gamblock-AI backend, website, PostgreSQL, and Caddy
on one Ubuntu VPS.

AI workflow context version: `2026-08-16.3`. Start with [`AGENTS.md`](AGENTS.md)
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
make deploy                 # production (gamblock-ai.com)
make deploy ENV=staging     # staging (staging.gamblock-ai.com)
make app APP=gamblock-ai-backend
make app APP=gamblock-ai-backend ENV=staging
make app APP=gamblock-ai-website ENV=staging
make ssh
```

`bootstrap` provisions the host, Docker, PostgreSQL (both databases), and Caddy
without the third-party application gates. `deploy` is the one-command path for
the selected environment: it updates Cloudflare DNS/strict SSL, provisions the
stack, creates a pre-deploy PostgreSQL backup, runs `migrate-up` and the
environment's seeding plan, starts the applications and Caddy, and waits until
the environment's public website and API health endpoints both answer. `app`
selects the requested role for the selected environment.

Seeding plans per environment:

- **production** — `migrate-up` + `seed-accounts` only (the four demo accounts
  with **no** fixture content). The users-only seeder refuses any database that
  contains accounts outside the approved fixture, so the deploy fails closed
  once real student accounts exist, and it never seeds education, Learning Hub,
  social, activity, support, or operational fixtures.
- **staging** — fresh reset on every deploy: the staging API is stopped,
  `migrate-down` + `reset-storage` run with their confirmation variables,
  then `migrate-up`, `seeder`, `seed-learning-hub`, and `demo-seeder` run
  (every seeder available in the backend image, including the full
  accounts-and-fixtures demo seeder).
  The staging backend uses `APP_ENV=staging` with demo WhatsApp codes and dev
  login while still persisting to PostgreSQL.

The backend template keeps production development login/demo data disabled,
mounts artifact, export, education-media, and avatar storage, and renders the
guarded confirmation variables for the one-shot tools. `update.sh` sources the
Ansible-rendered `update.env` (database name/user, container, seeding plan),
stays non-destructive, and never performs a fresh reset. Pre-deploy and update
backups are retained for 14 days. The website's public API, app URL, and VAPID
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

Keep the API stopped if any one-shot service fails. Both seeders accept an
empty database or the exact four known fixtures only; they reject unrelated
accounts, never seed education/Learning Hub/social/activity content through the
automatic production path, and are never called by `make deploy` or
`update.sh`.

## GitHub and Cloudflare helpers

```sh
make github-secrets-dry
make github-secrets
make cloudflare-dry
make cloudflare
```

GitHub configuration stores only `VPS_PASSWORD` as an Actions secret. Host,
pinned SSH fingerprint, public URLs, and enable/disable gates are Actions
variables. The Flutter repository additionally receives only the public
protection-grant trust store; Android/Windows signing material is provisioned
separately through protected release environments and is never read from the
deployment vault. The current bootstrapped production environment deliberately keeps
`ENABLE_VPS_DEPLOY=false`: GitHub-hosted runners cannot reliably reach the
password-authenticated SSH endpoint. Use the authorized local `make deploy`
path for production changes. Cloudflare dry-run is local-only and does not
require or contact the API.

All classification remains on-device. This stack must never receive or log raw
DOM, URLs, domains, screenshots, or browsing history.
