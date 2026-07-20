#!/bin/bash
# Wait until the public website and API are both healthy through Cloudflare.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
source "$SCRIPT_DIR/config.sh"

command -v curl >/dev/null 2>&1 || {
  echo -e "${RED}curl not found${NC}"
  exit 1
}

PRIMARY_DOMAIN=$(get_var "primary_domain")
API_DOMAIN=$(get_var "api_domain")
MAX_ATTEMPTS=${PRODUCTION_VERIFY_ATTEMPTS:-60}
WAIT_SECONDS=${PRODUCTION_VERIFY_INTERVAL_SECONDS:-5}
WEBSITE_URL="https://$PRIMARY_DOMAIN/"
API_URL="https://$API_DOMAIN/healthz"

is_ready() {
  curl --silent --fail --location --max-time 15 --output /dev/null "$1" 2>/dev/null
}

echo -e "${BLUE}=== Verify production endpoints ===${NC}"
for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
  website_ready=false
  api_ready=false
  is_ready "$WEBSITE_URL" && website_ready=true
  is_ready "$API_URL" && api_ready=true

  if [ "$website_ready" = true ] && [ "$api_ready" = true ]; then
    echo -e "${GREEN}Website ready:${NC} $WEBSITE_URL"
    echo -e "${GREEN}API ready:${NC} $API_URL"
    exit 0
  fi

  echo "Waiting for TLS/routes (attempt $attempt/$MAX_ATTEMPTS; website=$website_ready api=$api_ready)"
  if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
    sleep "$WAIT_SECONDS"
  fi
done

echo -e "${RED}Production did not become healthy within the verification window.${NC}" >&2
echo "Website: $WEBSITE_URL" >&2
echo "API: $API_URL" >&2
exit 1
