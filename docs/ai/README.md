# AI Context Index

Context version: `2026-07-20.5`

This repository is intentionally self-contained. A clone does not need a
parent workspace to discover its product constraints, infrastructure workflow,
or safety rules.

## Source hierarchy

1. `AGENTS.md` is the canonical source of repository instructions.
2. `docs/ai/manifest.yaml` declares the context version and required files.
3. `CLAUDE.md`, `GEMINI.md`, `.github/copilot-instructions.md`, and
   `.cursor/rules/gamblock-ai.mdc` adapt supported tools to `AGENTS.md`.
4. `COPILOT.md` and `.cursorrules` are legacy discovery pointers only.

Provider adapters must stay thin. Product invariants, authorization rules, and
implementation conventions belong in `AGENTS.md`, not in duplicated provider
files.

## Verification

From the repository root, run:

```sh
scripts/verify-ai-context.sh
```

That strict mode requires every context file to be tracked, matching CI. While
creating new files locally, use:

```sh
scripts/verify-ai-context.sh --allow-untracked
```

The relaxed option skips only the Git tracking assertion. It still validates
the version, provider imports, manifest entries, secret hygiene, and portable
paths.

## Updating context

When instructions materially change:

1. Update `AGENTS.md` and any affected repository documentation.
2. Choose a new context version and update `AGENTS.md`, `README.md`, this file,
   `docs/ai/manifest.yaml`, and the verifier's expected version.
3. Keep adapters as references to `AGENTS.md`.
4. Run the relaxed verifier during authoring, then the strict verifier after
   files are staged or committed.
5. Run `make lint`.

This component is operational support for the PKM prototype. It must not add
cloud inference or browsing-data collection. `make lint` is the default AI
check; syntax/check-mode/deployment checks run only on explicit request, and
external contact still requires authorization.

The production topology is one root/password/port-22 VPS with a pinned SSH
host key, Docker, PostgreSQL, and Caddy-managed TLS. The backend deployment
template keeps `ENABLE_DEV_LOGIN=false` and `ENABLE_DEMO_DATA=false`, mounts
artifact/export/media/avatar storage, and provides the production values
required by backend fail-closed core configuration validation. A missing
private-GHCR pull token remains a pre-deployment gate; SMTP and WhatsApp are
optional delivery adapters and missing values disable only their workflows.
Public Next.js variables, including Google OAuth's public client ID, are
build-time image inputs and are not secret runtime Ansible substitutions.

The complete `make deploy` path reconciles Cloudflare DNS before Caddy
certificate issuance, snapshots PostgreSQL, runs the image's migrate-up and
production-safe seeder one-shot services, starts the applications, and waits
for both public HTTPS endpoints. Backups older than 14 days are removed.
Migrate-down exists as a guarded manual tool only and is never invoked by
Ansible or deployment updates.

Production-host evidence on 2026-07-20: the root/password/pinned-host-key
connection passed and the idempotent bootstrap completed on the configured
VPS. UFW, fail2ban, unattended upgrades, a 2 GiB swapfile, Docker, healthy
PostgreSQL 16, and healthy Caddy 2.11.4 are active. Application deployment is
still waiting for the current backend/website images to be published to GHCR.
DNS reconciliation and public health verification are now part of the
authorized `make deploy` operation. SMTP and WhatsApp are not deployment
blockers.
