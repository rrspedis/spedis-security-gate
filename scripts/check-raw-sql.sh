#!/usr/bin/env bash
# check-raw-sql.sh
# Detects raw SQL constructed with string concatenation or template literals
# containing interpolated values. Potential SQL injection.

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

VIOLATIONS=0

SCAN_DIRS=("src" "apps" "packages")

echo "-> Scanning for raw SQL with potentially unparameterized input..."

for dir in "${SCAN_DIRS[@]}"; do
  [ ! -d "$dir" ] && continue

  # Patrón: sql`SELECT ... ${VAR} ...` donde VAR no es parametrizado
  # Drizzle sql tag parametriza ${}, pero si se usa con db.execute() con string concat no
  #
  # Patrón peligroso 1: db.execute("SELECT ... " + variable)
  # Patrón peligroso 2: client.query("INSERT ... " + variable)
  # Patrón peligroso 3: client.raw(...) con input
  #
  # Nota: Drizzle sql tagged template con ${} ES seguro, pero grep no distingue.
  # El patrón peligroso real es concatenación con +.

  while IFS= read -r match; do
    file=$(echo "$match" | cut -d: -f1)
    linenum=$(echo "$match" | cut -d: -f2)
    line=$(echo "$match" | cut -d: -f3-)

    # Skip test/spec files
    if echo "$file" | grep -qE "(test|spec)\.(ts|js)$"; then
      continue
    fi

    # Skip migration files (raw SQL is expected there)
    if echo "$file" | grep -qE "migrations/"; then
      continue
    fi

    # Skip node_modules/dist
    if echo "$file" | grep -qE "(node_modules|dist/|build/)"; then
      continue
    fi

    VIOLATIONS=$((VIOLATIONS + 1))
    echo -e "${RED}FAIL ${file}:${linenum}${NC}"
    echo "   ${line}"
    echo ""
  done < <(grep -rnE '(execute|query|raw)\s*\(\s*["' "'" ']+[^"'"'"']*(SELECT|INSERT|UPDATE|DELETE)[^"'"'"']*["' "'" ']+\s*\+' "$dir" 2>/dev/null || true)
done

echo ""
if [ $VIOLATIONS -eq 0 ]; then
  echo -e "${GREEN}OK No raw SQL with string concatenation detected.${NC}"
  exit 0
else
  echo -e "${RED}FAIL Found $VIOLATIONS raw SQL with string concatenation.${NC}"
  echo ""
  echo "Why this matters:"
  echo "  'SELECT * FROM users WHERE id = ' + userId"
  echo "  allows SQL injection if userId contains ', OR 1=1 --"
  echo ""
  echo "Fix:"
  echo "  Use Drizzle sql-tagged templates: sql\`SELECT * FROM users WHERE id = \${userId}\`"
  echo "  Or parameterized queries: client.query('SELECT * FROM users WHERE id = \$1', [userId])"
  exit 1
fi
