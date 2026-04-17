# Quick Start — Spedis Security Gate

Got 10 minutes? This gets the gate running on one project.

## Step 1 — Publish the central repo (one time, globally)

```bash
cd ~/work
# Extract the zip you received
unzip spedis-security-gate.zip
cd spedis-security-gate

# Initialize git and push to GitHub
git init
git add -A
git commit -m "feat: initial security gate v1.0.0"
gh repo create tropi/spedis-security-gate --public --source=. --push
git tag v1.0.0
git push --tags
```

**If your GitHub username is not `tropi`**, edit these files before pushing:
- `README.md` (all refs to `tropi/spedis-security-gate`)
- `bootstrap.sh` (the `SECGATE_REPO` default)
- `.github/workflows/reusable.yml` (the `raw.githubusercontent.com` URLs)

Or override via env var when running bootstrap:
```bash
SECGATE_REPO=yourusername/spedis-security-gate curl -sSL .../bootstrap.sh | bash
```

## Step 2 — Install in a project

```bash
cd ~/work/axisten  # or indesy, adscory, crezco, etc.
curl -sSL https://raw.githubusercontent.com/tropi/spedis-security-gate/main/bootstrap.sh | bash
```

Output:
```
→ Detected package manager: pnpm
✓ Installed .github/workflows/security-gate.yml
✓ Installed .gitleaks.toml
✓ Installed .git/hooks/pre-commit
✓ Appended security rules to CLAUDE.md

NOTICE: gitleaks not found in PATH.
Install it for local pre-commit scanning:
  macOS: brew install gitleaks

Security Gate installed.
```

Commit the new files:

```bash
git add .github/ .gitleaks.toml CLAUDE.md
git commit -m "chore: add Spedis Security Gate"
git push
```

## Step 3 — Install gitleaks locally (recommended)

So the pre-commit hook works:

**macOS:**
```bash
brew install gitleaks
```

**Linux:**
```bash
curl -sSL https://github.com/gitleaks/gitleaks/releases/latest/download/gitleaks_linux_x64.tar.gz | \
  tar -xz -C /tmp
sudo mv /tmp/gitleaks /usr/local/bin/
```

**Verify:**
```bash
gitleaks version
# Expected: v8.x.x
```

## Step 4 — Enable branch protection on GitHub

Repo → Settings → Branches → Add rule:

- **Branch name pattern:** `main`
- ✅ Require a pull request before merging
- ✅ Require status checks to pass before merging
- **Required status check:** `gate / summary`
- ✅ Do not allow bypassing (even for admins)

## Step 5 — Test the gate

Trigger a PR with intentionally bad code to verify it blocks:

```bash
git checkout -b test/security-gate
cat > src/test-bad.ts <<'EOF'
// This file intentionally fails the security gate
const JWT_SECRET = process.env.JWT_SECRET ?? "dev-secret-123";

async function badAuth() {
  try {
    await verify(token);
  } catch { }  // empty catch
}

const API_KEY = "sk-ant-abc123def456ghi789";  // hardcoded key
EOF

git add src/test-bad.ts
git commit -m "test: intentionally bad code"
# Pre-commit hook should FAIL here. If it doesn't:
#   - Check gitleaks is installed
#   - Check .git/hooks/pre-commit is executable

# If the hook is disabled or you use --no-verify:
git push origin test/security-gate

# Open PR on GitHub. The gate should fail within 2-3 minutes.
# Merge should be blocked.

# Clean up:
git checkout main
git branch -D test/security-gate
git push origin --delete test/security-gate
```

## Step 6 — Coolify integration

See [`docs/INTEGRATION_COOLIFY.md`](./docs/INTEGRATION_COOLIFY.md) for three patterns:

- **Pattern A (recommended):** Branch protection + Coolify watches `main`
- **Pattern B:** Coolify webhook triggered only after gate succeeds
- **Pattern C:** Release branch for staging/prod separation

## Roll out order

Deploy to projects in this order, highest risk first:

1. **Adscory** — most exposed (processes external ad data, multi-tenant, financial calculations)
2. **Axisten** — handles OAuth tokens and talks to Zoho CRMs of multiple tenants
3. **Indesy** — tenant isolation critical, financial/legal documents
4. **crezco** — PII and financial, but invite-only and smaller blast radius
5. **Client Zoho implementations** — lowest risk since Zoho controls most auth/storage

For each, after install:

1. First PR probably fails the gate (existing tech debt).
2. Review findings honestly: fix the real bugs, allowlist documented false positives with an expiry.
3. Merge once clean. From that point forward, every PR is gate-checked.

## Troubleshooting

**"Semgrep container not found"** — the reusable workflow uses `returntocorp/semgrep` image. Make sure GitHub Actions has internet access (default yes).

**"Gate runs forever"** — check Actions → job logs. If a custom check is stuck (e.g., bash script with infinite loop), kill the run and open an issue in `spedis-security-gate`.

**"Too many false positives on first run"** — normal. Use the three-strike rule:
- 1st strike: real bug → fix
- 2nd strike: false positive you can fix inline with `// nosemgrep: rule-id`
- 3rd strike: systemic false positive → add to `.security/allowlist.txt` with expiry

**"Gate is too slow"** — typical run is 2-3 min. If slower: check if `pnpm install` is cached properly. The reusable workflow uses `cache: pnpm`.

**"I need to skip the gate for a legitimate reason"** — see [`docs/INTEGRATION_COOLIFY.md`](./docs/INTEGRATION_COOLIFY.md) → "Emergency hotfix path".

## Further reading

- [`README.md`](./README.md) — full documentation
- [`docs/INTEGRATION_COOLIFY.md`](./docs/INTEGRATION_COOLIFY.md) — Coolify integration
- [`docs/EXTENDING.md`](./docs/EXTENDING.md) — add project-specific rules
- [`docs/PROJECT_RULES.md`](./docs/PROJECT_RULES.md) — pre-built rules for Axisten/Indesy/Adscory/crezco
