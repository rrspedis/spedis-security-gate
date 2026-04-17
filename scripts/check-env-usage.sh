#!/usr/bin/env bash
# Spedis Security Gate — check-env-usage v1.0.2
#
# Categorizes env var fallbacks into three tiers:
#   ERROR:   SECRET-class vars (JWT_SECRET, API_KEY, etc) with fallback
#   WARNING: INFRA URL vars (REDIS_URL, DATABASE_URL, etc) with fallback
#   IGNORE:  benign config (branding URLs, emails, domains, etc)
#
# Exit 0 if no ERRORs. Exit 1 if ERRORs found.

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

ERRORS=0
WARNINGS=0

SCAN_DIRS=("src" "apps" "packages" "lib")

# Vars classified as SECRETS (block)
SECRET_PATTERN='(SECRET|PASSWORD|PASSWD|TOKEN|APIKEY|API_KEY|PRIVATE_KEY|ENCRYPTION_KEY|CREDENTIAL|HMAC|JWT|STRIPE|ANTHROPIC|OPENAI|META_ACCESS|FACEBOOK_ACCESS|GOOGLE_CLIENT|GOOGLE_SECRET|AWS_SECRET|AWS_ACCESS|ZOHO_CLIENT|ZOHO_REFRESH)'

# Vars classified as INFRA URLs (warn, not block)
INFRA_PATTERN='^(REDIS_URL|DATABASE_URL|POSTGRES_URL|POSTGRESQL_URL|MONGODB_URL|MONGO_URL|AMQP_URL|RABBITMQ_URL|KAFKA_URL|BROKER_URL|QUEUE_URL|ELASTICSEARCH_URL|ELASTIC_URL)$'

echo -e "${BLUE}-> Scanning for hardcoded env var fallbacks (categorized)...${NC}"
echo ""

for dir in "${SCAN_DIRS[@]}"; do
  [ ! -d "$dir" ] && continue

  # Find all process.env.X ?? "..." or process.env.X || "..." patterns
  while IFS= read -r match; do
    file=$(echo "$match" | cut -d: -f1)
    linenum=$(echo "$match" | cut -d: -f2)
    line=$(echo "$match" | cut -d: -f3- | sed 's/^[[:space:]]*//')

    # Skip tests and build artifacts
    case "$file" in
      *.test.ts|*.test.js|*.spec.ts|*.spec.js) continue ;;
      *node_modules*|*dist/*|*build/*|*.next/*) continue ;;
    esac

    # Extract variable name
    varname=$(echo "$line" | grep -oE 'process\.env\.[A-Z_][A-Z0-9_]*' | head -1 | cut -d. -f3)
    [ -z "$varname" ] && continue

    # Skip if fallback is empty string, known default, or boolean/number
    if echo "$line" | grep -qE '(\|\||\?\?)\s*(""|'"''"'|false|true|null|undefined|[0-9]+|"(development|production|test|localhost|127\.0\.0\.1|3000|3001|8080|5000)"|'"'"'(development|production|test|localhost|127\.0\.0\.1|3000|3001|8080|5000)'"'"')'; then
      continue
    fi

    # Categorize
    if echo "$varname" | grep -qE "$SECRET_PATTERN"; then
      ERRORS=$((ERRORS + 1))
      echo -e "${RED}ERROR${NC} $file:$linenum"
      echo "  var: $varname (SECRET class)"
      echo "  $line"
      echo ""
    elif echo "$varname" | grep -qE "$INFRA_PATTERN"; then
      WARNINGS=$((WARNINGS + 1))
      echo -e "${YELLOW}WARN${NC}  $file:$linenum"
      echo "  var: $varname (INFRA URL class)"
      echo "  $line"
      echo ""
    fi
    # else: benign, ignore
  done < <(grep -rnE 'process\.env\.[A-Z_][A-Z0-9_]*[[:space:]]*(\|\|[[:space:]]*|\?\?[[:space:]]*)["'"'"'][^"'"'"']+["'"'"']' "$dir" 2>/dev/null || true)
done

echo "----------------------------------------"
echo -e "Summary: ${RED}$ERRORS error(s)${NC}, ${YELLOW}$WARNINGS warning(s)${NC}"
echo ""

if [ "$ERRORS" -gt 0 ]; then
  echo -e "${RED}Why ERRORs matter:${NC}"
  echo "  A fallback on a secret (e.g., JWT_SECRET ?? 'dev-secret') means the app"
  echo "  silently uses the fallback if the env var is missing. In production"
  echo "  this is a critical vulnerability that can enable forged tokens,"
  echo "  signature bypass, and session hijacking."
  echo ""
  echo "  Fix (fail-closed):"
  echo "    const jwtSecret = process.env.JWT_SECRET;"
  echo "    if (!jwtSecret) throw new Error('JWT_SECRET required');"
  echo ""
  exit 1
fi

if [ "$WARNINGS" -gt 0 ]; then
  echo -e "${YELLOW}Why WARNINGS matter (non-blocking):${NC}"
  echo "  Infrastructure URLs (REDIS_URL, DATABASE_URL) with localhost fallback"
  echo "  silently work in dev. In production if the env var is missing, the"
  echo "  app tries localhost and the dependent service (rate limiting, queues,"
  echo "  session store) is broken until someone notices."
  echo ""
  echo "  Fix (fail-closed in prod):"
  echo "    const url = process.env.NODE_ENV === 'production'"
  echo "      ? (process.env.REDIS_URL ?? throwIt('REDIS_URL required'))"
  echo "      : (process.env.REDIS_URL ?? 'redis://localhost:6379');"
  echo ""
fi

echo -e "${GREEN}No ERROR-level env var fallbacks found.${NC}"
exit 0
