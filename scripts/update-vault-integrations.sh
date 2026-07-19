#!/bin/bash
# Update third-party tokens without showing or keeping plaintext vault content.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VAULT_FILE="$PROJECT_DIR/group_vars/all/vault.yml"
VAULT_PASSWORD_FILE="$PROJECT_DIR/.vault_pass"

command -v ansible-vault >/dev/null 2>&1 || { echo "ansible-vault is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required"; exit 1; }
[ -s "$VAULT_PASSWORD_FILE" ] || { echo ".vault_pass must exist and be non-empty"; exit 1; }

read -rsp "GitHub PAT for private GHCR pulls: " GHCR_PAT
echo
read -rsp "Cloudflare API token: " CLOUDFLARE_TOKEN
echo

case "$GHCR_PAT" in
  ghp_*|github_pat_*) ;;
  *) echo "GitHub PAT format is not recognized"; exit 1 ;;
esac
case "$CLOUDFLARE_TOKEN" in
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
GAMBLOCK_CLOUDFLARE_TOKEN="$CLOUDFLARE_TOKEN" \
python3 - "$PLAIN_FILE" <<'PY'
import os
import pathlib
import sys
import tempfile

import yaml

path = pathlib.Path(sys.argv[1])
with path.open(encoding="utf-8") as handle:
    values = yaml.safe_load(handle)

values["vault_github_registry_pat"] = os.environ["GAMBLOCK_GHCR_PAT"]
values["vault_cloudflare_api_token"] = os.environ["GAMBLOCK_CLOUDFLARE_TOKEN"]

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

unset GHCR_PAT CLOUDFLARE_TOKEN
echo "Encrypted vault integration tokens updated."
