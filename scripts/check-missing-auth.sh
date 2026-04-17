#!/usr/bin/env bash
# check-missing-auth.sh
# Looks for Hono/Express mutation endpoints (POST/PUT/PATCH/DELETE)
# that do not have an auth middleware in the chain.

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

VIOLATIONS=0

SCAN_DIRS=("apps/api/src/routes" "src/routes" "packages/api/src/routes")

AUTH_PATTERNS="authMiddleware|requireAuth|isAuthenticated|authenticate|verifyToken|requireUser|requireSession"
PUBLIC_MARKER="@public-endpoint"

echo "-> Scanning for mutation endpoints without auth middleware..."

for dir in "${SCAN_DIRS[@]}"; do
  [ ! -d "$dir" ] && continue

  while IFS= read -r file; do
    # Check if the file has global auth: app.use(authMiddleware) or similar
    has_global_auth=false
    if grep -qE "app\.use\(.*(${AUTH_PATTERNS})" "$file"; then
      has_global_auth=true
    fi

    # Find mutation endpoint lines
    while IFS=: read -r linenum line; do
      # Skip comments
      if echo "$line" | grep -qE "^\s*//"; then
        continue
      fi

      # Check for @public-endpoint marker in this line or prev line
      is_public=false
      if echo "$line" | grep -qF "$PUBLIC_MARKER"; then
        is_public=true
      fi
      if [ "$linenum" -gt 1 ]; then
        prev=$(sed -n "$((linenum - 1))p" "$file" 2>/dev/null || echo "")
        if echo "$prev" | grep -qF "$PUBLIC_MARKER"; then
          is_public=true
        fi
      fi

      # Check for common public paths
      if echo "$line" | grep -qE "(auth/login|auth/register|auth/forgot|webhooks/|/health|/ping)"; then
        is_public=true
      fi

      $is_public && continue
      $has_global_auth && continue

      # Check if line itself has auth middleware
      if echo "$line" | grep -qE "$AUTH_PATTERNS"; then
        continue
      fi

      VIOLATIONS=$((VIOLATIONS + 1))
      echo -e "${YELLOW}WARN ${file}:${linenum}${NC}"
      echo "   ${line}"
      echo "   -> Mutation endpoint without visible auth middleware."
      echo "   -> Add middleware, mark with // @public-endpoint, or use app.use() globally."
      echo ""
    done < <(grep -nE "(app|router)\.(post|put|patch|delete)\s*\(" "$file" 2>/dev/null || true)
  done < <(find "$dir" -type f \( -name "*.ts" -o -name "*.js" \) 2>/dev/null)
done

echo ""
if [ $VIOLATIONS -eq 0 ]; then
  echo -e "${GREEN}OK All mutation endpoints have auth middleware or are marked public.${NC}"
  exit 0
else
  echo -e "${YELLOW}WARN Found $VIOLATIONS potentially unauthenticated mutation endpoint(s).${NC}"
  echo "Review each. If intentionally public, add a comment before the line:"
  echo "    // @public-endpoint - reason"
  # Warning only, not fail
  exit 0
fi
