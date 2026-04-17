#!/usr/bin/env bash
# Spedis Security Gate - bootstrap installer
#
# Usage (from any project root):
#   curl -sSL https://raw.githubusercontent.com/tropi/spedis-security-gate/main/bootstrap.sh | bash
#
# Or specific version/branch:
#   curl -sSL .../bootstrap.sh | SECGATE_VERSION=v1.0.0 bash

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

SECGATE_REPO="${SECGATE_REPO:-tropi/spedis-security-gate}"
SECGATE_VERSION="${SECGATE_VERSION:-main}"
BASE_URL="https://raw.githubusercontent.com/${SECGATE_REPO}/${SECGATE_VERSION}"

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
cd "$REPO_ROOT"

echo -e "${BLUE}Spedis Security Gate - Installer${NC}"
echo -e "   Source: ${SECGATE_REPO}@${SECGATE_VERSION}"
echo -e "   Target: ${REPO_ROOT}"
echo ""

# ============================================================
# 1. Detect package manager
# ============================================================
PKG_MANAGER="pnpm"
if [ -f "package-lock.json" ]; then
  PKG_MANAGER="npm"
elif [ -f "yarn.lock" ]; then
  PKG_MANAGER="yarn"
elif [ -f "bun.lockb" ] || [ -f "bun.lock" ]; then
  PKG_MANAGER="bun"
elif [ -f "pnpm-lock.yaml" ]; then
  PKG_MANAGER="pnpm"
fi

echo -e "-> Detected package manager: ${PKG_MANAGER}"

# ============================================================
# 2. Install GitHub Actions workflow
# ============================================================
mkdir -p "$REPO_ROOT/.github/workflows"
WORKFLOW_PATH="$REPO_ROOT/.github/workflows/security-gate.yml"

cat > "$WORKFLOW_PATH" <<WORKFLOW
# Installed by spedis-security-gate bootstrap.sh
# Do not edit by hand — update via: curl ... bootstrap.sh | bash
#
# Full gate definition: https://github.com/${SECGATE_REPO}
name: Security Gate

on:
  pull_request:
    branches: [main, dev]
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read
  pull-requests: read
  security-events: write

jobs:
  gate:
    uses: ${SECGATE_REPO}/.github/workflows/reusable.yml@${SECGATE_VERSION}
    with:
      package-manager: ${PKG_MANAGER}
      severity: ERROR
    secrets: inherit
WORKFLOW

echo -e "${GREEN}OK Installed${NC} .github/workflows/security-gate.yml"

# ============================================================
# 3. Install gitleaks config
# ============================================================
GITLEAKS_CONFIG="$REPO_ROOT/.gitleaks.toml"
if curl -sSL -o "$GITLEAKS_CONFIG" "$BASE_URL/rules/gitleaks.toml"; then
  echo -e "${GREEN}OK Installed${NC} .gitleaks.toml"
else
  echo -e "${YELLOW}WARN${NC} Could not download gitleaks config"
fi

# ============================================================
# 4. Install pre-commit hook
# ============================================================
if [ -d "$REPO_ROOT/.git" ]; then
  HOOK_PATH="$REPO_ROOT/.git/hooks/pre-commit"

  if [ -f "$HOOK_PATH" ] && [ "${OVERWRITE_HOOK:-}" != "1" ]; then
    echo -e "${YELLOW}WARN${NC} Pre-commit hook already exists. Skipping (set OVERWRITE_HOOK=1 to force)."
  else
    if curl -sSL -o "$HOOK_PATH" "$BASE_URL/hooks/pre-commit"; then
      chmod +x "$HOOK_PATH"
      echo -e "${GREEN}OK Installed${NC} .git/hooks/pre-commit"
    else
      echo -e "${YELLOW}WARN${NC} Could not download pre-commit hook"
    fi
  fi
else
  echo -e "${YELLOW}WARN${NC} Not a git repo — skipping pre-commit hook"
fi

# ============================================================
# 5. Install / recommend local gitleaks
# ============================================================
if ! command -v gitleaks >/dev/null 2>&1; then
  echo ""
  echo -e "${YELLOW}NOTICE:${NC} gitleaks not found in PATH."
  echo "Install it for local pre-commit scanning:"
  echo "  macOS:   brew install gitleaks"
  echo "  Linux:   https://github.com/gitleaks/gitleaks/releases"
  echo "  Docker:  alias gitleaks='docker run -v \$PWD:/path ghcr.io/gitleaks/gitleaks:latest'"
fi

# ============================================================
# 6. Drop CLAUDE.md security rules (if doesn't exist or append section)
# ============================================================
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
SECURITY_MARKER="<!-- SPEDIS-SECURITY-GATE-RULES -->"

if [ ! -f "$CLAUDE_MD" ] || ! grep -qF "$SECURITY_MARKER" "$CLAUDE_MD"; then
  echo ""
  echo "-> Appending security rules to CLAUDE.md..."

  cat >> "$CLAUDE_MD" <<'CLAUDEMD'

<!-- SPEDIS-SECURITY-GATE-RULES -->
## Security rules (enforced by CI gate)

These rules are checked automatically on every PR. If your code fails any of
them, the build blocks merge. Write code that passes the gate on the first try.

**Tenant isolation (multi-tenant repos):**
- Every query on a tenant-scoped table MUST include `tenantId` in the WHERE.
- No exceptions. No "reports" that skip it. If truly needed, comment `// @cross-tenant-query - reason`.

**Secrets and config:**
- NEVER write `process.env.X ?? "fallback"` or `|| "fallback"` with a real value.
- Secrets must fail-closed: read at boot, throw if missing.
- NEVER hardcode any string that could be a secret (API keys, tokens, passwords).

**Error handling:**
- NEVER write empty `catch { }` or `catch (e) { }` blocks.
- NEVER return the input parameter from a catch block (e.g., failed decrypt returning ciphertext).
- Catches must log AND (rethrow OR explicitly handle with a comment).

**Input validation:**
- NEVER pass `req.body` / `ctx.req.json()` directly to `db.insert(...).values(...)`.
- Always validate with a Zod/valibot schema at the route boundary.
- NEVER join user input into `fs.*` paths without `path.resolve()` + base dir check.

**Crypto and auth:**
- Compare secrets with `crypto.timingSafeEqual(Buffer, Buffer)`, never `===` or `==`.
- Never use JWT with `algorithm: "none"` or `jwt.verify()` without `algorithms: [...]`.
- Use `crypto.randomBytes()` or `crypto.randomUUID()` for tokens. NOT `Math.random()`.
- bcrypt rounds >= 12.

**Injection:**
- NEVER use `eval()` or `new Function()`.
- NEVER build shell commands with template literals + user input. Use `execFile()` with array args.
- Raw SQL ONLY with parameterized placeholders or Drizzle sql-tagged templates.

**SSRF:**
- `fetch()` / `axios()` with user-controlled URL MUST go through a `validateUrl()` function that:
  - Requires `https:` protocol
  - Rejects private IPs (127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16)
  - Resolves hostname and re-validates the IP (prevents DNS rebinding)

**XSS:**
- `dangerouslySetInnerHTML` ONLY with `DOMPurify.sanitize()`.
- Never assign user input to `element.innerHTML`.

**CORS/Headers:**
- Never `origin: "*"` with `credentials: true`.
- Never `origin: true` + credentials (reflects any origin).
- Next.js projects must have `headers()` in `next.config.js` with CSP, HSTS, X-Frame-Options.

**Behavior expectation:**
If implementing a feature identifies a security consideration not mentioned in
the prompt, STOP and flag it. Do not silently add guards, do not assume. Surface
it to the user. Honesty > helpfulness for security concerns.

<!-- /SPEDIS-SECURITY-GATE-RULES -->
CLAUDEMD
  echo -e "${GREEN}OK${NC} Appended security rules to CLAUDE.md"
fi

# ============================================================
# 7. Summary
# ============================================================
echo ""
echo -e "${GREEN}Security Gate installed.${NC}"
echo ""
echo "Next steps:"
echo ""
echo "1. Commit these files:"
echo "     git add .github/workflows/security-gate.yml .gitleaks.toml CLAUDE.md"
echo "     git commit -m 'chore: add Spedis Security Gate'"
echo ""
echo "2. In GitHub repo settings, enable branch protection on 'main':"
echo "     Settings -> Branches -> Add rule -> Require status checks to pass"
echo "     Required check: 'gate / summary'"
echo ""
echo "3. (Optional) Install gitleaks locally for pre-commit scanning."
echo ""
echo "4. Coolify: in deployment settings, enable 'Wait for GitHub Actions' so"
echo "   deploys only trigger after the gate passes."
echo ""
echo "Test the gate manually:"
echo "     gh workflow run security-gate.yml"
echo ""
