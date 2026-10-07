#!/usr/bin/env bash
# deploy.sh — Deploy the MTA Agents stack.
#
# Flow:
#   1. Load .env and run the cluster safety guard.
#   2. Install the OpenShift GitOps operator (bootstrap).
#   3. Wait for Argo CD to become Available.
#   4. Apply the Argo CD instance and AppProject.
#   5. Provision the mta-qwen-credentials Secret from .env values.
#   6. Apply the Argo CD Application (with GIT_REPO_URL / GIT_REPO_BRANCH
#      and Qwen env vars substituted).
#   7. Patch the ConsoleLink to the live MTA route (best-effort, after sync).
#
# Prerequisites:
#   - oc CLI authenticated as cluster-admin
#   - envsubst (gettext-tools) — brew install gettext / dnf install gettext
#   - .env filled in from env.example
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"

# ─── Step 0: Load environment and check cluster ────────────────────────────
print_separator "Step 0: Loading environment"
load_env
check_cluster

# ─── Step 1: Bootstrap OpenShift GitOps operator ──────────────────────────
print_separator "Step 1: Bootstrapping OpenShift GitOps operator"
oc apply -k "${SCRIPT_DIR}/gitops/bootstrap/base"
echo "Subscription applied. Waiting for OpenShift GitOps CSV..."

# Wait for the GitOps operator CSV to succeed (up to 5 minutes)
wait_for_csv "openshift-operators" "gitops" 300

# ─── Step 2: Wait for Argo CD instance ────────────────────────────────────
print_separator "Step 2: Waiting for Argo CD to become Available"
# The operator creates a default ArgoCD CR in openshift-gitops automatically.
# Wait up to 5 minutes for it, then apply our customised instance.
elapsed=0
until oc get argocd openshift-gitops -n openshift-gitops &>/dev/null; do
  if [[ ${elapsed} -ge 120 ]]; then
    echo "ERROR: ArgoCD CR not created by the operator after 2 minutes."
    exit 1
  fi
  sleep 10
  elapsed=$((elapsed + 10))
  echo "  Waiting for ArgoCD CR... (${elapsed}s)"
done
oc apply -f "${SCRIPT_DIR}/gitops/argocd/argocd-instance.yaml"
wait_for_argocd 300

# ─── Step 3: Apply Argo CD AppProject ─────────────────────────────────────
print_separator "Step 3: Applying Argo CD AppProject"
oc apply -f "${SCRIPT_DIR}/gitops/argocd/argocd-project.yaml"

# ─── Step 4: Provision LLM credential Secret ──────────────────────────────
print_separator "Step 4: Provisioning mta-qwen-credentials Secret"

# Ensure the openshift-mta namespace exists before creating the secret.
# Argo CD will also create it, but we need it now.
oc create namespace openshift-mta --dry-run=client -o yaml | oc apply -f -

QWEN_API_KEY="${QWEN_API_KEY:-}"
if [[ -z "${QWEN_API_KEY}" ]]; then
  echo "QWEN_API_KEY is empty — creating Secret with empty api-key value."
  echo "The Gateway CR will still reference it; the endpoint is assumed unauthenticated."
fi

oc create secret generic mta-qwen-credentials \
  -n openshift-mta \
  --from-literal=api-key="${QWEN_API_KEY}" \
  --dry-run=client -o yaml | oc apply -f -

echo "Secret mta-qwen-credentials is ready in openshift-mta."

# ─── Step 5: Apply Argo CD Application (with env substitution) ────────────
print_separator "Step 5: Applying Argo CD Application"

# Validate required Qwen variables
: "${GIT_REPO_URL:?GIT_REPO_URL must be set in .env}"
: "${GIT_REPO_BRANCH:?GIT_REPO_BRANCH must be set in .env}"
: "${QWEN_ENDPOINT_URL:?QWEN_ENDPOINT_URL must be set in .env}"
: "${QWEN_MODEL_ID:?QWEN_MODEL_ID must be set in .env}"
: "${QWEN_CONTEXT_WINDOW:?QWEN_CONTEXT_WINDOW must be set in .env}"

# Substitute env vars into the Argo CD Application manifest (GIT_REPO_URL,
# GIT_REPO_BRANCH) and apply.
envsubst '${GIT_REPO_URL} ${GIT_REPO_BRANCH}' \
  < "${SCRIPT_DIR}/gitops/argocd/mta-agents.yaml" \
  | oc apply -f -

echo "Argo CD Application 'mta-agents' applied."
echo "Argo CD will now sync the MTA stack from ${GIT_REPO_URL} (${GIT_REPO_BRANCH})."
echo ""
echo "NOTE: The Gateway CR in git contains placeholder values."
echo "  Argo CD will apply those placeholders first, then you must patch the"
echo "  live resource (or push the substituted manifest to your fork)."
echo ""
echo "  To patch the Gateway CR directly on the cluster:"
cat <<PATCH
  oc patch gateway.konveyor.io qwen-external -n openshift-mta --type=merge -p '{
    "spec": {
      "endpoint": "${QWEN_ENDPOINT_URL}",
      "model": {
        "name": "${QWEN_MODEL_ID}",
        "contextWindow": ${QWEN_CONTEXT_WINDOW}
      }
    }
  }'
PATCH

# ─── Step 6: Apply Gateway CR directly (server-side, to seed real values) ──
print_separator "Step 6: Applying Gateway CR with real Qwen endpoint values"
echo "Waiting for gateways.konveyor.io CRD to become available..."
echo "(This may take several minutes while the MTA operator installs.)"

elapsed=0
while ! oc get crd gateways.konveyor.io &>/dev/null; do
  if [[ ${elapsed} -ge 600 ]]; then
    echo ""
    echo "WARNING: gateways.konveyor.io CRD not available after 10 minutes."
    echo "  The Gateway CR will be applied by Argo CD once the CRD is registered."
    echo "  Once the MTA operator is running, manually apply:"
    echo "    envsubst < gitops/stages/mta-agents/llm-gateway/gateway.yaml | oc apply -f -"
    break
  fi
  sleep 15
  elapsed=$((elapsed + 15))
  echo "  Waiting for CRD... (${elapsed}s / 600s)"
done

if oc get crd gateways.konveyor.io &>/dev/null; then
  envsubst '${QWEN_ENDPOINT_URL} ${QWEN_MODEL_ID} ${QWEN_CONTEXT_WINDOW}' \
    < "${SCRIPT_DIR}/gitops/stages/mta-agents/llm-gateway/gateway.yaml" \
    | oc apply --server-side --force-conflicts \
        --field-manager=mta-agents-deploy -f -
  echo "Gateway CR qwen-external applied with real endpoint values."
fi

# ─── Step 7: Patch ConsoleLink to the live MTA route (best-effort) ─────────
print_separator "Step 7: Patching ConsoleLink (best-effort)"
MTA_HOST=""
for i in $(seq 1 12); do
  MTA_HOST="$(oc get route mta -n openshift-mta -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  [[ -n "${MTA_HOST}" ]] && break
  echo "  Waiting for MTA route... (${i}/12)"
  sleep 15
done

if [[ -n "${MTA_HOST}" ]]; then
  oc patch consolelink mta --type=merge \
    -p "{\"spec\":{\"href\":\"https://${MTA_HOST}\",\"applicationMenu\":{\"imageURL\":\"https://${MTA_HOST}/favicon.ico\"}}}" \
    2>/dev/null && echo "ConsoleLink patched: https://${MTA_HOST}" || true
else
  echo "MTA route not yet available. Patch the ConsoleLink manually once the instance is Ready:"
  echo "  MTA_HOST=\$(oc get route mta -n openshift-mta -o jsonpath='{.spec.host}')"
  echo "  oc patch consolelink mta --type=merge -p \"{\\\"spec\\\":{\\\"href\\\":\\\"https://\${MTA_HOST}\\\"}}\""
fi

# ─── Done ───────────────────────────────────────────────────────────────────
print_separator "Deployment complete"
echo ""
echo "Next steps:"
echo "  1. Run ./validate.sh to verify all components are healthy."
echo "  2. Retrieve the MTA admin password:"
echo "       oc get secret -n openshift-mta | grep -i admin"
echo "       oc get secret <secret-name> -n openshift-mta -o jsonpath='{.data.password}' | base64 -d"
echo "  3. Open the MTA console from the OpenShift launcher menu."
echo "  4. Add source control credentials and applications in the MTA UI."
echo ""
if [[ -n "${MTA_HOST:-}" ]]; then
  echo "  MTA URL: https://${MTA_HOST}"
fi
echo ""
echo "  Argo CD UI: $(oc get route openshift-gitops-server -n openshift-gitops \
  -o jsonpath='https://{.spec.host}' 2>/dev/null || echo '<oc get route openshift-gitops-server -n openshift-gitops>')"
