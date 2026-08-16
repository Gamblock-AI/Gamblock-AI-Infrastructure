# Gamblock-AI Infrastructure — Agent Rules


This repository is self-contained and requires no external workspace context.
`AGENTS.md` is the canonical instruction file; provider adapters and the
context manifest are indexed in `docs/ai/README.md`.

Context version: `2026-08-16.3`

## Product safety boundaries

- Gamblock-AI performs all AI inference on-device. Infrastructure must never
  introduce collection, transport, logging, or storage of DOM text, URLs,
  domains, screenshots, or browsing history.
- The browser extension is a passive sensor. Blocking and Pattern Interrupt
  authority remains with the Android/Windows client, never the backend or web
  deployment.
- Anti-tamper must never mark a Windows process as critical. Safe protection
  uses the Android Accessibility Service and Windows SCM auto-restart.
- Infrastructure may deploy aggregate supervision data only. Never add raw
  browsing data to environment templates, logs, observability, or backups.
- Production backend templates keep development login/demo data disabled,
  provide persistent artifact/export volumes, and satisfy fail-closed
  PostgreSQL/JWT/AES configuration validation.
- `NEXT_PUBLIC_*` website values are public build-time image inputs, not
  runtime Ansible secrets. A runtime template cannot change an already-built
  Next.js bundle.

## Stack

- Ansible 9+ with Ansible Vault for secrets
- Docker containers for the backend and website, pulled from GHCR
- PostgreSQL 16
- Caddy 2 as the external reverse proxy with automated TLS

## Repository structure

```text
ansible.cfg              # inventory, roles, vault, and SSH defaults
ansible-lint.cfg         # secret-free config used only by lint/CI
Makefile                 # local validation and explicitly invoked operations
inventory/hosts.ini      # target VPS host and connection metadata
inventory/known_hosts    # pinned production host identity
group_vars/all/
  vars.yml               # non-sensitive shared configuration (both environments)
  apps.yml               # default application catalog (production shape)
  vault.yml              # encrypted Ansible Vault data
group_vars/environments/
  production.yml         # production overrides (domains, DB, runtime, seeding)
  staging.yml            # staging overrides (containers, DB, runtime, seeding)
playbooks/
  server-setup.yml       # main provisioning playbook (environment extra var)
roles/
  common/                # shared deploy tasks and update.sh
  system/                # base host configuration
  infrastructure/        # Docker and Caddy setup
  databases/             # PostgreSQL setup (one container, two databases)
  applications/          # backend and website deployments
scripts/                 # GitHub and Cloudflare helper scripts
docs/ai/                 # versioned AI-context index and manifest
```

## Commands and authorization boundary

Local validation commands are safe to run while editing:

```sh
scripts/verify-ai-context.sh --allow-untracked
make lint
```

`make lint` deliberately uses `ansible-lint.cfg` and the placeholder-only
`vault.yml.example`. It never opens the encrypted operational vault, so CI can
validate a fresh clone without production secrets. The repository's lint target
sets both `GAMBLOCK_LINT_MODE=1` and `GAMBLOCK_LINT_VAULT_FILE` for that one
process; normal playbook commands default to the encrypted
`group_vars/all/vault.yml`. Never export the lint-mode variables for an
operational command.

`make deploy` is the complete deployment path: it first validates configured
provider credentials through read-only endpoints, reconciles Cloudflare DNS,
provisions the host, snapshots PostgreSQL, runs backend migrate-up and the
environment's seeding plan, starts both applications and Caddy, then waits for
the public website and API health endpoints. It never invokes migrate-down.
The target environment is selected with `ENV`: `make deploy` (production) or
`make deploy ENV=staging`.

Environment-specific configuration lives in
`group_vars/environments/{production,staging}.yml` and is loaded through the
`environment` extra var. Both environments share one VPS, one PostgreSQL
container, one Caddy, and the shared networks, but use separate databases
(`gamblock` vs `gamblock_staging`), separate application containers/ports, and
separate domains. Caddy serves all five hosts (www redirect, production,
api, staging, api-staging) from one Caddyfile.

Seeding plans differ by environment:

- Production runs `migrate-up` plus `seed-accounts` only: the users-only
  seeder installs the four owner-approved demo accounts and no education,
  Learning Hub, social, activity, support, or operational fixtures, so
  production holds exactly the accounts with no fixture content. It fails
  closed when the database contains any account outside that fixture.
- Staging is reset fresh on every deploy: the staging API is stopped,
  `migrate-down` and `reset-storage` run with their confirmation variables,
  then `migrate-up`, `seeder`, `seed-learning-hub`, and `demo-seeder` run —
  every seeder available in the backend image, including the full demo
  accounts-and-fixtures seeder. The staging backend uses
  `APP_ENV=staging`, demo WhatsApp codes, and dev login; it never uses
  `ENABLE_DEMO_DATA` (it still persists to PostgreSQL).

`update.sh` stays non-destructive and environment-aware: it sources the
Ansible-rendered `update.env` (database name/user, container, seeding plan)
and never performs a fresh reset. Guarded tools (`migrate-down`,
`reset-storage`, `demo-seeder`, `seed-accounts`) receive their exact
confirmation variables from the rendered application `.env` and are never added
outside the staging fresh-reset path.

The backend Compose `tools` profile exposes owner-invoked
`migrate-down`, `reset-storage`, `seeder`, `seed-learning-hub`,
`demo-seeder`, and `seed-accounts` services. They require exact confirmation
variables at invocation
time. Only `migrate-up` and the environment's seeding plan run during normal
deploys; `migrate-down`/`reset-storage` run only inside the staging
fresh-reset path and are never added to `update.sh`.

`make credential-check` opens the encrypted vault in memory and prints only
field-level status; it still requires explicit vault-access authorization.
`make credential-check-online` also contacts GHCR, Cloudflare, Fonnte, and
DeepSeek through read-only endpoints and requires external-contact approval.

`make check-mode` contacts the configured host but asks Ansible to simulate the
playbook with `--check`; confirm the intended inventory and permission to make
external contact before running it.

Never run any of the following without explicit user authorization in the
current conversation:

- Deployment or remote shell: `make bootstrap`, `make deploy`, `make app`,
  `make ssh`
- Vault access or mutation: `make vault-view`, `make vault-edit`,
  `make vault-encrypt`, `make vault-decrypt`
- External account or DNS mutation: `make ci-init`, `make github-secrets`,
  `make cloudflare`
- Any direct `ansible-playbook`, `ansible-vault`, `gh`, Cloudflare API, Docker
  registry, or SSH command that changes external state

Dry-run helpers can still expose target metadata or contact external services.
State what they access before running them and honor the user's authorization.

## Secrets and configuration

- `.vault_pass` and `.env` are local, gitignored files. Never print or commit
  their contents, and keep them mode `0600`.
- The production inventory uses only `root`, password authentication, SSH port
  22, and the pinned host key. Do not add deploy users, authentication keys, or
  a custom port unless the owner changes this operational decision.
- `group_vars/all/vault.yml` must remain Ansible-Vault encrypted in Git.
- Do not overwrite the tracked vault with `vault.yml.example` unless the user
  explicitly intends to initialize a different environment.
- Keep non-sensitive values in `vars.yml`, container definitions in `apps.yml`,
  and secrets in the encrypted vault.
- Keep SSH host identity in `inventory/known_hosts`; never replace the pinned
  key from an unverified network observation or commit a workstation path.
- Keep the matching `VPS_HOST_FINGERPRINT` Actions variable on both deploy
  repositories; CI SSH must fail closed when the host identity changes.
- Keep Fonnte, VAPID, and conditional DeepSeek gates aligned across the vault,
  backend environment template, and redacted credential validator.
- Keep the protection-grant ES256 private key only in the encrypted backend
  vault. Its non-secret `kid` and public trust store must match the Android and
  Windows release variables; never reuse JWT, VAPID, APK, or Authenticode keys.

## Change rules

- Add a service by creating an application role, registering it in `apps.yml`,
  and including it in `playbooks/server-setup.yml`.
- Keep roles focused on one infrastructure concern and preserve idempotency.
- Use Ansible modules instead of shell commands when a suitable module exists.
- Treat `roles/common/files/update.sh` as production deployment code; preserve
  strict error handling and never echo credentials.
- Keep `AGENTS.md`, `README.md`, and `docs/ai/manifest.yaml` synchronized when
  workflow, structure, safety boundaries, or commands change. Bump the context
  version for an intentional context contract revision.
- Do not rename existing hyphenated role directories as incidental cleanup;
  their names are explicitly exempted in `.ansible-lint` to avoid a broad,
  deployment-sensitive refactor.

## Default validation policy

Before handing off a change:

1. Run `scripts/verify-ai-context.sh --allow-untracked` while new context files
   are not committed. CI runs the stricter form without the flag.
2. Run `make lint`.
3. When vault/provider access was explicitly authorized, run the narrow
   `make credential-check` and optionally `make credential-check-online` gates.
4. Do not run `make check`, `make check-mode`, tests, builds, or deployment
   verification unless the user explicitly requests them. `make check-mode`
   additionally requires external-contact approval.

CI may retain syntax/full quality gates; this policy controls local commands
run by the AI after an ordinary prompt.
