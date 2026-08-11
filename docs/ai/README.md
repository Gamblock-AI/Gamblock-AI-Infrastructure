# AI Context Index


Jika ada pertentangan dengan `pkm_proposal.md`, proposal PKM adalah sumber mutlak.

Context version: `2026-08-12.2`

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
host key, Docker, PostgreSQL, and Caddy-managed TLS. Both GitHub deploy
workflows receive the trusted fingerprint as an Actions variable and fail
closed on a different host identity. The backend deployment template keeps
`ENABLE_DEV_LOGIN=false` and `ENABLE_DEMO_DATA=false`, mounts
artifact/export/media/avatar storage, and provides the production values
required by backend fail-closed configuration validation. Private-GHCR,
Fonnte, VAPID, the device-bound protection-grant P-256 keypair, and—while the
SPK LLM gate is enabled—DeepSeek credentials are pre-deployment gates. The
credential validator matches the active backend private key to the public
Android/Windows trust-store entry without printing either value. Public Next.js variables are
build-time image inputs and are not secret runtime Ansible substitutions.

The complete `make deploy` path first validates GHCR, Cloudflare, Fonnte, and
DeepSeek credentials through read-only provider endpoints, then reconciles
Cloudflare DNS before Caddy certificate issuance, snapshots PostgreSQL, runs
the image's migrate-up and production-safe seeder one-shot services, starts the
applications, and waits for both public HTTPS endpoints. Ansible and CI update
backups older than 14 days are removed.
Migrate-down, dynamic-storage reset, and the four-account demo seeder exist as
separately guarded manual tools only and are never invoked by Ansible or
deployment updates.

Production-host evidence rechecked on 2026-08-11: the
root/password/pinned-host-key connection passed on the configured VPS. UFW,
fail2ban, unattended upgrades, a 2 GiB swapfile, Docker, healthy PostgreSQL 16,
and healthy Caddy 2.11.4 are active. The current website image
starts Next.js successfully, but its Compose health probe must use
`127.0.0.1` rather than `localhost`: the container resolves `localhost` to
IPv6 first while Next.js listens on IPv4. The image and Compose templates now
use the explicit IPv4 loopback address. DNS reconciliation and public health
verification are part of the authorized `make deploy` operation. SMTP remains
optional; the production Fonnte adapter is required.
