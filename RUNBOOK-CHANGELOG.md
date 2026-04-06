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

## 2026-04-06 — DRS org policy blocks SCC activation on seed project

**Problem:** Activating Security Command Center on the seed project requires binding Google-managed service agents (e.g. `@security-center-api.iam.gserviceaccount.com`) to the project. The pre-existing `iam.allowedPolicyMemberDomains` org policy blocks these bindings because the service agents don't belong to the org domain (`gigachadglobal.org`). This is not a FAST-specific policy — it's a standard enterprise DRS constraint.

**Fix:** Override `iam.allowedPolicyMemberDomains` on the seed project only with `allowAll: true` before activating SCC. The override is scoped to the temporary seed project which gets deleted in cleanup. FAST itself re-deploys DRS at the org level with tag-based exceptions that properly allow service agents.

```bash
gcloud org-policies set-policy --project=fast-seed-bootstrap /dev/stdin <<EOF
name: projects/fast-seed-bootstrap/policies/iam.allowedPolicyMemberDomains
spec:
  rules:
    - allowAll: true
EOF
```

**Note:** This should be added to Step 7 of the runbook alongside the other org policy overrides if DRS is enforced on the org before FAST runs.

---

## 2026-04-06 — Added SCC activation step, GHA state persistence, import-and-apply workflow

**Problem 1:** All 16 SCC SHA custom modules failed with `404: Parent resource not found` even after granting `roles/securitycentermanagement.admin`. SCC Standard/Premium tier must be activated at the org level via the GCP Console before the API can manage org-level resources. Enabling the API on the seed project is not enough.

**Problem 2:** GHA workflow used local backend with ephemeral runners. State was lost between runs, causing "already exists" errors on retry for custom roles, tag keys, tag values, and folders created by the first partial apply.

**Changes:**
- Runbook: added Step 2b for SCC activation via GCP Console (no gcloud equivalent exists)
- Workflow: added `terraform.tfstate` artifact upload/download for state persistence across runs (90-day retention)
- Workflow: added `import-and-apply` action that imports orphaned resources (custom roles, tag keys, tag values, folders, org logging settings) into state before planning and applying
- Workflow: uses `dawidd6/action-download-artifact@v6` to retrieve state from previous workflow runs

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
