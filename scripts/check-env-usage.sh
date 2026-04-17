#!/usr/bin/env bash
# check-env-usage.sh
# Scans for hardcoded fallbacks on process.env, which are a critical
# anti-pattern (fail-open instead of fail-closed for secrets).
#
# Exit code 0 if clean, 1 if violations found.

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

VIOLATIONS=0
TOTAL=0

# Directorios de código a escanear
SCAN_DIRS=("src" "apps" "packages" "lib")

# Patrón peligroso: process.env.X con fallback hardcoded
DANGEROUS_PATTERNS=(
  # Fallback a string literal (que no sea vacío)
  'process\.env\.[A-Z_]+\s*\?\?\s*["'"'"'][^"'"'"']+["'"'"']'
  'process\.env\.[A-Z_]+\s*\|\|\s*["'"'"'][^"'"'"']+["'"'"']'
)

# Excepciones legítimas (valores que son OK como fallback)
ALLOWED_FALLBACKS=(
  '""'
  "''"
  '"development"'
  "'development'"
  '"production"'
  "'production'"
  '"test"'
  "'test'"
  'false'
  'true'
  '0'
  '"3000"'
  "'3000'"
  '"localhost"'
  "'localhost'"
)

echo "→ Scanning for hardcoded env var fallbacks..."

for dir in "${SCAN_DIRS[@]}"; do
  [ ! -d "$dir" ] && continue

  for pattern in "${DANGEROUS_PATTERNS[@]}"; do
    # grep ripgrep-style; usamos grep -rE para portabilidad
    while IFS= read -r line; do
      TOTAL=$((TOTAL + 1))

      # Skip si el fallback es uno permitido
      skip=false
      for allowed in "${ALLOWED_FALLBACKS[@]}"; do
        if echo "$line" | grep -qF "$allowed"; then
          skip=true
          break
        fi
      done

      if ! $skip; then
        # Skip si es test file
        if echo "$line" | grep -qE "(test|spec)\.(ts|js)"; then
          continue
        fi

        # Skip si está en node_modules/dist/build
        if echo "$line" | grep -qE "(node_modules|dist/|build/|\.next/)"; then
          continue
        fi

        VIOLATIONS=$((VIOLATIONS + 1))
        echo -e "${RED}✗ $line${NC}"
      fi
    done < <(grep -rEn "$pattern" "$dir" 2>/dev/null || true)
  done
done

echo ""
if [ $VIOLATIONS -eq 0 ]; then
  echo -e "${GREEN}✓ No hardcoded env var fallbacks detected.${NC}"
  exit 0
else
  echo -e "${RED}✗ Found $VIOLATIONS hardcoded env var fallback(s).${NC}"
  echo ""
  echo "Why this matters:"
  echo "  A fallback secret like \`process.env.JWT_SECRET ?? 'dev-secret'\`"
  echo "  means the app silently uses 'dev-secret' if the env var is missing."
  echo "  In production this is a critical vulnerability."
  echo ""
  echo "Fix:"
  echo "  const jwtSecret = process.env.JWT_SECRET;"
  echo "  if (!jwtSecret) throw new Error('JWT_SECRET is required');"
  echo ""
  exit 1
fi
