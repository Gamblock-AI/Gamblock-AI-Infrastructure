# Gamblock-AI Infrastructure

Ansible infrastructure for deploying the Gamblock-AI backend, website, and
PostgreSQL services to a VPS behind Nginx Proxy Manager.

AI workflow context version: `2026-07-16.5`. This repository contains all
instructions needed to work on it; start with [`AGENTS.md`](AGENTS.md) and the
index in [`docs/ai/README.md`](docs/ai/README.md).

## Safety boundaries

Gamblock-AI performs AI inference on-device. This deployment must never collect
or persist DOM text, URLs, domains, screenshots, or browsing history. Only
aggregate supervision data may reach server-side services.

Commands that deploy, access a vault, open a remote shell, change GitHub
settings, or mutate Cloudflare DNS require explicit user approval immediately
before execution. Validation commands do not grant permission to deploy.

## Structure

```text
ansible.cfg                     # Ansible defaults
ansible-lint.cfg                # Secret-free lint/CI defaults
Makefile                        # Validation and operation shortcuts
requirements.yml / .txt         # Galaxy and Python dependencies
inventory/hosts.ini             # Target VPS
group_vars/all/
  vars.yml                      # Non-sensitive settings
  apps.yml                      # Backend and website container catalog
  vault.yml                     # Encrypted, tracked Ansible Vault
  vault.yml.example             # Template for a new environment
playbooks/server-setup.yml      # Main playbook
roles/                          # System, Docker, database, and app roles
scripts/                        # GitHub and Cloudflare helpers
docs/ai/                        # AI-context index and manifest
```

## Prerequisites

- Python and Ansible 9+
- Python packages from `requirements.txt`
- Galaxy collections from `requirements.yml`
- An SSH key available at `~/.ssh/server_ed25519`, or a user-specific override
  supplied outside Git
- The correct vault password obtained through an approved, out-of-band channel

Install local dependencies:

```sh
python -m pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml
```

## Fresh-clone setup

1. Review `inventory/hosts.ini` and replace the example/target host only when
   you are authorized to work with that environment. The inventory contains no
   workstation-specific absolute path.
2. Create the ignored vault-password file locally:

   ```sh
   cp .vault_pass.example .vault_pass
   ```

   Replace the placeholder with the approved password. Never commit or print
   `.vault_pass`.
3. For the existing environment, keep the tracked `group_vars/all/vault.yml`
   encrypted and obtain its matching password. Do not copy
   `vault.yml.example` over it.
4. For a deliberately new environment only, obtain approval before replacing
   `vault.yml`, fill the template locally, and encrypt it before any commit.
5. Run local validation:

   ```sh
   scripts/verify-ai-context.sh --allow-untracked
   make lint
   ```

## Validation and check mode

- `scripts/verify-ai-context.sh` validates committed context and portability.
- `scripts/verify-ai-context.sh --allow-untracked` is for authoring new context
  files before they are committed.
- `make lint` runs `ansible-lint` with the secret-free `ansible-lint.cfg` and
  placeholder-only `vault.yml.example`, so a fresh clone and CI do not need or
  open the production vault.
- `make check` performs local Ansible syntax validation.
- `make check-mode` contacts the configured VPS and runs the playbook with
  `--check`. It does not request a deployment, but still requires confirmation
  of the target and permission for external contact. It intentionally omits
  `--diff` so rendered secrets are not displayed.

`make lint` is the default AI check. `make check` and `make check-mode` run
only when explicitly requested; check mode also needs permission for external
contact. CI may keep additional automatic validation.

## Operations requiring approval

After explicit approval, the relevant commands are:

```sh
make deploy
make deploy-fresh
make app APP=gamblock-ai-backend
make app APP=gamblock-ai-website
```

Vault commands (`vault-view`, `vault-edit`, `vault-encrypt`, `vault-decrypt`),
remote access (`ssh`), GitHub secret changes, and Cloudflare changes also require
explicit approval. Prefer `github-secrets-dry` and `cloudflare-dry` to inspect a
planned operation, while remembering that dry runs may still access local vault
data or external APIs.

## Deployment flow

- The main playbook configures the base host, Docker, PostgreSQL, backend, and
  website roles.
- Application containers pull `ghcr.io/gamblock-ai/<app>:latest`.
- Backend and website delivery workflows can SSH to the VPS and invoke the
  installed `update.sh` script after their own tests pass.
- Nginx Proxy Manager is expected to exist on the shared
  `nginx_proxy_manager_network`; proxy hosts are managed separately.
- The backend template explicitly disables development login and demo records,
  supplies production notification mode, and mounts controlled artifact/export
  volumes. Backend startup now rejects missing PostgreSQL, weak JWT secrets, or
  an invalid AES-256 journal key in production.
- `NEXT_PUBLIC_GOOGLE_CLIENT_ID` is a public build-time website setting. The
  website image workflow accepts it from a repository variable, but configuring
  that external variable still requires separate owner authorization; the
  runtime Ansible `.env` cannot retrofit it into an already-built Next.js image.

## CI

Infrastructure CI verifies that the AI-context contract is committed and
self-contained, installs the declared project requirements, and runs
`make lint`.
CI never deploys, opens the vault, or mutates external systems.

## AI-context maintenance

`AGENTS.md` is the source of truth. Provider-specific files are intentionally
thin adapters so rules do not drift. When the context contract changes, update
the manifest and documentation together and bump the context version. See
[`docs/ai/README.md`](docs/ai/README.md) for the complete file map.
