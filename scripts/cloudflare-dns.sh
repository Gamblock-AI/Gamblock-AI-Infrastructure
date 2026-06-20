#!/bin/bash
# Create/update Cloudflare DNS A records for the Gamblock-AI subdomains.
# Resolves the zone + VPS IP from group_vars; uses the Cloudflare API token from
# the encrypted vault. Run locally from your dev machine.
#
# Usage:
#   ./scripts/cloudflare-dns.sh            # apply
#   ./scripts/cloudflare-dns.sh --dry-run  # show what would be set
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

echo -e "${BLUE}=== Update Cloudflare DNS ===${NC}"

command -v curl >/dev/null 2>&1 || { echo -e "${RED}curl not found${NC}"; exit 1; }

ZONE_NAME=$(get_var "cloudflare_zone_name")
VPS_IP=$(get_vps_ip)
API_TOKEN=$(get_vault_var "vault_cloudflare_api_token")

if [ -z "$API_TOKEN" ] || [ "$API_TOKEN" = "REPLACE_WITH_CLOUDFLARE_API_TOKEN_DNS_EDIT" ]; then
  echo -e "${RED}Cloudflare API token not set in vault (vault_cloudflare_api_token)${NC}"
  exit 1
fi

echo -e "${GREEN}Zone:${NC} $ZONE_NAME"
echo -e "${GREEN}VPS IP:${NC} $VPS_IP"
echo ""

# Resolve the zone ID.
ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$ZONE_NAME" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result'][0]['id'] if d.get('result') else '')" 2>/dev/null || true)

if [ -z "$ZONE_ID" ]; then
  echo -e "${RED}Zone '$ZONE_NAME' not found with this token. Check the API token scope.${NC}"
  exit 1
fi
echo -e "${GREEN}Zone ID:${NC} $ZONE_ID"
echo ""

# Read records list from vars.yml (name/type/proxied).
RECORDS=$(python3 - "$VARS_FILE" << 'PY'
import yaml, sys
v = yaml.safe_load(open(sys.argv[1]))
for r in v.get("cloudflare_records", []):
    print(f"{r['name']}|{r['type']}|{r.get('proxied', True)}")
PY
)

while IFS='|' read -r name rtype proxied; do
  [ -z "$name" ] && continue
  fqdn="$name.$ZONE_NAME"
  echo -e "${BLUE}-- $fqdn ($rtype, proxied=$proxied) --${NC}"

  # Check for an existing record of the same name+type.
  EXISTING=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$fqdn&type=$rtype" \
    -H "Authorization: Bearer $API_TOKEN" \
    -H "Content-Type: application/json")
  REC_ID=$(echo "$EXISTING" | python3 -c "import sys,json; d=json.load(sys.stdin); r=d.get('result') or []; print(r[0]['id'] if r else '')" 2>/dev/null || true)

  if [ "$DRY_RUN" = true ]; then
    echo -e "  ${YELLOW}[dry-run]${NC} $fqdn -> $VPS_IP (existing=${REC_ID:-none})"
    continue
  fi

  PAYLOAD="{\"type\":\"$rtype\",\"name\":\"$fqdn\",\"content\":\"$VPS_IP\",\"proxied\":$proxied,\"ttl\":1}"
  if [ -n "$REC_ID" ]; then
    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$REC_ID" \
      -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json" \
      --data "$PAYLOAD" | python3 -c "import sys,json; d=json.load(sys.stdin); print('  updated' if d.get('success') else '  ERR: '+str(d.get('errors')))"
  else
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
      -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json" \
      --data "$PAYLOAD" | python3 -c "import sys,json; d=json.load(sys.stdin); print('  created' if d.get('success') else '  ERR: '+str(d.get('errors')))"
  fi
done <<< "$RECORDS"

echo ""
echo -e "${GREEN}Done.${NC}"
