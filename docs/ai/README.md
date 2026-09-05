# AI Context Index


Jika ada pertentangan dengan `pkm_proposal.md`, proposal PKM adalah sumber mutlak.

Context version: `2026-09-06.1`

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

The topology is one root/password/port-22 VPS with a pinned SSH host key,
Docker, one PostgreSQL 16 container, and Caddy-managed TLS serving two
environments: production (`gamblock-ai.com` + `api.gamblock-ai.com`) and
staging (`staging.gamblock-ai.com` + `api-staging.gamblock-ai.com`). Each
environment uses its own database (`gamblock` vs `gamblock_staging`), its own
application containers and internal ports, and its own domains; Caddy routes
all five hosts from one Caddyfile. Environment-specific variables live in
`group_vars/environments/{production,staging}.yml`, loaded through the
`environment` extra var (`make deploy ENV=staging`). GitHub deploy workflows
retain the pinned-host identity contract and are enabled: a push to `main` on
the backend or website repository pulls the new image and runs the
environment-aware, non-destructive `update.sh` for both production and staging.
The authorized local `make deploy` path remains canonical for full deploys. The backend deployment
template keeps production on `APP_ENV=production` with dev login/demo data
disabled, mounts artifact/export/media/avatar storage, and provides the
production values required by backend fail-closed configuration validation.
Private-GHCR, Fonnte, VAPID, the device-bound protection-grant P-256 keypair,
and—while the SPK LLM gate is enabled—DeepSeek credentials are pre-deployment
gates. The credential validator matches the active backend private key to the
public Android/Windows trust-store entry without printing either value. Public
Next.js variables are build-time image inputs and are not secret runtime
Ansible substitutions; the staging website image (`:staging`) is built by
website CI with the staging public URLs. The infrastructure GitHub helper keeps
the Flutter production and staging public URL variables aligned with this
contract; local Flutter development uses its component `.env` instead.

### Environment contract (staging vs production)

Staging runtime behavior is intentionally identical to production. Do not
re-introduce a `demo`/dev-only divergence without an explicit owner decision.

| Aspect | Production | Staging |
|---|---|---|
| `APP_ENV` | `production` | `production` (same fail-closed validation, strict CORS, no dev login) |
| `NOTIFICATION_MODE` | `production` | `production` (real Fonnte OTP/WhatsApp delivery; no demo preview codes) |
| `ENABLE_DEV_LOGIN` | `false` | `false` |
| `ENABLE_DEMO_DATA` | `false` | `false` |
| Database | `gamblock` | `gamblock_staging` |
| Domains / CORS / web base URL | `gamblock-ai.com` | `staging.gamblock-ai.com` |
| Seeding plan | `seed-accounts` only, gated on an empty database (`seed_only_when_empty: true`) — four accounts, **no** fixture content | `seeder` + `seed-learning-hub` + `demo-seeder` (**four accounts + full fixture set** — intentional) |
| Destructive reset | `fresh_reset_before_deploy: false` | `fresh_reset_before_deploy: false` (staging is NOT reset; data persists between deploys like production) |

Key implications:

- OTP and all Fonnte notifications are sent for real in both environments.
  There is a single `FONNTE_TOKEN` in the vault, so staging and production
  share the same WhatsApp device; this is a shared-delivery trait, not a data
  overlap. The backend also reads one shared `DEEPSEEK_API_KEY` from the vault
  in both environments; local development intentionally uses those same two
  provider values in its private `.env`.
- Production contains exactly the four owner-approved demo accounts and nothing
  else when it is seeded fresh. Once any account exists, the automatic seed plan
  is skipped and the populated database is left unchanged on deploy. Staging
  keeps the four demo accounts plus all fixture content
  (education, Learning Hub, activity, support, operational rows) so QA has
  realistic data. This asymmetry is by design and must not be "fixed".
- Both environments fail closed like production for configuration, database,
  and CORS because staging also runs `APP_ENV=production`.
- Neither environment is reset on deploy. `fresh_reset_before_deploy` is
  `false` for both; `migrate-down`/`reset-storage` remain owner-invoked manual
  tools only.

### Local development contract

Local development is intentionally provider-connected rather than demo-only.
The current local backend `.env` uses the same `FONNTE_TOKEN` and
`DEEPSEEK_API_KEY` values as the production and staging backend environments,
while keeping `APP_ENV=development`. Local backend notification mode is
`production`, so Fonnte-backed verification, reset, export/deletion, and
emergency flows can send real WhatsApp messages. DeepSeek-backed translation
and SPK personalization can make real API calls when invoked; SPK
personalization remains subject to the user's privacy preference.

The local application database is separate from both server databases and must
be a local PostgreSQL instance. The current Flutter local configuration targets
the Android-emulator host aliases `http://10.0.2.2:8080` and
`http://10.0.2.2:3000`; desktop or browser runs use loopback URLs instead. The
local `.env` files are gitignored/private configuration and are never
published as GitHub variables. The safe `.env.example` defaults remain
demo/blank so a fresh clone cannot accidentally send provider traffic before
the developer explicitly opts into the local connected setup.

All three environments must preserve the privacy boundary: DeepSeek receives
only the permitted SPK decision and self-reported context for personalization,
and no environment may send raw DOM, URLs, domains, screenshots, or browsing
history to external providers.



The complete `make deploy` path first validates GHCR, Cloudflare, Fonnte, and
DeepSeek credentials through read-only provider endpoints, then reconciles
Cloudflare DNS before Caddy certificate issuance. Without `ENV`, it runs the
full environment flow sequentially—production first, then staging—so each
environment snapshots its own PostgreSQL database, runs its seeding plan,
starts its application, and waits for its public HTTPS endpoints. An explicit
`ENV=production` or `ENV=staging` runs only that environment. Seeding differs
per environment: production runs
`migrate-up` plus the users-only `seed-accounts` binary (the four accounts
with no education/Learning Hub/social/activity fixtures), but the account seed
plan is gated on an empty users table — a populated production database is
left exactly as-is on deploy and the seeder only runs against an empty or
fresh-reset database. Staging runs `migrate-up` → `seeder` →
`seed-learning-hub` → `demo-seeder` (all seeders). Neither environment is reset
on deploy; `migrate-down`/`reset-storage` are owner-invoked manual tools only.
The production step targets the production containers and `gamblock`, while
the staging step targets the staging containers and `gamblock_staging`; the
shared PostgreSQL container and Caddy configuration are kept common to both
paths. The default flow is fail-fast: a production failure prevents staging
from starting, while a staging failure after a successful production step
returns failure without automatically rolling production back.
Ansible and CI update
backups older than 14 days are removed. A nightly scheduled backup
(`roles/system/backup-setup`) archives both PostgreSQL databases (production
`gamblock` and staging `gamblock_staging`) plus the dynamic file volumes of
every backend container (education media, exports, artifacts, avatars) into
`{{ docker_stack_base }}/backups`, pruned by the same 14-day retention.
`update.sh` remains non-destructive
and environment-aware through the rendered `update.env`, and when the
environment is seed-only-when-empty it skips `seed-accounts`/`demo-seeder` at
runtime if the database already contains user accounts.
Migrate-down, dynamic-storage reset, the full demo seeder, and the users-only
account seeder remain
separately guarded manual tools and are never invoked by `update.sh`.

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

## Cross-repository testing

Runtime and cross-repository evaluation evidence is owned by the public
[Gamblock-AI-Testing repository](https://github.com/Gamblock-AI/Gamblock-AI-Testing).
Infrastructure documentation does not duplicate test results or contain device
evidence. Infrastructure is not currently a runner/report target; do not
invent a testing report. If the scope is explicitly expanded, use the shared
test receipt to identify public and private/local data changes.
