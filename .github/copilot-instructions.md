# Gamblock-AI Infrastructure instructions

Follow [`AGENTS.md`](../AGENTS.md) as the canonical, self-contained repository
instruction file. Context version: `2026-07-15.2`.

Do not expose secrets, introduce raw browsing-data collection, or execute
deploy, vault, SSH, GitHub, Cloudflare, or other external mutations without
explicit user authorization. Keep changes idempotent and verify them with
`scripts/verify-ai-context.sh --allow-untracked` and `make lint`.
