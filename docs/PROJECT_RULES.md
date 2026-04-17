# Project-specific rulesets (ready to drop in)

Pre-built project-specific Semgrep rules for Rafael's stack. Copy the block for each project into its `.security/semgrep-project.yml`.

---

## Adscory (Performance Intelligence Center)

```yaml
# .security/semgrep-project.yml
rules:
  - id: adscory-meta-insight-must-be-atomic
    message: |
      Meta insight writes must use atomic upsert (onConflictDoUpdate), not
      separate select + insert/update. Non-atomic writes caused duplicate
      AdPlatformMetric rows in production (Q3 2025 incident).
    severity: ERROR
    languages: [typescript]
    pattern: |
      await db.insert($TABLE).values($VALS)
    pattern-not: |
      await db.insert($TABLE).values($VALS).onConflictDoUpdate(...)
    pattern-not: |
      await db.insert($TABLE).values($VALS).onConflictDoNothing()
    paths:
      include:
        - "**/meta/**"
        - "**/meta-pipeline/**"
        - "**/ad-platform-metric*"

  - id: adscory-meta-token-direct-env-access
    message: |
      Meta token must be retrieved via resolveMetaToken() only.
      Direct process.env.META_* access bypasses the token refresh worker
      and will break when tokens expire.
    severity: ERROR
    languages: [typescript]
    pattern-either:
      - pattern: process.env.META_ACCESS_TOKEN
      - pattern: process.env.FACEBOOK_ACCESS_TOKEN
      - pattern: process.env.META_LONG_LIVED_TOKEN
    paths:
      exclude:
        - "**/resolve-meta-token*"
        - "**/meta-token-refresh*"

  - id: adscory-google-token-direct-env-access
    message: |
      Google token must be retrieved via the unified token source,
      not direct env access.
    severity: ERROR
    languages: [typescript]
    pattern-either:
      - pattern: process.env.GOOGLE_ACCESS_TOKEN
      - pattern: process.env.GOOGLE_REFRESH_TOKEN
    paths:
      exclude:
        - "**/resolve-google-token*"
        - "**/google-token-refresh*"

  - id: adscory-aggregate-lead-counting
    message: |
      aggregate_lead action type must be deduped against lead action type.
      Counting both = inflated lead numbers (the Q3 2025 regression).
      Use the Regression Guard pattern in CLAUDE.md.
    severity: WARNING
    languages: [typescript]
    pattern-regex: "aggregate_lead"
    pattern-not-regex: "// @dedup-validated"
```

---

## Axisten (AI agent platform)

```yaml
# .security/semgrep-project.yml
rules:
  - id: axisten-haiku-must-return-text-only
    message: |
      Engine v3 principle: "la IA habla, el código decide".
      Haiku/Claude must return text extraction only, never executable actions.
      If you see JSON action fields in Claude response types, architecture is wrong.
    severity: ERROR
    languages: [typescript]
    pattern-either:
      - pattern-regex: 'proposedAction.*:.*execute'
      - pattern-regex: 'toolUse.*:.*auto_execute'

  - id: axisten-oauth-state-in-memory
    message: |
      OAuth state must persist in Redis or DB, not process memory.
      In-memory state breaks with multiple replicas and does not expire properly.
    severity: ERROR
    languages: [typescript]
    pattern-either:
      - pattern: |
          const oauthStates = new Map()
      - pattern: |
          const stateStore = {}
      - pattern: |
          const pendingStates = new Map()
    paths:
      include:
        - "**/oauth/**"

  - id: axisten-pkce-required
    message: |
      OAuth flows must use PKCE (code_challenge + code_verifier).
      Required for Sprint 7B completion.
    severity: WARNING
    languages: [typescript]
    pattern: |
      const authUrl = `$URL?client_id=...&redirect_uri=...`
    pattern-not-regex: "code_challenge"

  - id: axisten-whatsapp-raw-message-to-user
    message: |
      Raw JSON from Haiku must never be sent directly as WhatsApp message.
      Always pass through the message formatter. Triple greeting + raw JSON
      bugs came from direct passthrough.
    severity: ERROR
    languages: [typescript]
    pattern-either:
      - pattern: sendWhatsAppMessage($CTX, haikuResponse)
      - pattern: whatsapp.send(haikuResponse.raw)
      - pattern: |
          const msg = JSON.stringify($HAIKU);
          sendWhatsApp(msg);

  - id: axisten-tenant-isolation-strict
    message: |
      Axisten is strict multi-tenant. Every query on tool_definitions,
      agents, sessions, or oauth tokens must include tenantId in WHERE.
    severity: ERROR
    languages: [typescript]
    pattern-either:
      - pattern: db.select().from(toolDefinitions)
      - pattern: db.select().from(agents)
      - pattern: db.select().from(oauthTokens)
      - pattern: db.select().from(integrations)
    pattern-not-inside: |
      ...
      .where(...)
      ...
```

---

## Indesy (Real estate ERP)

```yaml
# .security/semgrep-project.yml
rules:
  - id: indesy-expenses-category-deprecated
    message: |
      expenses.category is deprecated as source of truth.
      Use expenses.accountId (FK to tenant_accounts) for new code.
      Reads of category are OK during transition, writes are not.
    severity: WARNING
    languages: [typescript]
    pattern-either:
      - pattern: |
          db.insert(expenses).values({ ..., category: $X, ... })
      - pattern: |
          db.update(expenses).set({ ..., category: $X, ... })
    pattern-not: |
      db.insert(expenses).values({ ..., category: $X, accountId: $Y, ... })

  - id: indesy-payment-engine-fifo-tenant-scoped
    message: |
      Payment FIFO allocation must be partitioned by tenantId.
      Cross-tenant payment application is a critical data integrity bug.
    severity: ERROR
    languages: [typescript]
    pattern-either:
      - pattern: |
          db.select().from(paymentApplications).orderBy(...)
      - pattern: |
          allocateFifoPayments($PAYMENT)
    pattern-not-regex: "tenantId"

  - id: indesy-paid-calculation-inconsistent
    message: |
      Never calculate `paid = totalPrice - balanceAtDelivery` directly.
      Use SUM(payment_applications.amount) for audit consistency.
      This inconsistency caused the financial data integrity bug.
    severity: WARNING
    languages: [typescript]
    pattern-regex: 'paid\s*=\s*\w*totalPrice\w*\s*-\s*\w*balanceAtDelivery'

  - id: indesy-document-engine-snapshot-required
    message: |
      Document generation must use snapshot (client_data_snapshot), not live
      client data. Live data changes retroactively modify signed documents.
    severity: ERROR
    languages: [typescript]
    pattern-either:
      - pattern: |
          generateContract({ ..., clientId: $X, ... })
      - pattern: |
          renderTemplate($T, { client: await getClient($ID) })
    pattern-not-regex: "snapshot"

  - id: indesy-cron-mora-must-be-idempotent
    message: |
      Mora calculation cron must be idempotent. A double-run should not
      produce double mora charges. Check for existing mora record before insert.
    severity: WARNING
    languages: [typescript]
    pattern: |
      await db.insert(moraCharges).values($V)
    pattern-not-inside: |
      const existing = await db.select().from(moraCharges).where(...)
      if (existing.length > 0) { ... }
      ...
```

---

## crezco (Personal finance)

```yaml
# .security/semgrep-project.yml
rules:
  - id: crezco-pii-in-logs
    message: |
      Personal financial data (amounts, account numbers, merchant names)
      must not appear in logs. Logger has redact config — use it.
    severity: WARNING
    languages: [typescript]
    pattern-either:
      - pattern-regex: 'logger\.(info|debug|warn)\([^)]*(amount|account_number|balance|transaction)'
      - pattern-regex: 'console\.log\([^)]*(amount|account_number|balance)'

  - id: crezco-gmail-oauth-scope-minimal
    message: |
      Gmail OAuth scope must be gmail.readonly, not gmail.modify or gmail.full.
      Write scope is not needed for receipt parsing.
    severity: ERROR
    languages: [typescript]
    pattern-regex: "(gmail\\.modify|gmail\\.full|https://mail\\.google\\.com/)"

  - id: crezco-claude-vision-raw-image
    message: |
      Receipts sent to Claude Vision must have PII stripped or redacted first.
      Raw image may contain account numbers, names not belonging to the user.
    severity: WARNING
    languages: [typescript]
    pattern-either:
      - pattern: anthropic.messages.create({ ..., content: [{ type: "image", source: { data: $RAW } }] })
    pattern-not-inside: |
      const redacted = await redactPii($RAW);
      ...

  - id: crezco-invite-only-auth-enforced
    message: |
      crezco uses invite-only auth. Signup endpoint must check invite token.
    severity: ERROR
    languages: [typescript]
    pattern: |
      app.post("/signup", async (ctx) => { ... })
    pattern-not-regex: "inviteToken|invite_token|validateInvite"
```

---

## Spedis client projects (real estate, healthcare, insurance)

For Zoho-based client implementations, the most common vulnerability category is Deluge functions that don't validate inputs. Add:

```yaml
# .security/semgrep-project.yml
rules:
  - id: deluge-zoho-direct-string-interpolation
    message: |
      Deluge function constructing query with string concatenation of user input.
      Use parameterized zoho.crm.searchRecords() with criteria object.
    severity: WARNING
    languages: [generic]
    pattern-regex: 'zoho\.crm\.(getRecords|searchRecords).*"[^"]*\+\s*\w+'
    paths:
      include:
        - "**/*.dg"
        - "**/*.deluge"

  - id: deluge-hardcoded-connection-string
    message: |
      Zoho connection string literal hardcoded. Must be a named connection.
      Exception: zoho.writer.mergeAndSign() has a documented hardcoded literal.
    severity: INFO
    languages: [generic]
    pattern-regex: 'invokeurl\s*\[\s*url\s*:\s*"[^"]+"\s*type\s*:\s*POST'
```

---

## How to apply

In each project:

```bash
mkdir -p .security
# Copy the relevant block from above into .security/semgrep-project.yml
```

Then update the workflow to include project rules:

```yaml
# .github/workflows/security-gate.yml
jobs:
  gate:
    uses: tropi/spedis-security-gate/.github/workflows/reusable.yml@v1.0.0
    with:
      package-manager: pnpm

  project-rules:
    runs-on: ubuntu-latest
    container:
      image: returntocorp/semgrep
    steps:
      - uses: actions/checkout@v4
      - run: semgrep scan --config .security/semgrep-project.yml --error --severity ERROR
```

---

## When to upstream vs keep local

**Keep local:**
- Rules referencing specific table names, function names, or business logic unique to the project
- Rules for deprecated migrations still in transition (remove when migration complete)
- Temporary guards for known bugs being remediated

**Upstream to central gate:**
- Generic patterns that apply to any project (e.g., "no secrets in logs")
- Rules that catch anti-patterns your team writes repeatedly across projects
- Rules that should apply company-wide (e.g., "always use Spedis logger wrapper")
