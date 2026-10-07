#!/usr/bin/env bash
# validate.sh — Post-deploy health checks for the MTA Agents stack.
#
# Checks:
#   1. Agent Sandbox Operator CSV is Succeeded.
#   2. MTA Operator CSV is Succeeded.
#   3. Tackle CR is Ready.
#   4. agentic-controller Deployment is Ready.
#   5. Default MTA Agents are Ready (migration-plan, migration-execute, migration-verify).
#   6. Gateway CR qwen-external is Verified.
#
# Usage:
#   ./validate.sh              — run all checks (exits 1 if any fail)
#   ./validate.sh --no-exit    — run all checks and print summary without exiting
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"

NO_EXIT=false
[[ "${1:-}" == "--no-exit" ]] && NO_EXIT=true

load_env
check_cluster

PASS=0
FAIL=0
WARN=0

ok()   { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }
warn() { echo "  [WARN] $*"; WARN=$((WARN + 1)); }

# ─── Check 1: Agent Sandbox Operator ───────────────────────────────────────
print_separator "Check 1: Agent Sandbox Operator"
SANDBOX_CSV_PHASE="$(oc get csv -n agent-sandbox-system --no-headers 2>/dev/null \
  | grep -i "agent-sandbox" | awk '{print $NF}' | head -1 || echo "")"
if [[ "${SANDBOX_CSV_PHASE}" == "Succeeded" ]]; then
  ok "Agent Sandbox Operator CSV: Succeeded"
elif [[ -z "${SANDBOX_CSV_PHASE}" ]]; then
  fail "Agent Sandbox Operator CSV not found in agent-sandbox-system."
  echo "       Check: oc get csv -n agent-sandbox-system"
  echo "       Check: oc get subscription agent-sandbox-operator -n agent-sandbox-system"
else
  fail "Agent Sandbox Operator CSV phase: ${SANDBOX_CSV_PHASE} (expected Succeeded)"
fi

# ─── Check 2: MTA Operator ─────────────────────────────────────────────────
print_separator "Check 2: MTA Operator"
MTA_CSV_PHASE="$(oc get csv -n openshift-mta --no-headers 2>/dev/null \
  | grep -i "mta-operator" | awk '{print $NF}' | head -1 || echo "")"
if [[ "${MTA_CSV_PHASE}" == "Succeeded" ]]; then
  ok "MTA Operator CSV: Succeeded"
elif [[ -z "${MTA_CSV_PHASE}" ]]; then
  fail "MTA Operator CSV not found in openshift-mta."
  echo "       Check: oc get csv -n openshift-mta"
  echo "       Check: oc get subscription mta-operator -n openshift-mta"
else
  fail "MTA Operator CSV phase: ${MTA_CSV_PHASE} (expected Succeeded)"
fi

# ─── Check 3: Tackle CR readiness ──────────────────────────────────────────
print_separator "Check 3: Tackle CR"
TACKLE_READY="$(oc get tackle mta -n openshift-mta \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")"
if [[ "${TACKLE_READY}" == "True" ]]; then
  ok "Tackle CR mta: Ready"
elif [[ -z "${TACKLE_READY}" ]]; then
  fail "Tackle CR mta not found or no Ready condition yet."
  echo "       Check: oc get tackle mta -n openshift-mta -o yaml"
else
  fail "Tackle CR mta Ready condition: ${TACKLE_READY} (expected True)"
  echo "       Check: oc get tackle mta -n openshift-mta -o jsonpath='{.status.conditions}'"
fi

# ─── Check 4: agentic-controller Deployment ────────────────────────────────
print_separator "Check 4: agentic-controller Deployment"
AGENTIC_READY="$(oc get deployment agentic-controller -n openshift-mta \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")"
AGENTIC_DESIRED="$(oc get deployment agentic-controller -n openshift-mta \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")"
if [[ -z "${AGENTIC_DESIRED}" ]]; then
  fail "agentic-controller Deployment not found."
  echo "       This Deployment is created by the operator after agentic_enabled is set."
  echo "       Verify: oc get tackle mta -n openshift-mta -o jsonpath='{.spec.agentic_enabled}'"
  echo "       Check:  oc get deployments -n openshift-mta"
elif [[ "${AGENTIC_READY}" == "${AGENTIC_DESIRED}" && -n "${AGENTIC_READY}" ]]; then
  ok "agentic-controller Deployment: ${AGENTIC_READY}/${AGENTIC_DESIRED} Ready"
else
  fail "agentic-controller Deployment: ${AGENTIC_READY:-0}/${AGENTIC_DESIRED} Ready"
  echo "       Check: oc logs -n openshift-mta deploy/agentic-controller"
fi

# ─── Check 5: Default MTA Agents ───────────────────────────────────────────
print_separator "Check 5: Default MTA Agents"
DEFAULT_AGENTS=("migration-plan-agent" "migration-execute-agent" "migration-verify-agent")
AGENTS_FOUND=false
for AGENT_NAME in "${DEFAULT_AGENTS[@]}"; do
  AGENT_READY="$(oc get agents.konveyor.io "${AGENT_NAME}" -n openshift-mta \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")"
  if [[ "${AGENT_READY}" == "True" ]]; then
    ok "Agent ${AGENT_NAME}: Ready"
    AGENTS_FOUND=true
  elif [[ -z "${AGENT_READY}" ]]; then
    warn "Agent ${AGENT_NAME}: not found yet (may still be installing)."
    echo "       Check: oc get agents.konveyor.io -n openshift-mta"
  else
    fail "Agent ${AGENT_NAME}: Ready=${AGENT_READY}"
    echo "       Check: oc get agents.konveyor.io ${AGENT_NAME} -n openshift-mta -o yaml"
  fi
done
if [[ "${AGENTS_FOUND}" == "false" ]]; then
  echo "       NOTE: Agents are installed by the operator when agentic_enabled is true."
  echo "             They appear after the agentic-controller is Running."
fi

# ─── Check 6: Gateway CR ───────────────────────────────────────────────────
print_separator "Check 6: Gateway CR qwen-external"
GW_EXISTS="$(oc get gateway.konveyor.io qwen-external -n openshift-mta \
  --ignore-not-found=true -o name 2>/dev/null || echo "")"
if [[ -z "${GW_EXISTS}" ]]; then
  fail "Gateway CR qwen-external not found in openshift-mta."
  echo "       The Gateway CRD is registered only after agentic_enabled takes effect."
  echo "       Check: oc get crd gateways.konveyor.io"
  echo "       Check: oc get gateways.konveyor.io -n openshift-mta"
else
  GW_VERIFIED="$(oc get gateway.konveyor.io qwen-external -n openshift-mta \
    -o jsonpath='{.status.verified}' 2>/dev/null || echo "false")"
  GW_ENDPOINT="$(oc get gateway.konveyor.io qwen-external -n openshift-mta \
    -o jsonpath='{.spec.endpoint}' 2>/dev/null || echo "")"
  GW_MODEL="$(oc get gateway.konveyor.io qwen-external -n openshift-mta \
    -o jsonpath='{.spec.model.name}' 2>/dev/null || echo "")"
  if [[ "${GW_VERIFIED}" == "true" ]]; then
    ok "Gateway qwen-external: Verified (endpoint: ${GW_ENDPOINT}, model: ${GW_MODEL})"
  else
    fail "Gateway qwen-external: Verified=${GW_VERIFIED} (expected true)"
    echo "       Endpoint : ${GW_ENDPOINT}"
    echo "       Model    : ${GW_MODEL}"
    echo "       Check endpoint URL and API key, then:"
    echo "         oc logs -n openshift-mta deploy/agentic-controller"
  fi
fi

# ─── Check 7: mta-qwen-credentials Secret ──────────────────────────────────
print_separator "Check 7: mta-qwen-credentials Secret"
SECRET_EXISTS="$(oc get secret mta-qwen-credentials -n openshift-mta \
  --ignore-not-found=true -o name 2>/dev/null || echo "")"
if [[ -n "${SECRET_EXISTS}" ]]; then
  ok "Secret mta-qwen-credentials exists in openshift-mta."
else
  fail "Secret mta-qwen-credentials not found in openshift-mta."
  echo "       Run deploy.sh to provision it, or:"
  echo "         oc create secret generic mta-qwen-credentials \\"
  echo "           -n openshift-mta --from-literal=api-key=<your-api-key>"
fi

# ─── Summary ────────────────────────────────────────────────────────────────
print_separator "Validation summary"
echo "  PASS: ${PASS}"
echo "  FAIL: ${FAIL}"
echo "  WARN: ${WARN}"
echo ""

if [[ ${FAIL} -gt 0 ]]; then
  echo "Some checks failed. Review the output above for remediation steps."
  echo ""
  echo "Common troubleshooting commands:"
  echo "  oc get csv -n openshift-mta"
  echo "  oc get csv -n agent-sandbox-system"
  echo "  oc get tackle mta -n openshift-mta -o yaml"
  echo "  oc get deployments -n openshift-mta"
  echo "  oc get gateways.konveyor.io -n openshift-mta"
  echo "  oc logs -n openshift-mta deploy/agentic-controller"
  echo "  oc get application mta-agents -n openshift-gitops -o yaml"
  if [[ "${NO_EXIT}" == "false" ]]; then
    exit 1
  fi
else
  MTA_HOST="$(oc get route mta -n openshift-mta -o jsonpath='{.spec.host}' 2>/dev/null || echo "")"
  echo "All checks passed. The MTA Agents stack is healthy."
  if [[ -n "${MTA_HOST}" ]]; then
    echo ""
    echo "  MTA URL: https://${MTA_HOST}"
  fi
fi
