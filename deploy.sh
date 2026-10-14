#!/usr/bin/env bash
# deploy.sh — Deploy the MTA Agents stack + GitLab CE instance.
#
# Flow:
#   1. Load .env and run the cluster safety guard.
#   2. Install the OpenShift GitOps operator (bootstrap).
#   3. Wait for Argo CD to become Available.
#   4. Apply the Argo CD instance and AppProject.
#   5. Provision the mta-qwen-credentials Secret from .env values.
#   6. Apply the mta-agents Argo CD Application (with GIT_REPO_URL /
#      GIT_REPO_BRANCH substituted).
#   7. Patch the Gateway CR on the cluster with real Qwen endpoint values.
#   8. Provision the gitlab-initial-root-password Secret from .env values.
#   9. Apply the gitlab Argo CD Application.
#  10. Patch the ConsoleLink to the live MTA route (best-effort, after sync).
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

# ─── Step 4: Provision LLM gateway credentials Secrets ────────────────────
print_separator "Step 4: Provisioning LLM gateway credential Secrets"

# Ensure the openshift-mta namespace exists before creating secrets.
# Argo CD will also create it, but we need it now.
oc create namespace openshift-mta --dry-run=client -o yaml | oc apply -f -

# Validate at least one gateway is defined.
name_var="GATEWAY_1_NAME"
: "${!name_var:?GATEWAY_1_NAME must be set in .env (at least one gateway is required)}"

# Loop over GATEWAY_N_* indexed vars; stop at the first gap in numbering.
gw_index=1
while true; do
  gw_name_var="GATEWAY_${gw_index}_NAME"
  GW_NAME="${!gw_name_var:-}"
  [[ -z "${GW_NAME}" ]] && break

  gw_key_var="GATEWAY_${gw_index}_API_KEY"
  GW_API_KEY="${!gw_key_var:-}"

  if [[ -z "${GW_API_KEY}" ]]; then
    echo "  [${GW_NAME}] GATEWAY_${gw_index}_API_KEY is empty — Secret will have an empty api-key (unauthenticated endpoint)."
  fi

  oc create secret generic "${GW_NAME}-credentials" \
    -n openshift-mta \
    --from-literal=api-key="${GW_API_KEY}" \
    --dry-run=client -o yaml | oc apply -f -

  echo "  [${GW_NAME}] Secret ${GW_NAME}-credentials is ready in openshift-mta."
  gw_index=$((gw_index + 1))
done
echo "Provisioned credentials for $((gw_index - 1)) gateway(s)."

# ─── Step 5: Apply Argo CD Application (with env substitution) ────────────
print_separator "Step 5: Applying Argo CD Application"

: "${GIT_REPO_URL:?GIT_REPO_URL must be set in .env}"
: "${GIT_REPO_BRANCH:?GIT_REPO_BRANCH must be set in .env}"

# Substitute env vars into the Argo CD Application manifest and apply.
envsubst '${GIT_REPO_URL} ${GIT_REPO_BRANCH}' \
  < "${SCRIPT_DIR}/gitops/argocd/mta-agents.yaml" \
  | oc apply -f -

echo "Argo CD Application 'mta-agents' applied."
echo "Argo CD will now sync the MTA stack from ${GIT_REPO_URL} (${GIT_REPO_BRANCH})."

# ─── Step 6: Apply Gateway CRs for all configured gateways ─────────────────
print_separator "Step 6: Applying Gateway CRs from .env"
echo "Waiting for gateways.konveyor.io CRD to become available..."
echo "(This may take several minutes while the MTA operator installs.)"

elapsed=0
while ! oc get crd gateways.konveyor.io &>/dev/null; do
  if [[ ${elapsed} -ge 600 ]]; then
    echo ""
    echo "WARNING: gateways.konveyor.io CRD not available after 10 minutes."
    echo "  Once the MTA operator is running, re-run this step manually:"
    echo "    bash deploy.sh  (idempotent — already-applied resources are skipped)"
    break
  fi
  sleep 15
  elapsed=$((elapsed + 15))
  echo "  Waiting for CRD... (${elapsed}s / 600s)"
done

if oc get crd gateways.konveyor.io &>/dev/null; then
  gw_index=1
  while true; do
    gw_name_var="GATEWAY_${gw_index}_NAME"
    GW_NAME="${!gw_name_var:-}"
    [[ -z "${GW_NAME}" ]] && break

    gw_endpoint_var="GATEWAY_${gw_index}_ENDPOINT"
    GW_ENDPOINT="${!gw_endpoint_var}"
    : "${GW_ENDPOINT:?GATEWAY_${gw_index}_ENDPOINT must be set in .env}"

    gw_model_var="GATEWAY_${gw_index}_MODEL_ID"
    GW_MODEL_ID="${!gw_model_var}"
    : "${GW_MODEL_ID:?GATEWAY_${gw_index}_MODEL_ID must be set in .env}"

    gw_ctx_var="GATEWAY_${gw_index}_CONTEXT_WINDOW"
    GW_CONTEXT_WINDOW="${!gw_ctx_var:-131072}"

    gw_tier_var="GATEWAY_${gw_index}_TIER"
    GW_TIER="${!gw_tier_var:-standard}"

    export GW_NAME GW_ENDPOINT GW_MODEL_ID GW_CONTEXT_WINDOW GW_TIER
    envsubst '${GW_NAME} ${GW_ENDPOINT} ${GW_MODEL_ID} ${GW_CONTEXT_WINDOW} ${GW_TIER}' \
      < "${SCRIPT_DIR}/gitops/stages/mta-agents/llm-gateway/gateway-template.yaml" \
      | oc apply --server-side --force-conflicts \
          --field-manager=mta-agents-deploy -f -

    echo "  [${GW_NAME}] Gateway CR applied (endpoint: ${GW_ENDPOINT}, model: ${GW_MODEL_ID})."
    gw_index=$((gw_index + 1))
  done
  echo "Applied $((gw_index - 1)) Gateway CR(s)."
fi

# ─── Step 8: Provision GitLab root password Secret ─────────────────────────
print_separator "Step 8: Provisioning gitlab-initial-root-password Secret"

GITLAB_ROOT_PASSWORD="${GITLAB_ROOT_PASSWORD:-}"
if [[ -z "${GITLAB_ROOT_PASSWORD}" ]]; then
  echo "ERROR: GITLAB_ROOT_PASSWORD is not set in .env."
  echo "  Set it and re-run deploy.sh, or create the Secret manually:"
  echo "    oc create secret generic gitlab-initial-root-password -n gitlab \\"
  echo "      --from-literal=password=<your-password>"
  exit 1
fi

# Ensure the gitlab namespace exists before creating the secret.
oc create namespace gitlab --dry-run=client -o yaml | oc apply -f -

oc create secret generic gitlab-initial-root-password \
  -n gitlab \
  --from-literal=password="${GITLAB_ROOT_PASSWORD}" \
  --dry-run=client -o yaml | oc apply -f -

echo "Secret gitlab-initial-root-password is ready in gitlab."

# ─── Step 9: Apply GitLab Argo CD Application ───────────────────────────────
print_separator "Step 9: Applying GitLab Argo CD Application"

envsubst '${GIT_REPO_URL} ${GIT_REPO_BRANCH}' \
  < "${SCRIPT_DIR}/gitops/argocd/gitlab.yaml" \
  | oc apply -f -

echo "Argo CD Application 'gitlab' applied."
echo "Argo CD will now sync the GitLab CE stack from ${GIT_REPO_URL} (${GIT_REPO_BRANCH})."
echo ""
echo "NOTE: The GitLab operator may take 10-15 minutes to install; the GitLab"
echo "  instance will start only after the apps.gitlab.com CRD is registered."
echo "  Monitor progress with:"
echo "    oc get csv -n gitlab-system"
echo "    oc get gitlab -n gitlab"
echo ""

# ─── Step 10: Patch ConsoleLink to the live MTA route (best-effort) ─────────
print_separator "Step 10: Patching ConsoleLink (best-effort)"
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
echo "  1. Run ./validate.sh to verify all MTA components are healthy."
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
echo "  GitLab CE (once the operator finishes installing):"
echo "    oc get route -n gitlab | grep webservice"
echo "    Login: root / \${GITLAB_ROOT_PASSWORD}"
echo "    Sign-up is DISABLED; create users via Admin > Users."
echo ""
echo "  Argo CD UI: $(oc get route openshift-gitops-server -n openshift-gitops \
  -o jsonpath='https://{.spec.host}' 2>/dev/null || echo '<oc get route openshift-gitops-server -n openshift-gitops>')"
