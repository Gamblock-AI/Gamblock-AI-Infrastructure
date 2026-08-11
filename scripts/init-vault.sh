#!/bin/bash
# Generate strong application secrets and immediately encrypt a deliberately
# new production vault. Existing operational vaults are never overwritten.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VAULT_FILE="$PROJECT_DIR/group_vars/all/vault.yml"
VAULT_PASSWORD_FILE="$PROJECT_DIR/.vault_pass"

command -v ansible-vault >/dev/null 2>&1 || { echo "ansible-vault is required"; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "openssl is required"; exit 1; }
[ -s "$VAULT_PASSWORD_FILE" ] || { echo ".vault_pass must exist and be non-empty"; exit 1; }

if [ -e "$VAULT_FILE" ]; then
  echo "Refusing to overwrite existing group_vars/all/vault.yml"
  echo "Use make vault-integrations or make vault-edit to update it in place."
  exit 1
fi

if [ -z "${GAMBLOCK_VPS_PASSWORD:-}" ]; then
  read -rsp "Current VPS root password: " GAMBLOCK_VPS_PASSWORD
  echo
fi
[ "${#GAMBLOCK_VPS_PASSWORD}" -ge 12 ] || { echo "Root password must be at least 12 characters"; exit 1; }

yaml_quote() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '"%s"' "$value"
}

TEMP_FILE=$(mktemp)
cleanup() {
  chmod 600 "$TEMP_FILE" 2>/dev/null || true
  if command -v shred >/dev/null 2>&1; then
    shred -u "$TEMP_FILE" || rm -f "$TEMP_FILE"
  else
    rm -f "$TEMP_FILE"
  fi
}
trap cleanup EXIT
chmod 600 "$TEMP_FILE"

PROTECTION_GRANT_PRIVATE_KEY=$(
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 2>/dev/null |
    openssl pkcs8 -topk8 -nocrypt -outform DER 2>/dev/null |
    base64 | tr -d '\n'
)
[ -n "$PROTECTION_GRANT_PRIVATE_KEY" ] || {
  echo "Failed to generate the protection-grant signing key"
  exit 1
}

{
  echo "---"
  printf 'vault_vps_password: %s\n' "$(yaml_quote "$GAMBLOCK_VPS_PASSWORD")"
  printf 'vault_github_registry_pat: %s\n' "$(yaml_quote "${GAMBLOCK_GHCR_PAT:-}")"
  printf 'vault_postgres_password: %s\n' "$(yaml_quote "$(openssl rand -hex 32)")"
  echo "vault_gamblock_backend:"
  printf '  jwt_access_secret: %s\n' "$(yaml_quote "$(openssl rand -hex 32)")"
  printf '  journal_encryption_key: %s\n' "$(yaml_quote "$(openssl rand -hex 32)")"
  printf '  protection_grant_signing_private_key: %s\n' "$(yaml_quote "$PROTECTION_GRANT_PRIVATE_KEY")"
  printf '  fonnte_token: %s\n' "$(yaml_quote "${GAMBLOCK_FONNTE_TOKEN:-}")"
  echo '  fonnte_base_url: "https://api.fonnte.com"'
  echo '  fonnte_country_code: "62"'
  printf '  deepseek_api_key: %s\n' "$(yaml_quote "${GAMBLOCK_DEEPSEEK_API_KEY:-}")"
  printf 'vault_vapid_private_key: %s\n' "$(yaml_quote "${GAMBLOCK_VAPID_PRIVATE_KEY:-}")"
  printf 'vault_cloudflare_api_token: %s\n' "$(yaml_quote "${GAMBLOCK_CLOUDFLARE_API_TOKEN:-}")"
} > "$TEMP_FILE"

unset PROTECTION_GRANT_PRIVATE_KEY

ansible-vault encrypt \
  --vault-password-file "$VAULT_PASSWORD_FILE" \
  --encrypt-vault-id default \
  --output "$VAULT_FILE" "$TEMP_FILE"
chmod 600 "$VAULT_FILE"
echo "Encrypted vault initialized: group_vars/all/vault.yml"
echo "Use 'make vault-integrations' or 'make vault-edit' to finish provider credentials."
