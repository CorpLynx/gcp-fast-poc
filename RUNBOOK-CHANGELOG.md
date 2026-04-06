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

## 2026-04-06 — Added securitycentermanagement.admin role to Step 5

**Problem:** Stage 0 apply failed with `IAM_PERMISSION_DENIED` on all 16 `google_scc_management_organization_security_health_analytics_custom_module` resources. The bootstrap SA needs `roles/securitycentermanagement.admin` at the org level to create SCC SHA custom modules.

**Changes:**
- Step 5: added `roles/securitycentermanagement.admin` to the org-level role grant loop
- Step 5: added inline comment noting which resources fail without it
- Cleanup section: added the same role to the removal loop

---

## 2026-04-06 — Added missing APIs to Step 2 (essentialcontacts, securitycentermanagement)

**Problem:** Stage 0 apply failed because `essentialcontacts.googleapis.com` and `securitycentermanagement.googleapis.com` were not enabled on the seed project. The bootstrap SA makes org-level API calls that route through the seed project's quota/billing, so these APIs must be enabled there.

**Failed resources without them:**
- `google_essential_contacts_contact` — org-level essential contacts for gcp-organization-admins
- All `google_scc_management_organization_security_health_analytics_custom_module` resources (16 total) — SCC SHA custom modules for artifact registry CMEK, Cloud Run binary auth, Cloud SQL HA/PITR, GKE confidential nodes, GKE dataplane v2, GKE regional clusters, KMS algorithms/protection levels, nested virtualization, secret rotation, Cloud Functions ingress/VPC connector, Cloud Run egress/ingress/default SA

**Changes:**
- Step 2: added `essentialcontacts.googleapis.com` and `securitycentermanagement.googleapis.com` to the API enable list
- Step 2: added inline comments noting which resources fail without each API

---

## 2026-04-05 — Replaced tfvars generation with defaults.yaml instructions

**Problem:** Step 9 generated a `0-org-setup.auto.tfvars` with variables (`organization`, `billing_account`, `prefix`, `groups`, `locations`) that don't exist in the current `0-org-setup` stage. The current stage only accepts `context`, `factories_config`, and `org_policies_imports`. All org/billing/prefix/location config lives in `datasets/hardened/defaults.yaml`.

**Changes:**
- Replaced Step 9: removed the `cat > 0-org-setup.auto.tfvars` script entirely
- New Step 9: instructions to edit `defaults.yaml` directly in the repo with real org/billing/prefix/domain values
- Added note about `org_policies_imports` tfvars for importing pre-existing org policies if needed during first apply
