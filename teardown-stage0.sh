#!/bin/bash
# =============================================================================
# FAST Stage 0 — Complete Teardown (based on fast/stages/CLEANUP.md)
#
# Prerequisites:
#   1. Download the fast-stage-0-tfstate artifact from your latest GHA run
#   2. Place terraform.tfstate in fast/stages/0-org-setup/
#   3. Have Terraform 1.12.2 installed locally
#   4. Be authenticated (gcloud auth application-default login or SA key)
#
# Run from the repo root.
# =============================================================================
set -euo pipefail

STAGE_DIR="fast/stages/0-org-setup"
export ORG_ID="1041701195417"
export BILLING_ACCOUNT_ID="014F76-ED4E67-7CCCE1"
export SEED_PROJECT="fast-seed-bootstrap"
export BOOTSTRAP_SA_EMAIL="fast-bootstrap@${SEED_PROJECT}.iam.gserviceaccount.com"

echo "=== Step 0: Verify state file exists ==="
if [ ! -f "$STAGE_DIR/terraform.tfstate" ]; then
  echo "ERROR: No terraform.tfstate found in $STAGE_DIR"
  echo "Download the fast-stage-0-tfstate artifact from GHA and place it there."
  exit 1
fi

echo "=== Step 1: Create bootstrap provider config ==="
cat > "$STAGE_DIR/provider-bootstrap.tf" <<'EOF'
provider "google" {}
provider "google-beta" {}
EOF

echo "=== Step 2: Terraform init ==="
cd "$STAGE_DIR"
terraform init

echo "=== Step 3: Grant bootstrap user permissions for destroy ==="
FAST_BU=$(gcloud config list --format 'value(core.account)')
echo "Current user: $FAST_BU"
echo "Running terraform apply with bootstrap_user to grant destroy permissions..."
terraform apply -var bootstrap_user="$FAST_BU" -auto-approve || true

echo ""
echo "=== Step 4: Remove resources from state that block destroy ==="
echo "Removing GCS buckets (Terraform can't delete non-empty buckets)..."
for x in $(terraform state list | grep google_storage_bucket.bucket 2>/dev/null); do
  echo "  state rm: $x"
  terraform state rm "$x" 2>/dev/null || true
done

echo "Removing managed folders..."
for x in $(terraform state list | grep google_storage_managed_folder.folder 2>/dev/null); do
  echo "  state rm: $x"
  terraform state rm "$x" 2>/dev/null || true
done

echo "Removing BigQuery datasets..."
for x in $(terraform state list | grep google_bigquery_dataset 2>/dev/null); do
  echo "  state rm: $x"
  terraform state rm "$x" 2>/dev/null || true
done

echo "Removing log bucket configs..."
for x in $(terraform state list | grep google_logging_project_bucket_config 2>/dev/null); do
  echo "  state rm: $x"
  terraform state rm "$x" 2>/dev/null || true
done

echo "Removing custom constraints from state (can't recreate with same name if destroyed)..."
for x in $(terraform state list | grep google_org_policy_custom_constraint 2>/dev/null); do
  echo "  state rm: $x"
  terraform state rm "$x" 2>/dev/null || true
done

echo ""
echo "=== Step 5: First terraform destroy ==="
echo "This will likely fail — that's expected. Continue to Step 6."
terraform destroy -auto-approve || true

echo ""
echo "=== Step 6: Grant additional roles for cleanup ==="
echo "Granting projectDeleter, owner, organizationAdmin to $FAST_BU..."
for role in roles/resourcemanager.projectDeleter roles/owner roles/resourcemanager.organizationAdmin; do
  gcloud organizations add-iam-policy-binding "$ORG_ID" \
    --member "user:$FAST_BU" --role "$role" --condition None --quiet 2>/dev/null || true
done

echo ""
echo "=== Step 7: Second terraform destroy ==="
terraform destroy -auto-approve || true

echo ""
echo "=== Step 8: Clean up local state ==="
rm -f terraform.tfstate terraform.tfstate.backup
rm -f provider-bootstrap.tf

echo ""
echo "=== Step 9: Clean up orphaned custom constraints ==="
echo "These were removed from state (not destroyed) to avoid the 30-day name cooldown."
echo "Deleting them from GCP now..."
CONSTRAINTS=$(gcloud org-policies list-custom-constraints \
  --organization="$ORG_ID" \
  --format="value(name)" 2>/dev/null)
if [ -n "$CONSTRAINTS" ]; then
  echo "$CONSTRAINTS" | while read -r c; do
    SHORT="${c##*/}"
    echo "  Deleting $SHORT..."
    gcloud org-policies delete-custom-constraint "$SHORT" \
      --organization="$ORG_ID" --quiet 2>/dev/null || echo "  (failed)"
  done
else
  echo "  No custom constraints found."
fi

echo ""
echo "=== Step 10: Remove bootstrap SA IAM bindings ==="
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
  roles/resourcemanager.tagUser \
  roles/accesscontextmanager.policyAdmin \
  roles/resourcemanager.organizationViewer \
  roles/securitycentermanagement.admin; do
  gcloud organizations remove-iam-policy-binding "$ORG_ID" \
    --member="serviceAccount:$BOOTSTRAP_SA_EMAIL" \
    --role="$role" --quiet 2>/dev/null || true
done

for role in roles/billing.admin roles/billing.user; do
  gcloud billing accounts remove-iam-policy-binding "$BILLING_ACCOUNT_ID" \
    --member="serviceAccount:$BOOTSTRAP_SA_EMAIL" \
    --role="$role" --quiet 2>/dev/null || true
done

echo ""
echo "=== Step 11: Remove user ad-hoc and destroy IAM bindings ==="
FAST_BU=$(gcloud config list --format 'value(core.account)')
for role in \
  roles/resourcemanager.folderAdmin \
  roles/securitycentermanagement.admin \
  roles/orgpolicy.policyAdmin \
  roles/resourcemanager.projectDeleter \
  roles/owner \
  roles/resourcemanager.organizationAdmin; do
  gcloud organizations remove-iam-policy-binding "$ORG_ID" \
    --member="user:$FAST_BU" \
    --role="$role" --quiet 2>/dev/null || true
done

echo ""
echo "=== Step 12: Reset org policy overrides on seed project ==="
gcloud org-policies reset iam.disableServiceAccountKeyCreation \
  --project="$SEED_PROJECT" 2>/dev/null || true
gcloud org-policies reset iam.managed.disableServiceAccountKeyCreation \
  --project="$SEED_PROJECT" 2>/dev/null || true
gcloud org-policies reset iam.allowedPolicyMemberDomains \
  --project="$SEED_PROJECT" 2>/dev/null || true

echo ""
echo "=== Step 13: Delete bootstrap SA and seed project ==="
gcloud iam service-accounts delete "$BOOTSTRAP_SA_EMAIL" \
  --project="$SEED_PROJECT" --quiet 2>/dev/null || true
gcloud projects delete "$SEED_PROJECT" --quiet 2>/dev/null || true

echo ""
echo "=== Teardown complete ==="
echo ""
echo "IMPORTANT:"
echo "  - Project IDs with prefix 'fast-poc' are in 30-day cooldown"
echo "  - Custom constraint names are in 30-day cooldown"
echo "  - Use a new prefix in defaults.yaml before re-deploying"
echo "  - Delete GCP_BOOTSTRAP_SA_KEY secret from GitHub"
