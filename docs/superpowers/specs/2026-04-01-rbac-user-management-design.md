# RBAC and User Management Design

## Overview

Add ArgoCD RBAC, Kubernetes RBAC, and user/service-account management to the infra-tooling repo. Migrate ArgoCD from raw manifests to Helm. Introduce a new `user-ctl.sh` script for all access control operations.

## Goals

1. ArgoCD RBAC controls UI/API access via roles with permission presets
2. Kubernetes RBAC provides direct cluster access for platform teams
3. Human users authenticate via x509 client certificates (signed by the cluster CA via CSR API)
4. Service accounts use short-lived tokens via the TokenRequest API
5. A single interactive tool (`user-ctl.sh`) manages roles, users, and service accounts
6. ArgoCD is installed and managed via Helm

## Architecture

### Two layers of RBAC

| Layer | Controls | Managed via |
|-------|----------|-------------|
| ArgoCD RBAC | UI/API access (applications, projects, repos, settings) | `helm/argocd-values.yaml` policy.csv (Casbin syntax) |
| Kubernetes RBAC | Direct cluster access via kubectl | ClusterRole/ClusterRoleBinding in `k8s/platform/` |

Both layers use the same group names. When `add-role` creates a role, it generates policy for both layers. When `add` creates a user, the certificate's `O=` field and the ArgoCD group mapping both reference the same group.

### Scripts and responsibilities

| Script | Responsibility |
|--------|---------------|
| `cluster-ctl.sh` | Cluster lifecycle, ArgoCD Helm install/upgrade |
| `user-ctl.sh` | Roles, users, service accounts (touches both cluster and repo) |
| `infra-ctl.sh` | GitOps repo structure (unchanged) |
| `secret-ctl.sh` | Sealed secrets (unchanged) |

## ArgoCD Helm Migration

### Changes to `cluster-ctl.sh`

**`init-cluster`** replaces the raw manifest install with:

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --values "$SCRIPT_DIR/helm/argocd-values.yaml" \
  --wait --timeout 120s
```

**New command: `upgrade-argocd`** runs `helm upgrade` with the values file. Convenience wrapper for after manual edits or for use outside of `user-ctl.sh`.

**`status`** adds `helm status argocd -n argocd` output.

**`delete-cluster`** is unchanged; k3d deletion wipes everything.

### Helm values file

`helm/argocd-values.yaml` is checked into the repo. Initial state:

```yaml
configs:
  cm: {}
    # Accounts added here by user-ctl.sh
    # accounts.<name>: apiKey, login
  rbac:
    policy.default: role:readonly
    policy.csv: |
      # Roles and group mappings added by user-ctl.sh add-role
```

Modified programmatically by `user-ctl.sh` using `yq`.

### Dependencies

`helm` added to `require_cmd` checks in `cluster-ctl.sh`.

## `user-ctl.sh` Commands

### `add-role <name>`

Creates an RBAC role in both ArgoCD and Kubernetes.

**Flow:**

1. Validate role name (RFC 1123)
2. Check role doesn't already exist (scan `k8s/platform/` and values file)
3. Prompt for permission preset (gum choose):
   - `admin-readonly-settings` -- full workload control, read-only server config
   - `developer` -- application access within assigned namespaces
   - `viewer` -- read-only everything
   - `custom` -- pick resources and actions interactively
4. For `developer`: prompt which namespaces (gum multi-select from detected envs)
5. For `custom`: multi-select resources, then multi-select actions
6. Generate ArgoCD policy lines, append to `helm/argocd-values.yaml`
7. Generate k8s RBAC manifests in `k8s/platform/`
8. Apply k8s manifests with `kubectl apply`
9. Run `helm upgrade` to apply ArgoCD changes
10. Print summary

**Permission preset mappings:**

| Preset | ArgoCD policy | K8s RBAC |
|--------|--------------|----------|
| `admin-readonly-settings` | `*` on applications, projects, repos; `get` on clusters, certs, accounts, logs | Built-in `admin` ClusterRole (namespaced) + custom read-only ClusterRole (cluster-scoped) |
| `developer` | `*` on applications within assigned projects | Role + RoleBinding per namespace (not ClusterRole) |
| `viewer` | `get` on all resources | ClusterRole: `get/list/watch` on all |
| `custom` | User-selected resource/action combos | Matching ClusterRole with selected API groups/verbs |

**ArgoCD policy example (admin-readonly-settings):**

```csv
p, role:platform-team, applications, *, */*, allow
p, role:platform-team, projects, *, *, allow
p, role:platform-team, repositories, *, *, allow
p, role:platform-team, clusters, get, *, allow
p, role:platform-team, certificates, get, *, allow
p, role:platform-team, accounts, get, *, allow
p, role:platform-team, logs, get, */*, allow
p, role:platform-team, exec, create, */*, allow

g, platform-team, role:platform-team
```

**K8s RBAC example (admin-readonly-settings):**

K8s RBAC is additive (no deny rules), so a single ClusterRole with `resources: ["*"]`
and `verbs: ["*"]` would grant write access to cluster-scoped resources too, defeating
the "not god-mode" goal. Instead, the preset binds the built-in `admin` ClusterRole
(which covers all namespaced resources but not cluster-scoped ones) and adds a custom
ClusterRole for read-only cluster-scoped access.

```yaml
# k8s/platform/platform-team-clusterrole.yaml
# Read-only access to cluster-scoped resources
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform-team-cluster-readonly
rules:
  - apiGroups: ["*"]
    resources:
      - nodes
      - namespaces
      - customresourcedefinitions
      - clusterroles
      - clusterrolebindings
      - storageclasses
      - persistentvolumes
      - ingressclasses
    verbs: ["get", "list", "watch"]
  - nonResourceURLs: ["*"]
    verbs: ["get"]
---
# k8s/platform/platform-team-clusterrolebinding.yaml
# Binding 1: built-in admin ClusterRole for all namespaced resources
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: platform-team-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: admin
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: platform-team
---
# Binding 2: custom read-only for cluster-scoped resources
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: platform-team-cluster-readonly
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: platform-team-cluster-readonly
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: platform-team
```

### `remove-role <name>`

Removes ArgoCD policy lines from values file, deletes k8s manifests, unapplies from cluster, runs `helm upgrade`.

### `list-roles`

Shows roles from the values file and `k8s/platform/`.

### `add <username> <group>`

Creates a human user with x509 client certificate and ArgoCD local account.

**Both arguments are required.** Fails if the group doesn't have a corresponding role (must `add-role` first).

**Flow:**

1. Validate username (RFC 1123) and verify group/role exists
2. Generate RSA key and CSR:
   ```bash
   openssl genrsa -out users/<username>.key 4096
   openssl req -new -key users/<username>.key \
     -subj "/CN=<username>/O=<group>" \
     -out users/<username>.csr
   ```
   The `O=` field maps to the k8s group, matching the ClusterRoleBinding subject.
3. Submit and approve CSR via Kubernetes CertificateSigningRequest API:
   - `signerName: kubernetes.io/kube-apiserver-client`
   - `usages: ["client auth"]`
4. Retrieve signed certificate
5. Generate kubeconfig at `users/<username>.kubeconfig`:
   - Cluster info from current context (server URL, CA)
   - User credentials from signed cert + key
   - Context named `<username>@<cluster-name>`
6. Add ArgoCD local account to values file:
   - `configs.cm.accounts.<username>: apiKey, login`
   - Append `g, <username>, role:<group>` to policy.csv
7. Run `helm upgrade`
8. Clean up `.csr` file, keep `.key`, `.crt`, `.kubeconfig`
9. Print instructions:
   ```
   Kubeconfig written to users/<username>.kubeconfig

   To use kubectl:
     export KUBECONFIG=users/<username>.kubeconfig

   To set ArgoCD password (first login):
     argocd account update-password --account <username>
   ```

### `remove <username>`

Removes ArgoCD account from values file, deletes k8s CSR, cleans up local files, runs `helm upgrade`.

### `list`

Shows all users and service accounts with type (cert/token), group, and token expiry for SAs.

### `add-sa <name> <group>`

Creates a Kubernetes ServiceAccount with a short-lived token and ArgoCD local account.

**Flow:**

1. Validate name and verify group/role exists
2. Create ServiceAccount in `kube-system` namespace
3. Create ClusterRoleBinding (or per-namespace RoleBindings for developer preset) mapping the SA to the role's ClusterRole
4. Generate token via TokenRequest API:
   ```bash
   kubectl create token <name> --namespace kube-system --duration 2160h
   ```
   Default duration: 90 days. Configurable via `--duration` flag.
5. Add ArgoCD local account to values file + `helm upgrade`
6. Generate kubeconfig at `users/<name>.kubeconfig` using the token
7. Print summary with token expiry date

### `refresh-sa <name>`

Regenerates the token and rewrites the kubeconfig. Same `kubectl create token` call with fresh expiry.

### `remove-sa <name>`

Removes ServiceAccount, bindings, ArgoCD account, and local files.

## File Layout

```
infra-tooling/
  cluster-ctl.sh              # Modified: Helm install, upgrade-argocd, status
  user-ctl.sh                 # New
  lib/common.sh               # Modified: add require_yq()
  helm/
    argocd-values.yaml        # New: ArgoCD Helm values
  k8s/
    platform/                 # New: generated by add-role
      <role>-clusterrole.yaml
      <role>-clusterrolebinding.yaml
  users/                      # New: gitignored
    <username>.key
    <username>.crt
    <username>.kubeconfig
  .gitignore                  # Modified: add users/
```

**Not modified:** `infra-ctl.sh`, `secret-ctl.sh`, `templates/`.

K8s RBAC manifests are generated directly by `user-ctl.sh` (not via templates) because they vary by preset, not by placeholder substitution.

## Dependencies

| Tool | Used by | Purpose |
|------|---------|---------|
| `gum` | All scripts | Interactive prompts (existing) |
| `helm` | `cluster-ctl.sh`, `user-ctl.sh` | ArgoCD install/upgrade |
| `yq` | `user-ctl.sh` | Programmatic YAML edits to values file |
| `kubectl` | `cluster-ctl.sh`, `user-ctl.sh` | Cluster operations (existing) |
| `openssl` | `user-ctl.sh` | Key/CSR generation for human users |
| `kubeseal` | `secret-ctl.sh` | Sealed secrets (existing, unchanged) |

## Values File Lifecycle

All programmatic edits to `helm/argocd-values.yaml` use `yq` for targeted path modifications. This preserves manual edits to unrelated sections.

Each `add-role`, `add`, `add-sa`, and their `remove` counterparts run `helm upgrade` after modifying the values file. For a practice cluster, per-operation upgrades are acceptable.

## Workflow

Typical setup sequence after `cluster-ctl.sh init-cluster`:

1. `user-ctl.sh add-role platform-team` -- pick `admin-readonly-settings` preset
2. `user-ctl.sh add alice platform-team` -- human user with cert
3. `user-ctl.sh add-sa ci-deploy platform-team` -- service account for CI
4. `user-ctl.sh add-role developers` -- pick `developer` preset, select namespaces
5. `user-ctl.sh add bob developers` -- human user with limited access
