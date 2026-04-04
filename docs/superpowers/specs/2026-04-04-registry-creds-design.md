# Registry Credentials and ArgoCD Creds Rename

## Problem

Pods using private container registry images (e.g., ghcr.io) fail with `ImagePullBackOff` because kubelet has no registry credentials. ArgoCD's Git repo credentials only give ArgoCD access to read the Git repository; they do not help kubelet pull container images. There is no native Kubernetes concept of cluster-wide `imagePullSecrets`, so credentials must be configured per-namespace.

Additionally, the existing `add-repo-creds` command name is misleading. It configures ArgoCD-specific credentials, not generic "repo" credentials. Renaming it to `add-argo-creds` makes its purpose clear.

## Changes

### 1. Rename `add-repo-creds` to `add-argo-creds`

Clean rename across all files. No backward-compatibility alias.

**Files affected:**
- `cluster-ctl.sh`: function `cmd_add_repo_creds` -> `cmd_add_argo_creds`, dispatcher case, usage text
- `completions.zsh`: command entry
- `AGENTS.md`: workflow sequence and references
- `README.md`: all references
- `infra-ctl.sh`: hint text after `init`

### 2. New command: `cluster-ctl.sh add-registry-creds`

Configures kubelet to pull images from a private container registry by creating a `docker-registry` secret and patching the default ServiceAccount in each target namespace.

**Flow:**

1. `require_gum`, `require_cmd kubectl`, `load_conf`
2. Prompt for registry server (default: `ghcr.io`)
3. Prompt for username (default: `REPO_OWNER` from `.infra-ctl.conf`)
4. Prompt for PAT; validate `read:packages` scope if registry is `ghcr.io`
5. Detect environments from `k8s/namespaces/*.yaml` via `detect_envs`
6. If no environments found, error with hint to run `infra-ctl.sh add-env` first
7. Multi-select namespaces via `gum choose --no-limit` (all pre-selected)
8. For each selected namespace:
   a. Create namespace if it does not exist (`kubectl create namespace --dry-run=client -o yaml | kubectl apply -f -`)
   b. Create `docker-registry` secret named `registry-creds` (idempotent via `--dry-run=client -o yaml | kubectl apply -f -`)
   c. Patch default ServiceAccount to add `imagePullSecrets: [{name: registry-creds}]`
9. Print summary of configured namespaces

**Secret name:** `registry-creds` (consistent with `add-kargo-creds` naming)

**Idempotent:** Safe to re-run. Overwrites existing secret, re-patches ServiceAccount.

**Explain mode:** Each `run_cmd` includes an `--explain` describing why kubelet needs separate credentials from ArgoCD (kubelet pulls container images; ArgoCD reads Git repos; these are different authentication domains).

### 3. `init-cluster` integration

No interactive prompt during init (namespaces do not exist yet, collecting credentials with no immediate effect would be confusing). Instead, add a hint in the "Next Steps" summary:

```
Next Steps
1. Initialize your GitOps repo:       infra-ctl.sh init
2. If using a private registry:       cluster-ctl.sh add-registry-creds
```

### 4. Completions and documentation

- `completions.zsh`: add `add-registry-creds` entry, rename `add-repo-creds` to `add-argo-creds`
- `AGENTS.md`: update workflow sequence with registry creds step, document the command, update all `add-repo-creds` references
- `README.md`: same updates
- `infra-ctl.sh`: update hint referencing `add-repo-creds`

## Why this approach

- **Per-namespace secrets + ServiceAccount patching** is the standard, portable Kubernetes approach. Works on k3d, kind, EKS, GKE, bare metal.
- **No template changes needed.** Patching the default ServiceAccount means all pods in the namespace automatically inherit `imagePullSecrets` without adding the field to every workload manifest.
- **Namespace creation during `add-registry-creds`** solves the chicken-and-egg problem: registry creds must exist before ArgoCD deploys pods, but ArgoCD normally creates namespaces via `CreateNamespace=true`. Pre-creating the namespace is harmless; ArgoCD's `CreateNamespace` is a no-op if the namespace already exists.
- **Hint-only in init-cluster** avoids collecting input that cannot be acted on immediately.

## Sequencing in workflow

The updated workflow sequence becomes:

1. `cluster-ctl.sh init-cluster`
2. `infra-ctl.sh init`
3. `infra-ctl.sh add-env` / `add-app` (creates namespace YAML files and app directories)
4. `cluster-ctl.sh add-argo-creds` (if private Git repo)
5. `cluster-ctl.sh add-registry-creds` (if private container registry)
6. `secret-ctl.sh init` + `secret-ctl.sh add`
7. Commit and push
8. `cluster-ctl.sh argo-init` + `argo-sync`
9. `cluster-ctl.sh add-kargo-creds` (if Kargo + private registry)
