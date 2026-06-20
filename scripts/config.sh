#!/bin/bash
# Shared configuration loader for local scripts. Reads from group_vars + inventory
# + vault (decrypted at runtime via ansible-vault). Source this file:
#   source "$(dirname "$0")/config.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
NC='\033[0m'

VAULT_FILE="$PROJECT_DIR/group_vars/all/vault.yml"
VARS_FILE="$PROJECT_DIR/group_vars/all/vars.yml"

# Read a simple scalar from vars.yml
get_var() {
  local key=$1
  grep "^${key}:" "$VARS_FILE" 2>/dev/null | head -1 | sed -E "s/^${key}:[[:space:]]*//" | tr -d '"' | tr -d "'"
}

# Read a secret from vault.yml. Tries the encrypted form first (ansible-vault
# view) and falls back to reading the plaintext file directly — so scripts work
# during initial setup before the vault is encrypted.
_vault_content() {
  if ansible-vault view "$VAULT_FILE" >/dev/null 2>&1; then
    ansible-vault view "$VAULT_FILE"
  else
    cat "$VAULT_FILE"
  fi
}

# Read a secret from the encrypted vault.yml (decrypts on the fly).
get_vault_var() {
  local key=$1
  _vault_content 2>/dev/null | grep "^${key}:" | head -1 | sed -E "s/^${key}:[[:space:]]*//" | tr -d '"' | tr -d "'"
}

# Read a multi-line secret from vault (e.g. a private key). Prints everything
# after the key line until a line that looks like a new top-level key.
get_vault_multiline() {
  local key=$1
  _vault_content 2>/dev/null | awk -v k="$key" '
    $0 ~ "^"k":" { found=1; sub("^"k":[[:space:]]*", ""); if ($0 == "|") next; print; next }
    found && /^[a-z_]+:/ { exit }
    found { print }
  '
}

# Get VPS IP from inventory
get_vps_ip() {
  grep -v "^#" "$PROJECT_DIR/inventory/hosts.ini" | grep -v "^\[" | grep -v "^$" | head -1 | awk '{print $1}'
}

# Load a local GitHub token from .env if present (overrides vault for auth).
load_local_github_token() {
  [ -f "$PROJECT_DIR/.env" ] || return 0
  [ -z "${GH_TOKEN:-}" ] || return 0
  local token
  token=$(grep -E '^(GH_TOKEN|GITHUB_TOKEN)=' "$PROJECT_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
  if [ -n "$token" ]; then
    export GH_TOKEN="$token"
  fi
}

# Common requirement checks
check_requirements() {
  command -v ansible-vault >/dev/null 2>&1 || { echo -e "${RED}ansible-vault not found${NC}"; return 1; }
  command -v gh >/dev/null 2>&1 || { echo -e "${RED}gh CLI not found${NC}"; return 1; }
  return 0
}

check_gh_auth() {
  gh auth status >/dev/null 2>&1 || { echo -e "${RED}gh not authenticated. Run: gh auth login${NC}"; return 1; }
  return 0
}
