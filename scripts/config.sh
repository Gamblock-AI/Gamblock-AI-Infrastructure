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
  python3 -c '
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    value = yaml.safe_load(handle).get(sys.argv[2], "")
print("" if value is None else value)
' "$VARS_FILE" "$key"
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
  _vault_content 2>/dev/null | python3 -c '
import sys
import yaml

value = yaml.safe_load(sys.stdin).get(sys.argv[1], "")
print("" if value is None else value)
' "$key"
}

# Read a multi-line secret from vault (e.g. a private key). Prints everything
# after the key line until a line that looks like a new top-level key.
get_vault_multiline() {
  local key=$1
  get_vault_var "$key"
}

# Get VPS IP from inventory
get_vps_ip() {
  awk '!/^#/ && !/^\[/ && NF { print $1; exit }' "$PROJECT_DIR/inventory/hosts.ini"
}

# Load a local GitHub token from .env if present (overrides vault for auth).
load_local_github_token() {
  [ -f "$PROJECT_DIR/.env" ] || return 0
  [ -z "${GH_TOKEN:-}" ] || return 0
  local line token=""
  while IFS= read -r line; do
    case "$line" in
      GH_TOKEN=*|GITHUB_TOKEN=*)
        token=${line#*=}
        token=${token#\"}
        token=${token%\"}
        token=${token#\'}
        token=${token%\'}
        break
        ;;
    esac
  done < "$PROJECT_DIR/.env"
  [ -z "$token" ] || export GH_TOKEN="$token"
  return 0
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
