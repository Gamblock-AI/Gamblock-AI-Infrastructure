#!/bin/bash
# Set GitHub repository secrets + variables for CI/CD deploy.
# Resolves values from group_vars (vars.yml + encrypted vault.yml) and pushes
# them via the gh CLI. Run locally from your dev machine.
#
# Usage:
#   ./scripts/github-secrets.sh            # all repos
#   ./scripts/github-secrets.sh --dry-run  # show what would be set, no changes
#   ./scripts/github-secrets.sh -y         # skip confirmation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

AUTO_CONFIRM=false
DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) AUTO_CONFIRM=true ;;
    --dry-run) DRY_RUN=true ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
  shift
done

echo -e "${BLUE}=== Update GitHub Secrets & Variables ===${NC}"

check_requirements || exit 1
[ "$DRY_RUN" = true ] || { check_gh_auth || exit 1; }
load_local_github_token

OWNER=$(get_var "github_owner")
VPS_IP=$(get_vps_ip)
CI_USER=$(get_var "ci_deploy_user")
REPOS=()
while IFS= read -r line; do
  REPOS+=("$line")
done < <(grep -E '^\s*-\s*"' "$VARS_FILE" | sed -E 's/.*"([^"]+)".*/\1/' | grep -iv '^\s*$')

# Secret values (from vault).
VPS_KEY=$(get_vault_multiline "vault_app_deployer_private_key")
GHCR_TOKEN=$(get_vault_var "vault_docker_password")

echo -e "${GREEN}Owner:${NC} $OWNER"
echo -e "${GREEN}VPS IP:${NC} $VPS_IP"
echo -e "${GREEN}CI user:${NC} $CI_USER"
echo -e "${GREEN}Repos:${NC} ${REPOS[*]}"
echo ""

if [ "$AUTO_CONFIRM" = false ] && [ "$DRY_RUN" = false ]; then
  read -rp "Proceed to set secrets/variables on these repos? [y/N] " confirm
  [ "$confirm" = "y" ] || { echo "Aborted."; exit 0; }
fi

set_secret() {
  local repo=$1 name=$2 value=$3
  if [ "$DRY_RUN" = true ]; then
    echo -e "  ${YELLOW}[dry-run]${NC} secret $name -> $OWNER/$repo"
    return
  fi
  printf '%s' "$value" | gh secret set "$name" --repo "$OWNER/$repo" --app actions
  echo -e "  ${GREEN}secret${NC} $name -> $OWNER/$repo"
}

set_variable() {
  local repo=$1 name=$2 value=$3
  if [ "$DRY_RUN" = true ]; then
    echo -e "  ${YELLOW}[dry-run]${NC} var $name -> $OWNER/$repo"
    return
  fi
  gh variable set "$name" --body "$value" --repo "$OWNER/$repo" || \
    gh variable create "$name" --body "$value" --repo "$OWNER/$repo"
  echo -e "  ${GREEN}var${NC} $name -> $OWNER/$repo"
}

PRIMARY_DOMAIN=$(get_var "primary_domain")
API_URL="https://api.$PRIMARY_DOMAIN"

for repo in "${REPOS[@]}"; do
  echo -e "${BLUE}-- $OWNER/$repo --${NC}"
  # Common deploy secrets for all repos that ship a Docker image.
  set_secret "$repo" "VPS_HOST" "$VPS_IP"
  set_secret "$repo" "VPS_USER" "$CI_USER"
  set_secret "$repo" "VPS_KEY" "$VPS_KEY"
  # GHCR pull token (used by update.sh on the VPS via docker-password.txt).
  set_secret "$repo" "DOCKER_TOKEN" "$GHCR_TOKEN"
done

# Website-specific build variable (NEXT_PUBLIC_API_URL is baked at build time).
set_variable "Gamblock-AI-Website" "NEXT_PUBLIC_API_URL" "$API_URL"

echo ""
echo -e "${GREEN}Done.${NC}"
