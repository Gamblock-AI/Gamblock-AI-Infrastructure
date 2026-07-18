# Gamblock-AI Infrastructure — Agent Rules

Context version: `2026-07-18.3`

This repository is self-contained and requires no external workspace context.
`AGENTS.md` is the canonical instruction file; provider adapters and the
context manifest are indexed in `docs/ai/README.md`.

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
- Nginx Proxy Manager as the external reverse proxy

## Repository structure

```text
ansible.cfg              # inventory, roles, vault, and SSH defaults
ansible-lint.cfg         # secret-free config used only by lint/CI
Makefile                 # local validation and explicitly invoked operations
inventory/hosts.ini      # target VPS host and connection metadata
group_vars/all/
  vars.yml               # non-sensitive configuration
  apps.yml               # application/container catalog
  vault.yml              # encrypted Ansible Vault data
playbooks/
  server-setup.yml       # main provisioning playbook
roles/
  common/                # shared deploy tasks and update.sh
  system/                # base host configuration
  infrastructure/        # Docker setup
  databases/             # PostgreSQL setup
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

`make check-mode` contacts the configured host but asks Ansible to simulate the
playbook with `--check`; confirm the intended inventory and permission to make
external contact before running it.

Never run any of the following without explicit user authorization in the
current conversation:

- Deployment or remote shell: `make deploy`, `make deploy-fresh`, `make app`,
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
  their contents.
- `group_vars/all/vault.yml` must remain Ansible-Vault encrypted in Git.
- Do not overwrite the tracked vault with `vault.yml.example` unless the user
  explicitly intends to initialize a different environment.
- Keep non-sensitive values in `vars.yml`, container definitions in `apps.yml`,
  and secrets in the encrypted vault.
- Use user-relative SSH configuration from `ansible.cfg`; never commit an
  absolute workstation path.

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
3. Do not run `make check`, `make check-mode`, tests, builds, or deployment
   verification unless the user explicitly requests them. `make check-mode`
   additionally requires external-contact approval.

CI may retain syntax/full quality gates; this policy controls local commands
run by the AI after an ordinary prompt.
