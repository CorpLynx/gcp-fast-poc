# Runbook Change Tracker

Changes made to `FAST-Pre-Bootstrap-Runbook-2.md` during the FAST POC setup.

---

## 2026-04-05 — Org policy override for SA key creation

**Problem:** `iam.disableServiceAccountKeyCreation` and `iam.managed.disableServiceAccountKeyCreation` enforced at the org level blocked SA key generation on the seed project. Stage 0 hadn't run yet — the policy was pre-existing on the org (set 2026-03-31).

**Changes:**
- Added Step 7: overrides both org policy constraints on the seed project only (`enforce: false`)
- Renumbered old Steps 7/8/9 → 8/9/10
- Cleanup section: added `gcloud org-policies reset` for both constraints to revert overrides after WIF switchover
- Cleanup section: hardcoded `FAST_PREFIX`, `ORG_ID`, `BILLING_ACCOUNT_ID` so it works in a fresh Cloud Shell session
- Cleanup section: uncommented seed project deletion — runs by default now since FAST creates its own `iac-0` project

---

## 2026-04-05 — Replaced tfvars generation with defaults.yaml instructions

**Problem:** Step 9 generated a `0-org-setup.auto.tfvars` with variables (`organization`, `billing_account`, `prefix`, `groups`, `locations`) that don't exist in the current `0-org-setup` stage. The current stage only accepts `context`, `factories_config`, and `org_policies_imports`. All org/billing/prefix/location config lives in `datasets/hardened/defaults.yaml`.

**Changes:**
- Replaced Step 9: removed the `cat > 0-org-setup.auto.tfvars` script entirely
- New Step 9: instructions to edit `defaults.yaml` directly in the repo with real org/billing/prefix/domain values
- Added note about `org_policies_imports` tfvars for importing pre-existing org policies if needed during first apply
