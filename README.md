# Spedis Security Gate

Automated security check that runs before production deploys. Reusable across every Spedis project (Axisten, Indesy, Adscory, crezco, client projects).

**One rule:** if the gate fails, the build blocks the merge. Coolify only deploys what passed the gate.

---

## What it checks

| Category | Tools | Blocks on |
|----------|-------|-----------|
| Secrets in code | gitleaks | Hardcoded API keys, tokens, private keys, Zoho/Meta/Anthropic tokens |
| Static analysis | Semgrep (OWASP + custom) | 60+ rules specific to the Hono/Drizzle/Next.js stack |
| Dependency vulns | pnpm audit + OSV-Scanner | High/critical CVEs in dependencies |
| Tenant isolation | Custom Semgrep + grep | Queries without `tenantId` in multi-tenant repos |
| Secrets fallback | Custom grep | `process.env.X ?? "fallback"` patterns |
| Silent errors | Semgrep | Empty catches, catches returning input |
| Auth middleware | Custom grep | Mutation endpoints without auth |
| Raw SQL injection | Custom grep | Query strings with concatenation |

---

## Quick start

### 1. Create the central repo (once, globally)

```bash
cd ~/work
git clone <this-zip-extracted> spedis-security-gate
cd spedis-security-gate
gh repo create tropi/spedis-security-gate --public --source=. --push
```

Create a version tag so projects can pin to a stable version:

```bash
git tag v1.0.0
git push --tags
```

### 2. Install in any project

From any project root:

```bash
curl -sSL https://raw.githubusercontent.com/tropi/spedis-security-gate/main/bootstrap.sh | bash
```

Or pin to a version:

```bash
curl -sSL https://raw.githubusercontent.com/tropi/spedis-security-gate/v1.0.0/bootstrap.sh | \
  SECGATE_VERSION=v1.0.0 bash
```

The bootstrap installs:
- `.github/workflows/security-gate.yml` — GitHub Actions workflow
- `.gitleaks.toml` — gitleaks config for local scanning
- `.git/hooks/pre-commit` — fast local check before each commit
- Appends a `## Security rules` section to `CLAUDE.md`

### 3. Enable branch protection (one-time per repo)

In GitHub: **Settings → Branches → Add rule** for `main`:

- ✅ Require status checks to pass before merging
- ✅ Required check: `gate / summary`
- ✅ Require branches to be up to date before merging

### 4. Configure Coolify to wait for the gate

In Coolify, deployment source:
- Set source branch to `main`
- Enable "Deploy only after checks pass" (if Coolify version supports it)
- If not: use the workflow in `examples/coolify-deploy-after-gate.yml` which triggers Coolify webhook only after gate succeeds

---

## How it works

```
┌─────────────────┐
│  Developer      │
│  (vibe coding)  │
└────────┬────────┘
         │ git commit
         ▼
┌─────────────────┐
│  pre-commit     │  Fast checks (gitleaks + grep patterns)
│  hook (local)   │  Blocks commit if secret/empty-catch/etc detected
└────────┬────────┘
         │ git push
         ▼
┌─────────────────────────────────────┐
│  GitHub Actions: security-gate.yml  │
│  Invokes reusable workflow from     │
│  tropi/spedis-security-gate         │
└────────┬────────────────────────────┘
         │
         ├─ secret-scan (gitleaks full history)
         ├─ sast (Semgrep: OWASP + custom rules)
         ├─ dependency-audit (pnpm audit + OSV)
         ├─ custom-checks (env fallbacks, missing auth, raw SQL)
         │
         └─ summary (fails if any above failed)
                  │
                  ▼
         ┌────────────────┐
         │  Merge to main │  BLOCKED until gate passes
         └────────┬───────┘
                  │
                  ▼
         ┌────────────────┐
         │  Coolify       │  Deploys only after merge to protected main
         │  auto-deploys  │
         └────────────────┘
```

---

## Custom Semgrep rules

All rules live in `rules/semgrep/`. Each file focuses on one category so you can audit and tune them independently.

| File | What it catches |
|------|-----------------|
| `tenant-isolation.yml` | Drizzle/Prisma queries without tenant_id, DELETE/UPDATE without WHERE |
| `secrets-and-config.yml` | `process.env.X ?? "dev-secret"`, hardcoded API keys, secrets in logs |
| `error-handling.yml` | Empty catches, catches returning null, catches returning input (the Adscory encryption bug pattern) |
| `input-validation.yml` | `req.body` directly to DB, Hono endpoints without zValidator, path traversal |
| `crypto-and-auth.yml` | Secret comparison with `===`, JWT algorithm:"none", MD5/SHA1 for security, Math.random for tokens, bcrypt rounds < 10 |
| `injection.yml` | Shell injection, eval(), new Function(), raw SQL with concat, MongoDB operator injection |
| `ssrf.yml` | fetch()/axios() with user-controlled URL, open redirects |
| `xss.yml` | dangerouslySetInnerHTML without sanitize, innerHTML assignment, document.write |
| `cors-and-headers.yml` | CORS wildcard + credentials, helmet disabled, CSP with unsafe-inline |
| `deprecated-and-dangerous.yml` | console.log in prod, `any` in request handlers, SSL verification disabled, tokens in localStorage |

---

## Adding custom rules for a specific project

A project can add its own rules without modifying the central repo:

```
your-project/
├── .github/workflows/security-gate.yml  (from bootstrap)
└── .security/
    ├── semgrep-extra.yml    ← your custom rules
    └── allowlist.txt        ← known false positives
```

Then override the workflow to include them:

```yaml
# your-project/.github/workflows/security-gate.yml
jobs:
  gate:
    uses: tropi/spedis-security-gate/.github/workflows/reusable.yml@v1.0.0
    with:
      package-manager: pnpm
      extra-rules-path: .security/semgrep-extra.yml  # new input
```

---

## False positives and suppressions

### For a single line (Semgrep):

```ts
// nosemgrep: rule-id-here
const query = db.select().from(tenants);  // tenants table is not tenant-scoped
```

### For a file (gitleaks):

Add to `.gitleaksignore` (next to `.gitleaks.toml`):

```
# Example: ignore all matches in this fixtures file
src/tests/fixtures/sample-response.json:*
```

### For a whole rule (emergency only):

Add to repo's `.security/allowlist.txt` with a reason:

```
# tenant-isolation false positive on analytics queries
# WHY: analytics uses a separate database with only aggregated data
# OWNER: rafael@spedis.com.do
# EXPIRY: 2026-05-01
rule:drizzle-select-without-tenant-id
path:apps/analytics/src/queries/**
```

---

## Updating rules centrally

When you update a rule in `tropi/spedis-security-gate`:

```bash
cd spedis-security-gate
# Edit rules
git commit -am "feat: add rule for X"
git tag v1.1.0
git push --tags
```

Every project using `@v1.0.0` stays pinned (stable). To adopt the new rules:

```bash
# In each project
cd axisten
# Bump the version in .github/workflows/security-gate.yml from v1.0.0 to v1.1.0
# Or re-run bootstrap:
curl -sSL .../bootstrap.sh | SECGATE_VERSION=v1.1.0 bash
```

---

## Performance

Typical gate runtime on a small repo:

| Job | Duration |
|-----|----------|
| secret-scan | 20–40s |
| sast | 60–120s |
| dependency-audit | 30–60s |
| custom-checks | 5–15s |
| **Total (parallel)** | **~2 min** |

Jobs run in parallel. The total blocking time is roughly the slowest job (SAST), not the sum.

---

## When to skip the gate (breaking glass)

Never skip it to get code merged faster. The only legitimate reasons:

1. **Hotfix for active incident** — use a direct commit to a hotfix branch, merge manually, re-run gate after. Document in the incident report.
2. **False positive you can't suppress inline** — add a scoped allowlist with an expiry date (max 30 days) and a follow-up ticket to resolve.
3. **Dependency with known CVE that has no fix** — use `skip-audit: true` input temporarily, track in a TODO with mitigation plan.

In all three cases, the workaround is visible in git history, has a deadline, and has an owner. No silent bypasses.

---

## What this gate does NOT cover

This is critical to be honest about. The gate catches **code-level and config-level** vulnerabilities. It does not replace:

- **Penetration testing** — humans finding logic bugs (auth bypass, privilege escalation, business logic)
- **Infrastructure security** — Hetzner VPS hardening, Coolify permissions, DB access controls
- **Runtime monitoring** — intrusion detection, anomaly detection, log analysis
- **Threat modeling** — thinking through attack vectors before writing code
- **Supply chain attacks** — npm package taking over, typosquatting
- **Social engineering** — phishing, OAuth app impersonation

Plan those separately. The gate is necessary, not sufficient.

---

## License

MIT. Use it, fork it, modify it. If you find a bug or want to contribute a rule, open a PR.

---

## Changelog

### v1.0.0 (2026-04-16)
- Initial release
- 10 Semgrep rule files (60+ rules)
- gitleaks config with stack-specific patterns (Zoho, Meta, Anthropic, Hetzner, Cloudflare)
- 3 custom bash check scripts
- Pre-commit hook
- Bootstrap installer
