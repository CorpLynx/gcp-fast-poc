# Domain Restricted Sharing (DRS) Override — Why It's Needed

## What is DRS?

Domain Restricted Sharing is a GCP organization policy (`iam.allowedPolicyMemberDomains`) that restricts which identities can be granted IAM roles on resources within the org. When enforced, only members belonging to your org's Cloud Identity domain (e.g., `@gigachadglobal.org`) can be added to IAM policies. Any attempt to grant a role to an identity outside the domain is blocked.

This is a standard enterprise security control. It prevents accidental or malicious granting of access to external users or service accounts.

## The Problem

Several GCP services use Google-managed service agents — service accounts created and owned by Google, not by your organization. These agents have email addresses like:

- `service-PROJECT_NUMBER@security-center-api.iam.gserviceaccount.com`
- `service-PROJECT_NUMBER@gcp-sa-ktd-hpsa.iam.gserviceaccount.com`
- `service-PROJECT_NUMBER@gcp-sa-dspm-hpsa.iam.gserviceaccount.com`
- `service-PROJECT_NUMBER@gcp-sa-csc-hpsa.iam.gserviceaccount.com`

These agents don't belong to your org domain. When DRS is enforced at the org level, any operation that tries to bind these agents to IAM policies on your projects will fail with:

```
FAILED_PRECONDITION: One or more users named in the policy do not belong to a permitted customer.
```

This specifically blocks:

1. Activating Security Command Center (SCC) — SCC activation binds its service agents to the project
2. Enabling certain APIs that auto-create service agent bindings
3. Any Terraform resource that creates IAM bindings for Google-managed service agents

## When Does This Happen?

During FAST Stage 0 bootstrap, you need to:
- Enable `securitycentermanagement.googleapis.com` on the seed project
- Activate SCC Standard tier at the org level (via Console)
- SCC activation creates service agent bindings on the seed project

If DRS is already enforced on the org (which it is in your case — it was set before FAST was deployed), these bindings are blocked.

## The Fix

Override `iam.allowedPolicyMemberDomains` on the seed project only, allowing all domains:

```bash
gcloud org-policies set-policy --project=fpoc-seed-bootstrap /dev/stdin <<EOF
name: projects/fpoc-seed-bootstrap/policies/iam.allowedPolicyMemberDomains
spec:
  rules:
    - allowAll: true
EOF
```

This override is scoped to the seed project only — it does not weaken DRS at the org level. The seed project is temporary and gets deleted after WIF switchover.

## Why This Is Safe

- The override only applies to the seed project, not the entire org
- The seed project is ephemeral — it exists only for the bootstrap phase
- FAST itself re-deploys DRS at the org level with tag-based exceptions that properly allow Google service agents where needed
- After Stage 0 succeeds and WIF is configured, the seed project is deleted, taking the override with it

## Why FAST Doesn't Handle This Automatically

FAST assumes it's the first thing deployed in a clean org. In a clean org, DRS isn't enforced yet — FAST is the one that sets it up (with proper exceptions for service agents via tag conditions). But if your org already has DRS enforced before FAST runs (common in enterprise orgs), the bootstrap hits this chicken-and-egg problem: FAST needs to run to set up the proper DRS exceptions, but DRS blocks FAST from running.

## Required Permissions

To set the override, you need `roles/orgpolicy.policyAdmin` on the org (or at least on the seed project). This role is part of the bootstrap SA's grants in Step 5 of the runbook, but your user account also needs it if you're running the override manually from Cloud Shell.

## Cleanup

The override is automatically cleaned up when the seed project is deleted. If you want to explicitly revert it before deletion:

```bash
gcloud org-policies reset iam.allowedPolicyMemberDomains --project=fpoc-seed-bootstrap
```

## Also Affected

The same DRS constraint also blocks the managed variant `iam.managed.allowedPolicyMemberDomains` if it exists on your org. The seed project override for the legacy constraint is usually sufficient, but if you encounter issues with the managed variant, override it too:

```bash
gcloud org-policies set-policy --project=fpoc-seed-bootstrap /dev/stdin <<EOF
name: projects/fpoc-seed-bootstrap/policies/iam.managed.allowedPolicyMemberDomains
spec:
  rules:
    - allowAll: true
EOF
```
