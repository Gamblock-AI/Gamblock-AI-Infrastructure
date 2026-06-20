# Gamblock-AI Infrastructure

Ansible IaaC for deploying the Gamblock-AI platform to a VPS: Docker, PostgreSQL,
and the backend + website containers pulled from GitHub Container Registry (GHCR)
behind Nginx Proxy Manager.

## Structure

```
ansible.cfg                     # Ansible config (inventory, vault, sudo)
Makefile                        # Shortcut commands
requirements.yml / .txt         # Galaxy collections + Python deps
inventory/hosts.ini             # Target VPS
group_vars/all/
  vars.yml                      # Non-sensitive config (domains, ports, images)
  apps.yml                      # App catalog (backend + website)
  vault.yml.example             # Secret template -> copy to vault.yml, encrypt
playbooks/server-setup.yml      # Main playbook
roles/
  common/                       # update.sh + shared deploy tasks
  system/base-setup/            # deployer + app-deployer users, dirs
  infrastructure/docker-setup/  # Docker engine + networks
  databases/postgres-setup/     # PostgreSQL 16 container
  applications/
    gamblock-ai-backend-setup/  # backend compose + .env
    gamblock-ai-website-setup/  # website compose + .env
```

## Prerequisites

- Ansible 9+ (`pip install -r requirements.txt`)
- Galaxy collections: `ansible-galaxy collection install -r requirements.yml`
- SSH key to the VPS (default `~/.ssh/server_ed25519`, set in `ansible.cfg`)
- A GitHub PAT with `read:packages` scope (for GHCR pulls via `update.sh`)

## Setup

1. Edit `inventory/hosts.ini` with your VPS IP.
2. Create `.vault_pass` (already done — holds your vault password):
   ```sh
   # .vault_pass exists; edit it if needed
   ```
3. Copy the secret template and fill real values, then encrypt:
   ```sh
   cp group_vars/all/vault.yml.example group_vars/all/vault.yml
   # edit vault.yml with real secrets (GHCR token, VPS ssh key, Cloudflare token, ...)
   make vault-encrypt        # encrypts group_vars/all/vault.yml
   ```
   - `make vault-view` — view secrets without decrypting on disk
   - `make vault-edit` — edit (decrypts in-memory, re-encrypts on save)
   - `make vault-decrypt` — decrypt to plaintext (only when editing by hand)
4. Deploy the server:
   ```sh
   make deploy
   ```

## CI/CD cloud configuration (one-shot)

After the server is deployed and the vault is filled, configure GitHub repo
secrets/variables and Cloudflare DNS from your local machine:

```sh
make ci-init          # sets GitHub secrets + Cloudflare DNS (from vault)
# or individually:
make github-secrets   # VPS_HOST/VPS_USER/VPS_KEY/DOCKER_TOKEN + NEXT_PUBLIC_API_URL
make cloudflare       # A records for api.<domain> + app.<domain> -> VPS IP
```

Dry-run first to preview:
```sh
make github-secrets-dry
make cloudflare-dry
```

These scripts read everything from `group_vars` (vars.yml + encrypted vault.yml)
and the inventory — no hardcoded values. Prerequisites: `gh` CLI authenticated
(`gh auth login`) and `ansible-vault` available.

## Deploy flow

- `make deploy` runs the full playbook (system → docker → postgres → apps).
- `make app APP=gamblock-ai-backend` deploys one application.
- App containers pull `ghcr.io/gamblock-ai/<app>:latest` and run via docker-compose.
- CI auto-deploys: on push to `main`, the backend/website workflows build+push the
  image to GHCR, then SSH into the VPS and run `./update.sh` to pull + restart.

## CI/CD secrets (per backend + website repo)

Set these GitHub repository secrets for auto-deploy:
- `VPS_HOST` — server IP
- `VPS_USER` — `app-deployer`
- `VPS_KEY` — SSH private key for app-deployer

GHCR push uses the built-in `GITHUB_TOKEN` (no extra secret). For the website, set
a repository variable `NEXT_PUBLIC_API_URL` (e.g. `https://api.gamblock-ai.my.id`).

## Nginx Proxy Manager

This repo expects Nginx Proxy Manager (NPM) to be running on the VPS with the
`nginx_proxy_manager_network` Docker network. Configure proxy hosts manually in NPM:
- `api.<domain>` → `gamblock-ai-backend:8080`
- `app.<domain>` → `gamblock-ai-website:3000`

## Commands

- `make ping` — test connection
- `make check` — syntax check
- `make lint` — ansible-lint
- `make deploy` — full deploy
- `make deploy-fresh` — fresh deploy with migrations
- `make app APP=<name>` — single app (gamblock-ai-backend / gamblock-ai-website)
- `make ssh` — shell into the server
- `make vault-encrypt` / `vault-decrypt` / `vault-view` / `vault-edit` — manage secrets
- `make github-secrets` / `github-secrets-dry` — set GitHub CI secrets
- `make cloudflare` / `cloudflare-dry` — set Cloudflare DNS
- `make ci-init` — one-shot GitHub + Cloudflare setup
