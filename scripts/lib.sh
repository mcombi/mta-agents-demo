#!/usr/bin/env bash
# Shared helper functions for deploy.sh and validate.sh.
# Source this file; do not execute it directly.
set -euo pipefail

# ─── Environment loading ────────────────────────────────────────────────────

load_env() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local env_file="${script_dir}/.env"
  if [[ -f "${env_file}" ]]; then
    # Export all variables defined in .env, ignoring comments and blank lines
    set -o allexport
    # shellcheck disable=SC1090
    source "${env_file}"
    set +o allexport
  else
    echo "WARNING: .env not found — using environment variables as-is."
    echo "         Copy env.example to .env and fill in the values."
  fi
}

# ─── Safety guard ──────────────────────────────────────────────────────────

check_cluster() {
  if [[ -z "${RHOAI_EXPECTED_API_SERVER:-}" ]]; then
    echo "WARNING: RHOAI_EXPECTED_API_SERVER is not set — skipping cluster guard."
    return
  fi
  local current_server
  current_server="$(oc whoami --show-server 2>/dev/null || true)"
  if [[ "${current_server}" != *"${RHOAI_EXPECTED_API_SERVER}"* ]]; then
    echo "ERROR: Current API server does not match RHOAI_EXPECTED_API_SERVER."
    echo "  Expected substring : ${RHOAI_EXPECTED_API_SERVER}"
    echo "  Current server     : ${current_server}"
    echo "  Run: oc login ${OPENSHIFT_API_URL:-<cluster-api-url>}"
    exit 1
  fi
  echo "Cluster guard passed: ${current_server}"
}

# ─── Waiting helpers ────────────────────────────────────────────────────────

wait_for_csv() {
  local namespace="$1"
  local name_pattern="$2"
  local timeout="${3:-300}"
  local elapsed=0
  echo "Waiting for CSV matching '${name_pattern}' in ${namespace} to succeed..."
  while [[ ${elapsed} -lt ${timeout} ]]; do
    local phase
    # grep by CSV name (first column) then read the phase (last column)
    phase="$(oc get csv -n "${namespace}" --no-headers 2>/dev/null \
      | grep -i "${name_pattern}" | awk '{print $NF}' | head -1 || true)"
    if [[ "${phase}" == "Succeeded" ]]; then
      echo "  CSV ${name_pattern} is Succeeded."
      return 0
    fi
    sleep 10
    elapsed=$((elapsed + 10))
    echo "  Waiting... (${elapsed}s / ${timeout}s) current phase: ${phase:-unknown}"
  done
  echo "ERROR: Timed out waiting for CSV ${name_pattern} in ${namespace}."
  return 1
}

wait_for_deployment() {
  local namespace="$1"
  local name="$2"
  local timeout="${3:-300}"
  echo "Waiting for deployment ${namespace}/${name}..."
  oc rollout status deployment/"${name}" \
    -n "${namespace}" \
    --timeout="${timeout}s"
}

wait_for_argocd() {
  local timeout="${1:-300}"
  local elapsed=0
  echo "Waiting for Argo CD openshift-gitops to become available..."
  while [[ ${elapsed} -lt ${timeout} ]]; do
    local ready
    ready="$(oc get argocd openshift-gitops -n openshift-gitops \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "${ready}" == "Available" ]]; then
      echo "  Argo CD is Available."
      return 0
    fi
    sleep 10
    elapsed=$((elapsed + 10))
    echo "  Waiting... (${elapsed}s / ${timeout}s) phase: ${ready:-pending}"
  done
  echo "ERROR: Timed out waiting for Argo CD to become Available."
  return 1
}

# ─── Printing helpers ────────────────────────────────────────────────────────

print_separator() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo "  $*"
  echo "═══════════════════════════════════════════════════════════════════"
}
