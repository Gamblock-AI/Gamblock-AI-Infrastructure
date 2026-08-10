#!/bin/bash
# Update selected third-party tokens without showing their values. Blank input
# preserves the encrypted value already in the vault.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VAULT_FILE="$PROJECT_DIR/group_vars/all/vault.yml"
VAULT_PASSWORD_FILE="$PROJECT_DIR/.vault_pass"

command -v ansible-vault >/dev/null 2>&1 || { echo "ansible-vault is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required"; exit 1; }
[ -s "$VAULT_PASSWORD_FILE" ] || { echo ".vault_pass must exist and be non-empty"; exit 1; }

NON_INTERACTIVE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --non-interactive) NON_INTERACTIVE=true ;;
    -h|--help)
      echo "Usage: $0 [--non-interactive]"
      echo "Non-interactive mode reads GAMBLOCK_GHCR_PAT, GAMBLOCK_CLOUDFLARE_API_TOKEN,"
      echo "GAMBLOCK_FONNTE_TOKEN, and GAMBLOCK_DEEPSEEK_API_KEY from the environment."
      exit 0
      ;;
    *) echo "Unknown argument: $1"; exit 2 ;;
  esac
  shift
done

GHCR_PAT=${GAMBLOCK_GHCR_PAT:-}
CLOUDFLARE_TOKEN=${GAMBLOCK_CLOUDFLARE_API_TOKEN:-}
FONNTE_TOKEN=${GAMBLOCK_FONNTE_TOKEN:-}
DEEPSEEK_API_KEY=${GAMBLOCK_DEEPSEEK_API_KEY:-}

if [ "$NON_INTERACTIVE" = false ]; then
  read -rsp "GitHub PAT for private GHCR pulls (blank preserves current): " GHCR_PAT
  echo
  read -rsp "Cloudflare API token (blank preserves current): " CLOUDFLARE_TOKEN
  echo
  read -rsp "Fonnte token (blank preserves current): " FONNTE_TOKEN
  echo
  read -rsp "DeepSeek API key (blank preserves current): " DEEPSEEK_API_KEY
  echo
fi

[ -n "$GHCR_PAT$CLOUDFLARE_TOKEN$FONNTE_TOKEN$DEEPSEEK_API_KEY" ] || {
  echo "No integration token update was requested"
  exit 1
}

case "$GHCR_PAT" in
  "") ;;
  ghp_*|github_pat_*) ;;
  *) echo "GitHub PAT format is not recognized"; exit 1 ;;
esac
case "$CLOUDFLARE_TOKEN" in
  "") ;;
  cfut_*) ;;
  *) echo "Cloudflare token format is not recognized"; exit 1 ;;
esac

PLAIN_FILE=$(mktemp)
ENCRYPTED_FILE=$(mktemp)
cleanup() {
  for secret_file in "$PLAIN_FILE" "$ENCRYPTED_FILE"; do
    chmod 600 "$secret_file" 2>/dev/null || true
    if command -v shred >/dev/null 2>&1; then
      shred -u "$secret_file" 2>/dev/null || rm -f "$secret_file"
    else
      rm -f "$secret_file"
    fi
  done
}
trap cleanup EXIT
chmod 600 "$PLAIN_FILE" "$ENCRYPTED_FILE"

ansible-vault decrypt \
  --vault-password-file "$VAULT_PASSWORD_FILE" \
  --output "$PLAIN_FILE" "$VAULT_FILE" >/dev/null

GAMBLOCK_GHCR_PAT="$GHCR_PAT" \
GAMBLOCK_CLOUDFLARE_API_TOKEN="$CLOUDFLARE_TOKEN" \
GAMBLOCK_FONNTE_TOKEN="$FONNTE_TOKEN" \
GAMBLOCK_DEEPSEEK_API_KEY="$DEEPSEEK_API_KEY" \
python3 - "$PLAIN_FILE" <<'PY'
import os
import pathlib
import sys
import tempfile

import yaml

path = pathlib.Path(sys.argv[1])
with path.open(encoding="utf-8") as handle:
    values = yaml.safe_load(handle)

updates = {
    "vault_github_registry_pat": os.environ.get("GAMBLOCK_GHCR_PAT", ""),
    "vault_cloudflare_api_token": os.environ.get("GAMBLOCK_CLOUDFLARE_API_TOKEN", ""),
}
for key, value in updates.items():
    if value:
        values[key] = value

backend = values.setdefault("vault_gamblock_backend", {})
if not isinstance(backend, dict):
    raise SystemExit("vault_gamblock_backend must be a mapping")
backend_updates = {
    "fonnte_token": os.environ.get("GAMBLOCK_FONNTE_TOKEN", ""),
    "deepseek_api_key": os.environ.get("GAMBLOCK_DEEPSEEK_API_KEY", ""),
}
for key, value in backend_updates.items():
    if value:
        backend[key] = value

with tempfile.NamedTemporaryFile(
    "w", encoding="utf-8", dir=path.parent, delete=False
) as handle:
    yaml.safe_dump(values, handle, sort_keys=False)
    replacement = pathlib.Path(handle.name)
replacement.chmod(0o600)
replacement.replace(path)
PY

ansible-vault encrypt \
  --vault-password-file "$VAULT_PASSWORD_FILE" \
  --encrypt-vault-id default \
  --output "$ENCRYPTED_FILE" "$PLAIN_FILE" >/dev/null
install -m 0600 "$ENCRYPTED_FILE" "$VAULT_FILE"

unset GHCR_PAT CLOUDFLARE_TOKEN FONNTE_TOKEN DEEPSEEK_API_KEY
unset GAMBLOCK_GHCR_PAT GAMBLOCK_CLOUDFLARE_API_TOKEN
unset GAMBLOCK_FONNTE_TOKEN GAMBLOCK_DEEPSEEK_API_KEY
echo "Encrypted vault integration tokens updated; unchanged values were preserved."
