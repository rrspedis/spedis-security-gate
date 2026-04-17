# Extending the gate with project-specific rules

Sometimes a project has security concerns that don't belong in the central gate (e.g., "Adscory Meta pipeline must use atomic upserts only"). You can add project-specific rules without touching the central repo.

---

## Pattern 1: Project-local Semgrep rules

Create `.security/semgrep-project.yml` in your project:

```yaml
rules:
  - id: adscory-meta-insight-must-be-atomic
    message: |
      Meta insight writes must use atomic upsert, not separate select+insert.
      Non-atomic writes caused the duplicate AdPlatformMetric rows bug.
    severity: ERROR
    languages: [typescript]
    pattern-either:
      - pattern: |
          await db.select().from(adPlatformMetric).where(...)
          ...
          await db.insert(adPlatformMetric).values(...)
    pattern-not-inside: |
      await db.transaction(async () => { ... })
```

Then extend your workflow to include it:

```yaml
# .github/workflows/security-gate.yml
jobs:
  gate:
    uses: tropi/spedis-security-gate/.github/workflows/reusable.yml@v1.0.0
    with:
      package-manager: pnpm

  project-sast:
    runs-on: ubuntu-latest
    container:
      image: returntocorp/semgrep
    steps:
      - uses: actions/checkout@v4
      - run: semgrep scan --config .security/semgrep-project.yml --error --severity ERROR
```

---

## Pattern 2: Project-specific allowlist

If the central rules trigger false positives in your project, allowlist them locally:

`.security/allowlist.txt`:
```
# Analytics queries legitimately read across tenants
# because analytics DB has only aggregated non-PII data
rule:drizzle-select-without-tenant-id
path:apps/analytics/src/queries/**

# Intentionally public health endpoint
rule:endpoint-without-auth
path:apps/api/src/routes/health.ts
```

Hook into the custom-checks job to respect it:

```yaml
      - name: Apply project allowlist
        run: |
          if [ -f .security/allowlist.txt ]; then
            echo "Loading project allowlist..."
            export SEMGREP_ALLOWLIST=.security/allowlist.txt
          fi
```

Then pass `SEMGREP_ALLOWLIST` through to subsequent Semgrep invocations.

---

## Pattern 3: Project-specific bash checks

Some rules don't fit Semgrep (e.g., "every migration must have a corresponding rollback"). Write a bash check:

```bash
#!/usr/bin/env bash
# .security/check-migrations-have-rollback.sh

set -euo pipefail

MIGRATIONS_DIR="apps/api/src/db/migrations"
FAILED=0

for up_migration in "$MIGRATIONS_DIR"/*.up.sql; do
  name=$(basename "$up_migration" .up.sql)
  down_migration="$MIGRATIONS_DIR/$name.down.sql"
  
  if [ ! -f "$down_migration" ]; then
    echo "❌ Missing rollback for migration: $name"
    FAILED=$((FAILED + 1))
  fi
done

exit $FAILED
```

And add to workflow:

```yaml
  migration-rollbacks:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: bash .security/check-migrations-have-rollback.sh
```

---

## Examples of good project-specific rules

### Adscory
- Meta insight writes must be atomic upserts
- `resolveMetaToken()` is the only way to get Meta tokens (grep for direct env access)
- `AdPlatformMetric` unique index must not be removed

### Axisten (AI speaks, code decides)
- Haiku calls must not return JSON with executable actions
- `tool_definitions` executed only through `Action Orchestrator`, never inline
- OAuth state must come from Redis, not process memory

### Indesy
- `tenant_id` mandatory on every query (enforced via central rule already)
- `expenses.account_id` is source of truth, `category` is deprecated (WARN if new code writes to category)
- Payment engine FIFO logic must include `tenant_id` in partitioning

### crezco
- Email receipt parsing must strip PII from logs
- Claude API calls redact user financial data before send

---

## Upstreaming a rule

If a rule you wrote for one project is useful across all projects, contribute it upstream:

1. Generalize the rule (remove project-specific names)
2. Add it to the appropriate file in `rules/semgrep/` in the central repo
3. Open a PR with example trigger + expected behavior
4. Tag a new version `v1.x.0`

Over time the central repo grows into your organizational security memory.
