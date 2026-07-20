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
# shellcheck source=scripts/config.sh
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

load_local_github_token
check_requirements || exit 1
[ "$DRY_RUN" = true ] || { check_gh_auth || exit 1; }

OWNER=$(get_var "github_owner")
VPS_IP=$(get_vps_ip)
DEPLOY_REPOS=("Gamblock-AI-Backend" "Gamblock-AI-Website")
FLUTTER_REPO="Gamblock-AI-Apps"
VPS_PASSWORD=$(get_vault_var "vault_vps_password")
[ -n "$VPS_PASSWORD" ] || { echo -e "${RED}vault_vps_password is empty${NC}"; exit 1; }

echo -e "${GREEN}Owner:${NC} $OWNER"
echo -e "${GREEN}VPS IP:${NC} $VPS_IP"
echo -e "${GREEN}Deploy repos:${NC} ${DEPLOY_REPOS[*]}"
echo -e "${GREEN}Release repo:${NC} $FLUTTER_REPO"
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

for repo in "${DEPLOY_REPOS[@]}"; do
  echo -e "${BLUE}-- $OWNER/$repo --${NC}"
  set_secret "$repo" "VPS_PASSWORD" "$VPS_PASSWORD"
  set_variable "$repo" "VPS_HOST" "$VPS_IP"
  set_variable "$repo" "ENABLE_VPS_DEPLOY" "$(get_var github_enable_vps_deploy)"
done

set_variable "Gamblock-AI-Website" "NEXT_PUBLIC_API_URL" "https://$(get_var api_domain)"
set_variable "Gamblock-AI-Website" "NEXT_PUBLIC_GOOGLE_CLIENT_ID" "$(get_var google_web_client_id)"

echo -e "${BLUE}-- $OWNER/$FLUTTER_REPO --${NC}"
set_variable "$FLUTTER_REPO" "DEV_API_BASE_URL" "$(get_var flutter_development_api_url)"
set_variable "$FLUTTER_REPO" "PROD_API_BASE_URL" "$(get_var flutter_production_api_url)"
set_variable "$FLUTTER_REPO" "WEB_BASE_URL" "$(get_var flutter_web_base_url)"
set_variable "$FLUTTER_REPO" "GOOGLE_WEB_CLIENT_ID" "$(get_var google_web_client_id)"
set_variable "$FLUTTER_REPO" "GOOGLE_WINDOWS_CLIENT_ID" "$(get_var google_windows_client_id)"
set_variable "$FLUTTER_REPO" "ENABLE_PRODUCTION_RELEASE" "$(get_var github_enable_production_release)"

echo ""
echo -e "${GREEN}Done.${NC}"
