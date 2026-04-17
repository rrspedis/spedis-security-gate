# Integration with Coolify

**Goal:** Coolify must only deploy code that passed the security gate. No bypass.

Coolify by default deploys on every push to the watched branch. That's too permissive — a `git push main` that skips GitHub Actions (via `--no-verify` bypassing hooks, or committing directly without a PR) deploys unvetted code.

This doc covers the three patterns to close that gap, in order of preference.

---

## Pattern A (preferred): Branch protection + wait for checks

### How it works

1. GitHub branch protection on `main` requires the `gate / summary` check to pass before merge.
2. Developers cannot push directly to `main` (protected).
3. All changes enter `main` via PR that passed the gate.
4. Coolify watches `main` and deploys every new commit.

Because `main` is protected, every commit on it already passed the gate.

### Setup

**GitHub side:**

1. Repo → Settings → Branches → Add branch protection rule
2. Branch name pattern: `main`
3. Enable:
   - ✅ Require a pull request before merging
   - ✅ Require status checks to pass before merging
   - ✅ Require branches to be up to date before merging
   - Required checks: **`gate / summary`**
   - ✅ Do not allow bypassing the above settings (even for admins)
4. Optionally:
   - ✅ Require conversation resolution before merging
   - ✅ Require signed commits

**Coolify side:**

1. Application → Configuration → Source → ensure branch is `main`
2. Application → Configuration → Advanced → Enable "Watch the repository for changes"
3. No further action needed — Coolify deploys every commit on `main`, and every commit on `main` is gate-verified.

**Verification:**

```bash
# This should fail:
git checkout main
git commit --allow-empty -m "direct push test"
git push origin main
# Expected: remote rejected - protected branch hook declined
```

---

## Pattern B: Coolify webhook triggered by gate success

If you're a solo developer and don't want to PR your own changes (but still want the gate to run):

### How it works

1. Coolify's "auto-deploy on push" is **disabled**.
2. Coolify exposes a deploy webhook URL.
3. A GitHub Action job runs AFTER the gate succeeds on `main` and calls Coolify's webhook.
4. Result: deploy fires only on gate-passing commits.

### Setup

**Coolify side:**

1. Application → Settings → Deploy → copy the "Deploy Webhook URL"
2. Disable "Auto-deploy on push"

**GitHub side:**

1. Repo → Settings → Secrets → Add secret:
   - Name: `COOLIFY_DEPLOY_WEBHOOK`
   - Value: the webhook URL from Coolify
2. Add to `.github/workflows/coolify-deploy.yml`:

```yaml
name: Coolify Deploy

on:
  workflow_run:
    workflows: ["Security Gate"]
    types: [completed]
    branches: [main]

jobs:
  deploy:
    if: ${{ github.event.workflow_run.conclusion == 'success' }}
    runs-on: ubuntu-latest
    steps:
      - name: Trigger Coolify deploy
        run: |
          curl -X POST \
            -H "Authorization: Bearer ${{ secrets.COOLIFY_DEPLOY_TOKEN }}" \
            "${{ secrets.COOLIFY_DEPLOY_WEBHOOK }}"
```

The key line: `if: ${{ github.event.workflow_run.conclusion == 'success' }}` — deploy only if the gate workflow succeeded.

### Verification

Push a commit that would fail the gate (e.g., `console.log('leaked: sk-ant-12345...')` somewhere), push to main, confirm:
1. Gate fails
2. Coolify deploy action does NOT trigger
3. Coolify dashboard shows no new deploy

---

## Pattern C: Release branch (for team workflows with Coolify pre-prod)

For projects where you want staging deploys from `main` and production deploys gated separately:

### How it works

1. `main` is gate-protected, Coolify deploys to **staging** automatically.
2. `release/*` branches are also gate-protected, Coolify watches `release/prod` for production deploys.
3. Promote to production by merging `main` into `release/prod`.

### Setup

**Coolify:**

- App "Staging" watches `main`
- App "Production" watches `release/prod`

**GitHub:**

- Branch protection on both `main` and `release/prod` requiring `gate / summary`
- `release/prod` additionally requires manual approval (CODEOWNERS) before merge

This gives you two layers: code passes gate + stages before prod, and prod requires explicit promotion.

---

## What to do if Coolify has an older version without workflow wait

Older Coolify versions deploy on push without a way to wait. In that case:

1. Use Pattern B (disable auto-deploy, trigger via webhook after gate).
2. Or: upgrade Coolify to a version that supports deploy webhooks and disabling auto-deploy.

If you can't do either, there's a lower-quality fallback: set up a self-hosted runner that runs the gate locally before `git push origin main`. Add a pre-push hook:

```bash
# .git/hooks/pre-push
#!/bin/bash
remote="$1"
url="$2"
protected_branch="main"

while read local_ref local_oid remote_ref remote_oid; do
  if [[ "$remote_ref" == *"$protected_branch" ]]; then
    echo "Running security gate before push to $protected_branch..."
    semgrep scan --config rules/semgrep --error --severity ERROR || {
      echo "❌ Security gate failed. Push blocked."
      exit 1
    }
  fi
done
```

This is weaker (can be bypassed with `--no-verify`), but better than nothing.

---

## Emergency hotfix path

Sometimes prod is down and you need to push a fix NOW, bypassing the gate. Legitimate scenarios:

1. **Known incident, fix is trivial, gate is slow.** Create a `hotfix/incident-N` branch, push, Coolify deploys to a pre-flagged hotfix app (separate from staging/prod watcher), validate, then merge to main through proper gate later.

2. **Gate is broken (false positive blocking legit change).** Use `[skip gate]` in commit message ONLY if the gate's false positive is documented and a PR is open to fix it. This should be rare.

3. **Vulnerability in a dependency with no upgrade path yet.** Use the `skip-audit: true` input temporarily.

**Never:** disable branch protection, merge without review, or push directly to main as a habit.

---

## Monitoring the gate

Add a weekly summary to your team (or yourself):

```yaml
# .github/workflows/gate-weekly-report.yml
name: Gate Weekly Report

on:
  schedule:
    - cron: '0 9 * * MON'  # Monday 9am

jobs:
  report:
    runs-on: ubuntu-latest
    steps:
      - name: Summarize last week's gate runs
        run: |
          gh run list --workflow=security-gate.yml --limit 50 --json status,conclusion,createdAt | \
            jq 'group_by(.conclusion) | map({conclusion: .[0].conclusion, count: length})'
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

If the gate fails more than ~15% of runs, it's either (a) catching real issues consistently (good — review what's escaping), or (b) too noisy (tune rules or allowlist).
