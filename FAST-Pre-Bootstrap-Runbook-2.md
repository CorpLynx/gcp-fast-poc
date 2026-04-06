# FAST Pre-Bootstrap Setup — Cloud Shell Runbook

Run these steps in **GCP Cloud Shell** as your Super Admin. Each step is copy-paste ready.
Cloud Shell has `gcloud` pre-installed and pre-authenticated.

---

## Find Your IDs

Run this first to get the values you need for the variables block.

```bash
# List all GCP organizations your account has access to.
# Look for the numeric ID in the "ID" column — that's your ORG_ID.
echo "=== Organization ==="
gcloud organizations list

# List all billing accounts your account can see.
# The ID is in the format XXXXXX-XXXXXX-XXXXXX — that's your BILLING_ACCOUNT_ID.
echo ""
echo "=== Billing Accounts ==="
gcloud billing accounts list

# Show which Google account you're currently authenticated as.
# This should be your Super Admin (e.g., super-admin@yourdomain.com).
echo ""
echo "=== Current Account ==="
gcloud config get-value account

# Retrieve the Cloud Identity Customer ID tied to your organization.
# This is used later in FAST's tfvars for domain-restricted sharing policies.
echo ""
echo "=== Customer ID ==="
ORG_ID=$(gcloud organizations list --format="value(ID)" --limit=1)
gcloud organizations describe "$ORG_ID" --format="value(owner.directoryCustomerId)"
```

Note the **Organization ID** (numeric) and **Billing Account ID** (format: `XXXXXX-XXXXXX-XXXXXX`) from the output.

---

## Set Your Variables

Edit these values using the IDs from above, then paste the entire block into Cloud Shell.

Notes:
- **FAST_PREFIX** must be lowercase, max 9 characters (e.g., your company abbreviation)
- **DEFAULT_REGION** uses no dash before the number (e.g., `us-east4` not `us-east-4`)

```bash
# Your verified domain — the one tied to Cloud Identity / Google Workspace.
export DOMAIN="gigachadglobal.org"

# Numeric organization ID from the discovery step above.
export ORG_ID="1041701195417"

# Billing account ID from the discovery step above (format: XXXXXX-XXXXXX-XXXXXX).
export BILLING_ACCOUNT_ID="014F76-ED4E67-7CCCE1"

# Short prefix prepended to every resource FAST creates (lowercase, max 9 chars).
# This makes GCP project IDs globally unique. Use a company abbreviation.
export FAST_PREFIX="fast"

# Default GCP region for FAST resources (BigQuery, GCS, logging).
# Pick a region that supports all core services. No dash before the number.
export DEFAULT_REGION="us-east4"

# Derived values — no need to edit these.
# SEED_PROJECT: temporary project to host the bootstrap SA and enable APIs.
export SEED_PROJECT="${FAST_PREFIX}-seed-bootstrap"

# BOOTSTRAP_SA_NAME: name of the service account that will run Stage 0.
export BOOTSTRAP_SA_NAME="fast-bootstrap"

# BOOTSTRAP_SA_EMAIL: full email of the bootstrap SA (derived from name + project).
export BOOTSTRAP_SA_EMAIL="${BOOTSTRAP_SA_NAME}@${SEED_PROJECT}.iam.gserviceaccount.com"

# SA_MEMBER: IAM principal format for the bootstrap SA, used in role bindings.
export SA_MEMBER="serviceAccount:${BOOTSTRAP_SA_EMAIL}"
```

Verify your org and billing are accessible:

```bash
# Should print your organization's display name (e.g., "yourdomain.com").
gcloud organizations describe "$ORG_ID" --format="value(displayName)"

# Should print your billing account's display name (e.g., "My Billing Account").
gcloud billing accounts describe "$BILLING_ACCOUNT_ID" --format="value(displayName)"
```

---

## Step 1: Create Seed Project

A temporary GCP project to host the bootstrap service account and enable APIs.
FAST's Stage 0 will create its own automation projects — this seed project can
be deleted after WIF switchover.

```bash
# Create a new project under your organization.
# Project IDs are globally unique — the prefix keeps it unique.
gcloud projects create "$SEED_PROJECT" \
  --organization="$ORG_ID" \
  --name="FAST Bootstrap Seed"

# Link the seed project to your billing account so API usage can be billed.
# Without billing, most APIs will refuse to enable.
gcloud billing projects link "$SEED_PROJECT" \
  --billing-account="$BILLING_ACCOUNT_ID"
```

---

## Step 2: Enable APIs

Enable the GCP APIs that Stage 0 needs when it runs. These are enabled on the
seed project so the bootstrap SA can make API calls during terraform apply.

```bash
# cloudresourcemanager  — manage projects, folders, orgs
# cloudbilling          — link projects to billing accounts
# iam                   — manage service accounts and IAM policies
# cloudidentity         — manage Cloud Identity groups
# orgpolicy             — set organization-level policies
# serviceusage          — enable/disable APIs on projects
# cloudasset            — inventory org resources (used by FAST for validation)
# accesscontextmanager  — VPC Service Controls perimeter management
# storage               — GCS buckets for Terraform state and FAST outputs
# essentialcontacts     — org-level essential contacts (failed without: google_essential_contacts_contact)
# securitycentermanagement — SCC custom SHA modules (failed without: all google_scc_management_organization_security_health_analytics_custom_module resources)
gcloud services enable \
  cloudresourcemanager.googleapis.com \
  cloudbilling.googleapis.com \
  iam.googleapis.com \
  cloudidentity.googleapis.com \
  orgpolicy.googleapis.com \
  serviceusage.googleapis.com \
  cloudasset.googleapis.com \
  accesscontextmanager.googleapis.com \
  storage.googleapis.com \
  essentialcontacts.googleapis.com \
  securitycentermanagement.googleapis.com \
  --project="$SEED_PROJECT"
```

---

## Step 3: Create Google Groups

FAST assigns IAM roles to these groups, not to individual users. The groups must
exist before Stage 0 runs. If the gcloud commands fail (Cloud Identity API
permissions), create them manually at admin.google.com → Groups.

```bash
# Loop through each required group and create it in Cloud Identity.
# --organization        ties the group to your GCP org
# --with-initial-owner  adds the current user as an owner of the group
# 2>/dev/null           suppresses verbose error output for cleaner logs
for group in \
  gcp-organization-admins \
  gcp-billing-admins \
  gcp-network-admins \
  gcp-security-admins \
  gcp-logging-admins \
  gcp-devops; do

  gcloud identity groups create "${group}@${DOMAIN}" \
    --organization="$ORG_ID" \
    --display-name="$group" \
    --description="FAST prerequisite group" \
    --with-initial-owner=WITH_INITIAL_OWNER \
    2>/dev/null && echo "Created: ${group}@${DOMAIN}" \
    || echo "Already exists or failed: ${group}@${DOMAIN} — create manually in admin.google.com if needed"
done
```

---

## Step 4: Create Bootstrap Service Account

This is the temporary identity that runs FAST Stage 0 from your GHES pipeline.
It gets broad org-level roles for the initial deployment, and is destroyed
after Workload Identity Federation (WIF) takes over.

```bash
# Create the SA in the seed project.
# --display-name and --description are metadata to remind you this is temporary.
gcloud iam service-accounts create "$BOOTSTRAP_SA_NAME" \
  --project="$SEED_PROJECT" \
  --display-name="FAST Bootstrap (destroy after WIF switchover)" \
  --description="Temporary SA for FAST Stage 0 via GHES. Delete after WIF."
```

---

## Step 5: Grant Organization IAM Roles

Grant the bootstrap SA the org-level roles it needs to run Stage 0.
These are broad permissions — Stage 0 creates projects, custom roles,
folders, service accounts, org policies, logging sinks, and tags.

```bash
# Each role grants a specific capability needed by Stage 0:
#   organizationAdmin       — full org-level admin (create custom roles, manage IAM)
#   projectCreator          — create the automation, billing, and logging projects
#   folderAdmin             — create the top-level folder hierarchy
#   organizationRoleAdmin   — create custom IAM roles at the org level
#   securityAdmin           — manage org-level security settings
#   serviceAccountAdmin     — create per-stage service accounts
#   policyAdmin             — set organization policies (e.g., domain restriction)
#   configWriter            — configure org-level log sinks
#   networkAdmin            — manage shared VPC host project designation
#   xpnAdmin                — manage cross-project networking (Shared VPC)
#   tagAdmin                — create org-level tags (used for IAM conditions)
#   policyAdmin (ACM)       — manage VPC Service Controls access policies
#   organizationViewer      — read org metadata
for role in \
  roles/resourcemanager.organizationAdmin \
  roles/resourcemanager.projectCreator \
  roles/resourcemanager.folderAdmin \
  roles/iam.organizationRoleAdmin \
  roles/iam.securityAdmin \
  roles/iam.serviceAccountAdmin \
  roles/orgpolicy.policyAdmin \
  roles/logging.configWriter \
  roles/compute.networkAdmin \
  roles/compute.xpnAdmin \
  roles/resourcemanager.tagAdmin \
  roles/accesscontextmanager.policyAdmin \
  roles/resourcemanager.organizationViewer; do

  # add-iam-policy-binding is additive — it won't remove existing bindings.
  # --quiet suppresses the confirmation prompt.
  gcloud organizations add-iam-policy-binding "$ORG_ID" \
    --member="$SA_MEMBER" \
    --role="$role" \
    --quiet > /dev/null 2>&1 \
    && echo "Granted: $role" \
    || echo "Failed: $role"
done
```

---

## Step 6: Grant Billing IAM Roles

Stage 0 creates projects and links them to the billing account, so the
bootstrap SA needs permissions on the billing account itself.

```bash
# billing.admin  — full control over the billing account (needed to set IAM on it)
# billing.user   — link projects to the billing account
for role in \
  roles/billing.admin \
  roles/billing.user; do

  # Same additive binding, but on the billing account instead of the org.
  gcloud billing accounts add-iam-policy-binding "$BILLING_ACCOUNT_ID" \
    --member="$SA_MEMBER" \
    --role="$role" \
    --quiet > /dev/null 2>&1 \
    && echo "Granted: $role" \
    || echo "Failed: $role"
done
```

---

## Step 7: Override Org Policy for Key Creation

Your org enforces `iam.disableServiceAccountKeyCreation` and the managed variant
`iam.managed.disableServiceAccountKeyCreation`, which block SA key generation.
Override both on the seed project only. These overrides are reverted in the
Cleanup section after WIF switchover.

```bash
# Override the legacy constraint on the seed project.
gcloud org-policies set-policy --project="$SEED_PROJECT" /dev/stdin <<EOF
name: projects/${SEED_PROJECT}/policies/iam.disableServiceAccountKeyCreation
spec:
  rules:
    - enforce: false
EOF

# Override the managed constraint on the seed project.
# This is the newer version that takes precedence over the legacy one.
gcloud org-policies set-policy --project="$SEED_PROJECT" /dev/stdin <<EOF
name: projects/${SEED_PROJECT}/policies/iam.managed.disableServiceAccountKeyCreation
spec:
  rules:
    - enforce: false
EOF

echo "Org policy overrides applied on $SEED_PROJECT"
```

---

## Step 8: Generate Service Account Key

Download a JSON key for the bootstrap SA. This key is what your GHES pipeline
uses to authenticate to GCP for the initial Stage 0 run.

```bash
# Creates a JSON key file containing the SA's private key.
# This is the GCP equivalent of an AWS access key / secret key pair.
# The file is a sensitive credential — treat it like a password.
gcloud iam service-accounts keys create fast-bootstrap-sa-key.json \
  --iam-account="$BOOTSTRAP_SA_EMAIL" \
  --key-file-type=json
```

**This file is sensitive.** Download it from Cloud Shell (three-dot menu → Download), store it as a GHES secret, then delete it:

```bash
# After downloading and storing in GHES as GCP_BOOTSTRAP_SA_KEY:
rm -f fast-bootstrap-sa-key.json
```

---

## Step 9: Configure FAST Defaults

FAST's current `0-org-setup` stage does **not** use a tfvars file for org/billing/prefix
configuration. All of that lives in the dataset's `defaults.yaml`. Edit the file
directly in your repo at `fast/stages/0-org-setup/datasets/hardened/defaults.yaml`:

```yaml
global:
  billing_account: 014F76-ED4E67-7CCCE1       # your billing account ID
  organization:
    domain: gigachadglobal.org                  # your verified domain
    id: 1041701195417                           # your numeric org ID
    customer_id: C02xrlndw                      # from: gcloud organizations describe $ORG_ID --format="value(owner.directoryCustomerId)"
projects:
  defaults:
    prefix: fast                                # lowercase, max 9 chars
    locations:
      bigquery: $locations:primary
      logging: $locations:primary
      storage: $locations:primary
context:
  iam_principals:
    gcp-organization-admins: group:gcp-organization-admins@gigachadglobal.org
  locations:
    primary: us-east4
```

The only tfvars you might need is for importing pre-existing org policies
(if any conflict during the first apply):

```bash
# Only if needed — create fast/stages/0-org-setup/0-org-setup.auto.tfvars
org_policies_imports = [
  "iam.disableServiceAccountKeyCreation",
  "iam.allowedPolicyMemberDomains"
]
```

Commit the edited `defaults.yaml` to your repo. No separate tfvars file is needed.

---

## Step 10: Verify

Confirm everything was created correctly before moving to the pipeline.

```bash
# Verify the org is accessible and print its display name + resource name.
echo "=== Organization ==="
gcloud organizations describe "$ORG_ID" --format="value(displayName, name)"

# Verify the seed project exists and print its ID + numeric project number.
echo ""
echo "=== Seed Project ==="
gcloud projects describe "$SEED_PROJECT" --format="value(projectId, projectNumber)"

# Verify the bootstrap SA exists and print its email.
echo ""
echo "=== Bootstrap SA ==="
gcloud iam service-accounts describe "$BOOTSTRAP_SA_EMAIL" \
  --project="$SEED_PROJECT" --format="value(email)"

# Verify all six required groups exist in Cloud Identity.
# If any print "MISSING", create them manually in admin.google.com.
echo ""
echo "=== Groups ==="
for group in gcp-organization-admins gcp-billing-admins gcp-network-admins \
  gcp-security-admins gcp-logging-admins gcp-devops; do
  gcloud identity groups describe "${group}@${DOMAIN}" \
    --format="value(groupKey.id)" 2>/dev/null \
    && true || echo "MISSING: ${group}@${DOMAIN}"
done

# List all org-level IAM roles currently granted to the bootstrap SA.
# You should see all 13 roles from Step 5.
echo ""
echo "=== SA Org Roles ==="
gcloud organizations get-iam-policy "$ORG_ID" \
  --flatten="bindings[].members" \
  --filter="bindings.members:$BOOTSTRAP_SA_EMAIL" \
  --format="table(bindings.role)"
```

---

## Next Steps

1. **Store the SA key in GHES** as secret `GCP_BOOTSTRAP_SA_KEY`
2. **Copy `0-org-setup.auto.tfvars`** into your repo at `fast/stages/0-org-setup/`
3. **Copy the `fast-stage-0.yml` workflow** into `.github/workflows/`
4. **Push to main** — Stage 0 runs via the pipeline
5. **After Stage 0 succeeds**, migrate state to GCS (follow terraform output)
6. **Add WIF config** to tfvars, re-apply Stage 0, switch workflow to WIF
7. **Destroy bootstrap SA** — run the cleanup commands below

---

## Cleanup (After WIF Switchover)

Run this **only after** WIF is confirmed working and the SA key is removed from GHES:

```bash
# Re-set variables if you're in a new Cloud Shell session.
export FAST_PREFIX="fast"
export BOOTSTRAP_SA_EMAIL="fast-bootstrap@${FAST_PREFIX}-seed-bootstrap.iam.gserviceaccount.com"
export SEED_PROJECT="${FAST_PREFIX}-seed-bootstrap"
export ORG_ID="1041701195417"
export BILLING_ACCOUNT_ID="014F76-ED4E67-7CCCE1"

# Remove all org-level IAM roles from the bootstrap SA.
# remove-iam-policy-binding is the inverse of add-iam-policy-binding.
# "|| true" ensures the script continues even if a binding doesn't exist.
for role in \
  roles/resourcemanager.organizationAdmin \
  roles/resourcemanager.projectCreator \
  roles/resourcemanager.folderAdmin \
  roles/iam.organizationRoleAdmin \
  roles/iam.securityAdmin \
  roles/iam.serviceAccountAdmin \
  roles/orgpolicy.policyAdmin \
  roles/logging.configWriter \
  roles/compute.networkAdmin \
  roles/compute.xpnAdmin \
  roles/resourcemanager.tagAdmin \
  roles/accesscontextmanager.policyAdmin \
  roles/resourcemanager.organizationViewer; do
  gcloud organizations remove-iam-policy-binding "$ORG_ID" \
    --member="serviceAccount:$BOOTSTRAP_SA_EMAIL" \
    --role="$role" --quiet 2>/dev/null || true
done

# Remove billing IAM roles from the bootstrap SA.
for role in roles/billing.admin roles/billing.user; do
  gcloud billing accounts remove-iam-policy-binding "$BILLING_ACCOUNT_ID" \
    --member="serviceAccount:$BOOTSTRAP_SA_EMAIL" \
    --role="$role" --quiet 2>/dev/null || true
done

# Revert the org policy overrides on the seed project.
# This restores inheritance from the org-level policy (enforce: true).
gcloud org-policies reset iam.disableServiceAccountKeyCreation \
  --project="$SEED_PROJECT" 2>/dev/null || true
gcloud org-policies reset iam.managed.disableServiceAccountKeyCreation \
  --project="$SEED_PROJECT" 2>/dev/null || true
echo "Org policy overrides reverted on $SEED_PROJECT"

# Permanently delete the bootstrap service account.
# This also invalidates any existing keys — the GHES secret becomes useless.
gcloud iam service-accounts delete "$BOOTSTRAP_SA_EMAIL" \
  --project="$SEED_PROJECT" --quiet

# Delete the seed project. FAST created its own iac-0 project in Stage 0,
# so this project is no longer needed.
gcloud projects delete "$SEED_PROJECT" --quiet
echo "Seed project $SEED_PROJECT deleted"
```
