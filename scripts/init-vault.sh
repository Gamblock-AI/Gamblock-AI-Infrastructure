#!/bin/bash
# Generate strong application secrets and immediately encrypt the complete
# production vault. Missing third-party credentials remain empty deploy gates.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VAULT_FILE="$PROJECT_DIR/group_vars/all/vault.yml"
VAULT_PASSWORD_FILE="$PROJECT_DIR/.vault_pass"

command -v ansible-vault >/dev/null 2>&1 || { echo "ansible-vault is required"; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "openssl is required"; exit 1; }
[ -s "$VAULT_PASSWORD_FILE" ] || { echo ".vault_pass must exist and be non-empty"; exit 1; }

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

{
  echo "---"
  printf 'vault_vps_password: %s\n' "$(yaml_quote "$GAMBLOCK_VPS_PASSWORD")"
  printf 'vault_github_registry_pat: %s\n' "$(yaml_quote "${GAMBLOCK_GHCR_PAT:-}")"
  printf 'vault_postgres_password: %s\n' "$(yaml_quote "$(openssl rand -hex 32)")"
  echo "vault_gamblock_backend:"
  printf '  jwt_access_secret: %s\n' "$(yaml_quote "$(openssl rand -hex 32)")"
  printf '  journal_encryption_key: %s\n' "$(yaml_quote "$(openssl rand -hex 32)")"
  printf '  smtp_host: %s\n' "$(yaml_quote "${GAMBLOCK_SMTP_HOST:-}")"
  printf '  smtp_port: %s\n' "${GAMBLOCK_SMTP_PORT:-0}"
  printf '  smtp_username: %s\n' "$(yaml_quote "${GAMBLOCK_SMTP_USERNAME:-}")"
  printf '  smtp_password: %s\n' "$(yaml_quote "${GAMBLOCK_SMTP_PASSWORD:-}")"
  printf '  smtp_from: %s\n' "$(yaml_quote "${GAMBLOCK_SMTP_FROM:-}")"
  echo '  whatsapp_api_key: ""'
  echo '  whatsapp_phone_id: ""'
  echo '  whatsapp_base_url: "https://graph.facebook.com/v18.0"'
  printf 'vault_cloudflare_api_token: %s\n' "$(yaml_quote "${GAMBLOCK_CLOUDFLARE_API_TOKEN:-}")"
} > "$TEMP_FILE"

ansible-vault encrypt \
  --vault-password-file "$VAULT_PASSWORD_FILE" \
  --encrypt-vault-id default \
  --output "$VAULT_FILE" "$TEMP_FILE"
chmod 600 "$VAULT_FILE"
echo "Encrypted vault initialized: group_vars/all/vault.yml"
echo "Use 'make vault-edit' to add GHCR, SMTP, and Cloudflare credentials."
