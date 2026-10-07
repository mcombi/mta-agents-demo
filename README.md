# MTA Agents Demo

A minimal, self-contained GitOps repository that deploys the **Migration Toolkit for Applications (MTA) 8.3 Agentic AI Factory** on Red Hat OpenShift, backed by a self-hosted Qwen model served through an OpenAI-compatible endpoint.

This project is a focused spin-off of [rhoai3-coding-demo](https://github.com/mcombi/rhoai3-coding-demo/tree/feat/mta-agents-maas), retaining only the components required to test MTA Agents.

> **Developer Preview**: MTA Agents is Developer Preview software in MTA 8.3. It is not supported by Red Hat in production and may change or be removed without notice.

---

## What gets deployed

| Component | Namespace | Purpose |
|---|---|---|
| OpenShift GitOps (Argo CD) | `openshift-gitops` | GitOps controller |
| Agent Sandbox Operator | `agent-sandbox-system` | Sandboxed execution environment for agents |
| MTA Operator 8.3 | `openshift-mta` | Migration Toolkit for Applications |
| Tackle CR | `openshift-mta` | MTA instance with `agentic_enabled: true` |
| Gateway CR (`qwen-external`) | `openshift-mta` | LLM gateway pointing to the self-hosted Qwen endpoint |

---

## Prerequisites

- Red Hat OpenShift 4.20+
- `oc` CLI authenticated as `cluster-admin`
- A self-hosted Qwen model endpoint that speaks the OpenAI-compatible chat completions API (`/v1/chat/completions`)
- A fork of this repository pushed to a Git host that Argo CD can reach from the cluster

---

## Quick start

```bash
# 1. Clone and configure
git clone https://github.com/<your-org>/mta-agents-demo.git
cd mta-agents-demo
cp env.example .env
# Edit .env — fill in OPENSHIFT_API_URL, QWEN_ENDPOINT_URL, QWEN_MODEL_ID, etc.

# 2. Log in to the cluster
oc login "${OPENSHIFT_API_URL}" --token=<token>

# 3. Deploy
./deploy.sh

# 4. Validate
./validate.sh
```

---

## After deployment

1. Retrieve the MTA admin password:
   ```bash
   oc get secret mta-mta-hub-bucket -n openshift-mta -o jsonpath='{.data.password}' | base64 -d
   # or look for: oc get secret -n openshift-mta | grep admin
   ```
2. Open the MTA console link from the OpenShift launcher menu.
3. In **Administration → Credentials**, add source control credentials with **push access** to the Git branch that agents will use.
4. In **Migration → Application Inventory**, add the application you want to migrate and assign the credentials.
5. In **Agentic → Agents**, confirm the three default agents (`migration-plan-agent`, `migration-execute-agent`, `migration-verify-agent`) show `Ready`.
6. In **Agentic → Agent runs**, create a run — select an agent, select the `qwen-external` gateway, select the application, and set the target Git branch.

---

## Architecture

```
OpenShift Cluster
├── openshift-gitops
│   └── Argo CD  ─── reconciles ──→  mta-agents (Application)
├── agent-sandbox-system
│   └── Agent Sandbox Operator   ←── agentic-controller
└── openshift-mta
    ├── Tackle CR (agentic_enabled: true)
    ├── agentic-controller
    ├── Secret: mta-qwen-credentials
    ├── Gateway CR: qwen-external (provider: openai)
    │   └── HTTPS /v1/chat/completions ──→ Self-hosted Qwen endpoint
    └── Default Agents: plan / execute / verify
```

---

## Repository layout

```
mta-agents-demo/
├── README.md
├── AGENTS.md                              # Agent entry point for coding agents working on this repo
├── env.example                            # Environment template — copy to .env
├── deploy.sh                              # End-to-end deploy script
├── validate.sh                            # Post-deploy health checks
├── scripts/
│   └── lib.sh                             # Shared helper functions
└── gitops/
    ├── bootstrap/base/                    # OpenShift GitOps operator bootstrap
    ├── argocd/                            # Argo CD instance, project, Application
    └── stages/mta-agents/                 # Kustomize manifests for the MTA stack
        ├── agent-sandbox-operator/
        ├── mta-operator/
        ├── mta-instance/
        └── llm-gateway/
```

---

## References

- [MTA 8.3 — Configuring and using MTA Agents](https://docs.redhat.com/en/documentation/migration_toolkit_for_applications/8.3/html-single/configuring_and_managing_the_migration_toolkit_for_applications_user_interface/configuring-and-using-mta-agents_use)
- [Red Hat build of Agent Sandbox — Installation](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_red_hat_build_of_agent_sandbox/install-agent-sandbox-overview_agent-sandbox)
- [MTA 8.3 Installation guide](https://docs.redhat.com/en/documentation/migration_toolkit_for_applications/8.3/html-single/installing_the_migration_toolkit_for_applications/index)
