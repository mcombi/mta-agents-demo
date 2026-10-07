# AGENTS.md — MTA Agents Demo

Entry point for AI coding agents working on this repository.

## What this repo is

A minimal GitOps repository that deploys the MTA 8.3 Agentic AI Factory on OpenShift, backed by a self-hosted Qwen model. It is a spin-off of [rhoai3-coding-demo](https://github.com/mcombi/rhoai3-coding-demo/tree/feat/mta-agents-maas) with all dependencies stripped except MTA + Agent Sandbox Operator + a single LLM Gateway CR.

## Repository contract

- **All Kubernetes resources** live under `gitops/stages/mta-agents/` as Kustomize bases.
- **Secrets are never committed.** `deploy.sh` provisions `mta-qwen-credentials` from `.env` at deploy time.
- **Argo CD manages drift.** Do not `oc apply` resources directly that are under Argo CD management — update the manifests in `gitops/` and let Argo CD reconcile.
- **`env.example` is the source of truth** for which environment variables are needed. Keep it in sync with `deploy.sh` and `validate.sh`.
- **Sync waves** follow: namespaces and operators at wave 0–2, Tackle CR at wave 10, Gateway CR at wave 15.

## Key files

| File | Purpose |
|---|---|
| `env.example` | All required environment variables with documentation |
| `deploy.sh` | End-to-end deployment: bootstrap → secret → Argo CD Application |
| `validate.sh` | Health checks for all deployed components |
| `gitops/bootstrap/base/` | OpenShift GitOps operator subscription |
| `gitops/argocd/` | Argo CD instance, AppProject, and Application manifests |
| `gitops/stages/mta-agents/` | Kustomize manifests for the full MTA agents stack |

## Development rules

- Keep the kustomization tree flat — avoid overlay nesting beyond what is already present.
- When adding a new Gateway CR for a different LLM provider, add it to `llm-gateway/` and reference it in the stage `kustomization.yaml`.
- Do not add RHOAI, MaaS, GPU, RHBK, Dev Spaces, or RHDH resources — this repo is intentionally minimal.
- Shell scripts must pass `shellcheck` and use `set -euo pipefail`.
- YAML resources must include `argocd.argoproj.io/sync-wave` annotations consistent with the table above.
