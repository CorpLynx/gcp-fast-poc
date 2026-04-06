#!/bin/bash
# =============================================================================
# FAST Stage 0 — Complete Teardown
# Run from Cloud Shell as corplynx@gigachadglobal.org
# =============================================================================
set -euo pipefail

export ORG_ID="1041701195417"
export BILLING_ACCOUNT_ID="014F76-ED4E67-7CCCE1"
export SEED_PROJECT="fast-seed-bootstrap"
export BOOTSTRAP_SA_EMAIL="fast-bootstrap@${SEED_PROJECT}.iam.gserviceaccount.com"

echo "=== Phase 1: Terraform Destroy ==="
echo "Download the fast-stage-0-tfstate artifact from your latest GHA run first."
echo "Place terraform.tfstate in fast/stages/0-org-setup/ then run:"
echo ""
echo "  cd fast/stages/0-org-setup"
echo "  cat > provider-bootstrap.tf <<'EOF'"
echo '  provider "google" {}'
echo '  provider "google-beta" {}'
echo "  EOF"
echo "  export GOOGLE_APPLICATION_CREDENTIALS=/path/to/sa-key.json"
echo "  terraform init"
echo "  terraform destroy -auto-approve"
echo ""
echo "If you don't have the SA key, authenticate as yourself:"
echo "  gcloud auth application-default login"
echo "  terraform destroy -auto-approve"
echo ""
read -p "Press Enter after terraform destroy completes (or skip if no state)..."

echo ""
echo "=== Phase 2: Delete custom constraints ==="
CONSTRAINTS=$(gcloud org-policies list-custom-constraints \
  --organization="$ORG_ID" \
  --format="value(name)" 2>/dev/null)
if [ -n "$CONSTRAINTS" ]; then
  echo "$CONSTRAINTS" | while read -r c; do
    CONSTRAINT_SHORT="${c##*/}"
    echo "  Deleting $CONSTRAINT_SHORT..."
    gcloud org-policies delete-custom-constraint "$CONSTRAINT_SHORT" \
      --organization="$ORG_ID" --quiet 2>/dev/null || echo "  (failed)"
  done
else
  echo "  No custom constraints found."
fi

echo ""
echo "=== Phase 3: Delete orphaned folders ==="
gcloud resource-manager folders list \
  --organization="$ORG_ID" \
  --filter="lifecycleState=ACTIVE" \
  --format="value(name,displayName)" 2>/dev/null | while IFS=$'\t' read -r FOLDER_ID FOLDER_NAME; do
    echo "  Deleting folder: $FOLDER_NAME ($FOLDER_ID)..."
    gcloud resource-manager folders delete "$FOLDER_ID" --quiet 2>/dev/null || echo "  (failed — may have children)"
done

echo ""
echo "=== Phase 4: Delete orphaned projects ==="
for prefix in fast-poc fast; do
  gcloud projects list \
    --filter="projectId:${prefix}-prod-* AND lifecycleState=ACTIVE" \
    --format="value(projectId)" 2>/dev/null | while read -r proj; do
      echo "  Deleting project: $proj..."
      gcloud projects delete "$proj" --quiet 2>/dev/null || echo "  (failed)"
  done
done

echo ""
echo "=== Phase 5: Delete orphaned custom roles ==="
gcloud iam roles list --organization="$ORG_ID" \
  --format="value(name)" 2>/dev/null | while read -r role; do
    ROLE_SHORT="${role##*/}"
    echo "  Deleting custom role: $ROLE_SHORT..."
    gcloud iam roles delete "$ROLE_SHORT" --organization="$ORG_ID" \
      --quiet 2>/dev/null || echo "  (failed or already deleted)"
done

echo ""
echo "=== Phase 6: Delete orphaned tag keys and values ==="
for key_short in context environment org-policies; do
  KEY_ID=$(gcloud resource-manager tags keys list \
    --parent="organizations/$ORG_ID" \
    --filter="shortName=$key_short" \
    --format="value(name)" 2>/dev/null)
  if [ -n "$KEY_ID" ]; then
    # Delete values first
    gcloud resource-manager tags values list \
      --parent="$KEY_ID" \
      --format="value(name)" 2>/dev/null | while read -r val_id; do
        echo "  Deleting tag value: $val_id..."
        gcloud resource-manager tags values delete "$val_id" --quiet 2>/dev/null || echo "  (failed)"
    done
    echo "  Deleting tag key: $key_short ($KEY_ID)..."
    gcloud resource-manager tags keys delete "$KEY_ID" --quiet 2>/dev/null || echo "  (failed)"
  fi
done

echo ""
echo "=== Phase 7: Remove bootstrap SA org IAM bindings ==="
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
echo "=== Phase 8: Remove user ad-hoc IAM bindings ==="
for role in \
  roles/resourcemanager.folderAdmin \
  roles/securitycentermanagement.admin \
  roles/orgpolicy.policyAdmin; do
  gcloud organizations remove-iam-policy-binding "$ORG_ID" \
    --member="user:corplynx@gigachadglobal.org" \
    --role="$role" --quiet 2>/dev/null || true
done

echo ""
echo "=== Phase 9: Reset org policy overrides on seed project ==="
gcloud org-policies reset iam.disableServiceAccountKeyCreation \
  --project="$SEED_PROJECT" 2>/dev/null || true
gcloud org-policies reset iam.managed.disableServiceAccountKeyCreation \
  --project="$SEED_PROJECT" 2>/dev/null || true
gcloud org-policies reset iam.allowedPolicyMemberDomains \
  --project="$SEED_PROJECT" 2>/dev/null || true

echo ""
echo "=== Phase 10: Delete bootstrap SA and seed project ==="
gcloud iam service-accounts delete "$BOOTSTRAP_SA_EMAIL" \
  --project="$SEED_PROJECT" --quiet 2>/dev/null || true
gcloud projects delete "$SEED_PROJECT" --quiet 2>/dev/null || true

echo ""
echo "=== Teardown complete ==="
echo ""
echo "IMPORTANT: Project IDs with prefix 'fast-poc' are now in 30-day cooldown."
echo "Use a new prefix (e.g., 'fpoc') in defaults.yaml before re-deploying."
echo ""
echo "Delete the GCP_BOOTSTRAP_SA_KEY secret from GitHub before re-deploying."
