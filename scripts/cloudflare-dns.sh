#!/bin/bash
# Create/update the apex, www, and api records and require Full (strict) SSL.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
source "$SCRIPT_DIR/config.sh"

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

command -v curl >/dev/null 2>&1 || { echo -e "${RED}curl not found${NC}"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo -e "${RED}python3 not found${NC}"; exit 1; }

ZONE_NAME=$(get_var "cloudflare_zone_name")
VPS_IP=$(get_vps_ip)

RECORDS=$(python3 - "$VARS_FILE" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    values = yaml.safe_load(handle)
for record in values.get("cloudflare_records", []):
    print(f"{record['name']}|{record['type']}|{str(record.get('proxied', True)).lower()}")
PY
)

echo -e "${BLUE}=== Update Cloudflare DNS ===${NC}"
echo -e "${GREEN}Zone:${NC} $ZONE_NAME"
echo -e "${GREEN}VPS IP:${NC} $VPS_IP"

if [ "$DRY_RUN" = true ]; then
  while IFS='|' read -r name rtype proxied; do
    [ -z "$name" ] && continue
    [ "$name" = "@" ] && fqdn="$ZONE_NAME" || fqdn="$name.$ZONE_NAME"
    echo -e "  ${YELLOW}[dry-run]${NC} $fqdn $rtype -> $VPS_IP (proxied=$proxied)"
  done <<< "$RECORDS"
  echo -e "  ${YELLOW}[dry-run]${NC} SSL mode -> strict"
  exit 0
fi

API_TOKEN=$(get_vault_var "vault_cloudflare_api_token")
[ -n "$API_TOKEN" ] || {
  echo -e "${RED}vault_cloudflare_api_token is empty${NC}"
  exit 1
}

api_request() {
  local method=$1 url=$2 data=${3:-}
  if [ -n "$data" ]; then
    curl --fail-with-body --silent --show-error -X "$method" "$url" \
      -H "Authorization: Bearer $API_TOKEN" \
      -H "Content-Type: application/json" \
      --data "$data"
  else
    curl --fail-with-body --silent --show-error -X "$method" "$url" \
      -H "Authorization: Bearer $API_TOKEN" \
      -H "Content-Type: application/json"
  fi
}

require_success() {
  python3 -c 'import json,sys; data=json.load(sys.stdin); sys.exit(0 if data.get("success") else 1)'
}

ZONE_RESPONSE=$(api_request GET "https://api.cloudflare.com/client/v4/zones?name=$ZONE_NAME")
ZONE_ID=$(printf '%s' "$ZONE_RESPONSE" | python3 -c 'import json,sys; r=json.load(sys.stdin).get("result", []); print(r[0]["id"] if r else "")')
[ -n "$ZONE_ID" ] || { echo -e "${RED}Zone not found or token lacks Zone Read${NC}"; exit 1; }

while IFS='|' read -r name rtype proxied; do
  [ -z "$name" ] && continue
  [ "$name" = "@" ] && fqdn="$ZONE_NAME" || fqdn="$name.$ZONE_NAME"
  echo -e "${BLUE}-- $fqdn --${NC}"

  EXISTING=$(api_request GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$fqdn")
  while IFS='|' read -r record_id record_type; do
    [ -z "$record_id" ] && continue
    if [ "$record_type" != "$rtype" ]; then
      api_request DELETE "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$record_id" | require_success
      echo "  removed conflicting $record_type record"
    fi
  done < <(printf '%s' "$EXISTING" | python3 -c 'import json,sys; [print("{}|{}".format(r["id"], r["type"])) for r in json.load(sys.stdin).get("result", [])]')

  RECORD_ID=$(printf '%s' "$EXISTING" | python3 -c 'import json,sys; expected=sys.argv[1]; rows=json.load(sys.stdin).get("result", []); print(next((r["id"] for r in rows if r["type"] == expected), ""))' "$rtype")
  PAYLOAD=$(python3 -c 'import json,sys; print(json.dumps({"type":sys.argv[1],"name":sys.argv[2],"content":sys.argv[3],"proxied":sys.argv[4] == "true","ttl":1}))' "$rtype" "$fqdn" "$VPS_IP" "$proxied")

  if [ -n "$RECORD_ID" ]; then
    api_request PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" "$PAYLOAD" | require_success
    echo "  updated"
  else
    api_request POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" "$PAYLOAD" | require_success
    echo "  created"
  fi
done <<< "$RECORDS"

api_request PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/settings/ssl" '{"value":"strict"}' | require_success
echo -e "${GREEN}Cloudflare DNS updated; SSL mode is Full (strict).${NC}"
