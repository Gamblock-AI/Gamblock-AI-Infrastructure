# Gamblock-AI Infrastructure

Ansible deployment for the Gamblock-AI backend, website, PostgreSQL, and Caddy
on one Ubuntu VPS.

AI workflow context version: `2026-07-20.5`. Start with [`AGENTS.md`](AGENTS.md)
and [`docs/ai/README.md`](docs/ai/README.md).

## Production shape

- `https://gamblock-ai.com` → website
- `https://www.gamblock-ai.com` → permanent apex redirect
- `https://api.gamblock-ai.com` → backend
- Cloudflare proxied DNS in Full (strict) mode
- Caddy `2.11.4-alpine` with automatic origin TLS
- PostgreSQL 16 and private GHCR application images
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
playbooks/server-setup.yml
roles/system/base-setup/
roles/infrastructure/{docker-setup,caddy-setup}/
roles/databases/postgres-setup/
roles/applications/
roles/common/files/update.sh
scripts/{init-vault,github-secrets,cloudflare-dns,verify-production}.sh
```

## Local setup and validation

```sh
python -m pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml
cp .vault_pass.example .vault_pass
make lint
scripts/verify-ai-context.sh --allow-untracked
```

`.vault_pass` is ignored and must contain the password for the tracked encrypted
`group_vars/all/vault.yml`. For a deliberately new environment, `make
vault-init` prompts for the current VPS root password, generates independent
PostgreSQL/JWT/AES values, and encrypts the result immediately. Add remaining
credentials with `make vault-edit`, or update only the GHCR and Cloudflare
tokens without opening an editor using `make vault-integrations`. Never keep a
plaintext vault.

`make lint` uses only `vault.yml.example`. `make check` is local syntax
validation. `make ping`, `make check-mode`, `make bootstrap`, deployment,
remote shell, vault access, GitHub mutation, and Cloudflare mutation require
the authorization described in `AGENTS.md`.

## Readiness gates

Normal application deployment intentionally stops before remote changes until
all of these are configured in the encrypted vault:

- a GitHub PAT with `read:packages` for private GHCR pulls;
- valid PostgreSQL, JWT, and 64-character journal encryption values.

SMTP and WhatsApp are optional delivery adapters. Without them, the stack still
deploys in production mode but email verification/reset/export notifications
and WhatsApp delivery remain unavailable; demo codes stay disabled. The
Cloudflare helper separately requires a token
with Zone Read, DNS Edit, and Zone Settings Edit for `gamblock-ai.com`.

## Authorized operation sequence

```sh
make ping
make bootstrap
make deploy
make app APP=gamblock-ai-backend
make app APP=gamblock-ai-website
make ssh
```

`bootstrap` provisions the host, Docker, PostgreSQL, and Caddy without the
third-party application gates. `deploy` is the one-command production path: it
updates Cloudflare DNS/strict SSL, provisions the complete stack, creates a
pre-deploy PostgreSQL backup, runs `migrate-up` and the production-safe seeder,
starts the backend/website/Caddy, and waits until the public website and API
health endpoint both answer successfully. `app` selects the requested role;
the backend role also performs backup, migration, and safe seeding.

The backend template disables development login/demo data, uses one PostgreSQL
password consistently, includes web and Windows Google audiences, keeps
delivery providers optional, and mounts artifact, export, education-media, and
avatar storage. Its `tools` profile exposes `migrate-up`, guarded
`migrate-down`, and `seeder`; automatic deployment calls only migrate-up and
the production-safe seeder. Pre-deploy backups are retained for 14 days. The
website's public API and Google client ID are Docker build-time GitHub
variables; Ansible cannot retrofit them into an already-built Next.js image.

## GitHub and Cloudflare helpers

```sh
make github-secrets-dry
make github-secrets
make cloudflare-dry
make cloudflare
```

GitHub configuration stores only `VPS_PASSWORD` as an Actions secret. Host,
public URLs, OAuth client IDs, and enable/disable gates are Actions
variables. `ENABLE_VPS_DEPLOY` defaults to `false` until the first bootstrap is
verified. Cloudflare dry-run is local-only and does not require or contact the
API.

All classification remains on-device. This stack must never receive or log raw
DOM, URLs, domains, screenshots, or browsing history.
