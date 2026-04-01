# RBAC and User Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add ArgoCD Helm-based RBAC, Kubernetes RBAC, and user/service-account management via a new `user-ctl.sh` script.

**Architecture:** Two RBAC layers (ArgoCD for UI/API, Kubernetes for kubectl access) managed by a single `user-ctl.sh` script. ArgoCD migrates from raw manifests to Helm. Roles, users, and service accounts are all managed through interactive gum prompts. The Helm values file (`helm/argocd-values.yaml`) is the source of truth for ArgoCD config, modified programmatically via `yq`.

**Tech Stack:** Bash, gum, helm, yq, kubectl, openssl

**Spec:** `docs/superpowers/specs/2026-04-01-rbac-user-management-design.md`

---

## File Structure

### New files

| File | Responsibility |
|------|---------------|
| `user-ctl.sh` | Main script: role, user, and service account management |
| `helm/argocd-values.yaml` | ArgoCD Helm values (RBAC policy, accounts, server config) |
| `lib/user-ctl-helpers.sh` | Helper functions for user-ctl: YAML generation, ArgoCD policy generation, kubeconfig generation |

### Modified files

| File | Changes |
|------|---------|
| `cluster-ctl.sh` | Replace raw manifest install with Helm; add `upgrade-argocd` command; update `status` |
| `lib/common.sh` | Add `require_yq()` and `require_helm()` |
| `.gitignore` | Add `users/` directory |

### Generated files (by `add-role`)

| File | When |
|------|------|
| `k8s/platform/<role>-clusterrole.yaml` | admin-readonly-settings, viewer, custom presets |
| `k8s/platform/<role>-clusterrolebinding.yaml` | admin-readonly-settings, viewer, custom presets |
| `k8s/platform/<role>-role.yaml` | developer preset |
| `k8s/platform/<role>-rolebinding-<ns>.yaml` | developer preset (one per namespace) |

### Generated files (by `add` / `add-sa`)

| File | When |
|------|------|
| `users/<name>.key` | `add` (human user) |
| `users/<name>.crt` | `add` (human user) |
| `users/<name>.kubeconfig` | `add` and `add-sa` |

---

## Task 1: Scaffold `helm/argocd-values.yaml`

**Files:**
- Create: `helm/argocd-values.yaml`

- [ ] **Step 1: Create the Helm values file**

```yaml
# ArgoCD Helm chart values
# Managed by user-ctl.sh -- safe to edit manually; yq modifications target specific paths.
#
# Apply changes with: cluster-ctl.sh upgrade-argocd
# Or directly: helm upgrade argocd argo/argo-cd -n argocd --values helm/argocd-values.yaml

configs:
  cm: {}
  rbac:
    policy.default: role:readonly
    policy.csv: ""
```

- [ ] **Step 2: Commit**

```bash
git add helm/argocd-values.yaml
git commit -m "Add ArgoCD Helm values file

- Initial values with empty RBAC policy
- policy.default set to role:readonly
- Accounts and policy managed by user-ctl.sh via yq"
```

---

## Task 2: Add `require_yq()` and `require_helm()` to `lib/common.sh`

**Files:**
- Modify: `lib/common.sh:12-43` (dependency checking section)

- [ ] **Step 1: Add `require_yq` function after `require_gum`**

Add after the closing `}` of `require_gum()` (line 43):

```bash
require_yq() {
    if ! command -v yq &>/dev/null; then
        echo "ERROR: 'yq' (Go version by mikefarah) is required but not installed." >&2
        echo "  Install: brew install yq" >&2
        echo "  Or visit: https://github.com/mikefarah/yq#install" >&2
        exit 1
    fi
}

require_helm() {
    if ! command -v helm &>/dev/null; then
        echo "ERROR: 'helm' is required but not installed." >&2
        echo "  Install: brew install helm" >&2
        echo "  Or visit: https://helm.sh/docs/intro/install/" >&2
        exit 1
    fi
}
```

- [ ] **Step 2: Verify the script still sources correctly**

```bash
bash -n lib/common.sh
```

Expected: no output (clean parse).

- [ ] **Step 3: Commit**

```bash
git add lib/common.sh
git commit -m "Add require_yq and require_helm to common.sh

- require_yq checks for mikefarah/yq (Go version)
- require_helm checks for helm CLI
- Both print install hints on failure"
```

---

## Task 3: Migrate ArgoCD install to Helm in `cluster-ctl.sh`

**Files:**
- Modify: `cluster-ctl.sh:74-102` (ArgoCD install block in `cmd_init_cluster`)
- Modify: `cluster-ctl.sh:184-198` (usage text)
- Modify: `cluster-ctl.sh:214-224` (main dispatcher)

- [ ] **Step 1: Add `require_helm` to `cmd_init_cluster` dependency checks**

In `cmd_init_cluster()`, after line 11 (`require_cmd "kubectl" "brew install kubectl"`), add:

```bash
    require_helm
```

- [ ] **Step 2: Replace the raw manifest ArgoCD install block**

Replace lines 74-102 (the entire ArgoCD install block inside the `if gum confirm "Install ArgoCD?"` block) with:

```bash
    # Prompt for ArgoCD installation
    if gum confirm "Install ArgoCD?"; then
        echo ""

        local values_file="${SCRIPT_DIR}/helm/argocd-values.yaml"
        if [[ ! -f "$values_file" ]]; then
            print_error "Helm values file not found: ${values_file}"
            print_info "Expected at: helm/argocd-values.yaml relative to this script."
            exit 1
        fi

        gum spin --title "Adding ArgoCD Helm repo..." -- \
            helm repo add argo https://argoproj.github.io/argo-helm

        gum spin --title "Updating Helm repos..." -- \
            helm repo update

        gum spin --title "Installing ArgoCD via Helm (this may take a minute)..." -- \
            helm install argocd argo/argo-cd \
                --namespace argocd --create-namespace \
                --values "$values_file" \
                --wait --timeout 120s

        print_success "ArgoCD installed via Helm."

        echo ""
        print_info "Get the admin password with:"
        print_info "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
        echo ""
        print_info "Port-forward the ArgoCD UI:"
        print_info "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
        print_info "  Then open: https://localhost:8080 (username: admin)"
    fi
```

- [ ] **Step 3: Add the `cmd_upgrade_argocd` function**

Add after `cmd_status()` and before `usage()`:

```bash
cmd_upgrade_argocd() {
    require_gum
    require_cmd "kubectl" "brew install kubectl"
    require_helm

    print_header "Upgrade ArgoCD"
    echo ""

    # Verify ArgoCD is installed
    if ! helm status argocd -n argocd &>/dev/null; then
        print_error "ArgoCD Helm release not found in namespace 'argocd'."
        print_info "Run 'cluster-ctl.sh init-cluster' to install ArgoCD first."
        exit 1
    fi

    local values_file="${SCRIPT_DIR}/helm/argocd-values.yaml"
    if [[ ! -f "$values_file" ]]; then
        print_error "Helm values file not found: ${values_file}"
        exit 1
    fi

    gum spin --title "Upgrading ArgoCD..." -- \
        helm upgrade argocd argo/argo-cd \
            --namespace argocd \
            --values "$values_file" \
            --wait --timeout 120s

    print_success "ArgoCD upgraded."
    echo ""
}
```

- [ ] **Step 4: Add Helm status to `cmd_status`**

In `cmd_status()`, after the ArgoCD pods listing (inside the `if kubectl get namespace argocd` block, after the `done` on the pod listing loop), add:

```bash
        echo ""
        if helm status argocd -n argocd &>/dev/null; then
            local helm_status
            helm_status="$(helm status argocd -n argocd --short 2>/dev/null)" || true
            print_info "Helm release: ${helm_status}"
        else
            print_info "ArgoCD was not installed via Helm."
        fi
```

- [ ] **Step 5: Update `usage()` to include `upgrade-argocd`**

Replace the usage function:

```bash
usage() {
    cat <<EOF
Usage: cluster-ctl.sh <command> [options]

Commands:
  init-cluster      Create a local k3d cluster and optionally install ArgoCD
  delete-cluster    Tear down a k3d cluster
  upgrade-argocd    Re-apply ArgoCD Helm values (after editing helm/argocd-values.yaml)
  status            Show cluster and ArgoCD health

Global options:
  --target-dir <path>   Directory context (default: current directory)
EOF
}
```

- [ ] **Step 6: Add `upgrade-argocd` to the main dispatcher**

In the `case "$command" in` block, add a new entry:

```bash
        upgrade-argocd)     cmd_upgrade_argocd "$@" ;;
```

- [ ] **Step 7: Verify syntax**

```bash
bash -n cluster-ctl.sh
```

Expected: no output (clean parse).

- [ ] **Step 8: Commit**

```bash
git add cluster-ctl.sh
git commit -m "Migrate ArgoCD install from raw manifests to Helm

- init-cluster now uses helm install with helm/argocd-values.yaml
- Add upgrade-argocd command for re-applying values
- Add Helm release info to status command
- Require helm CLI as dependency"
```

---

## Task 4: Update `.gitignore`

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Add `users/` to `.gitignore`**

Append to `.gitignore`:

```
users/
```

- [ ] **Step 2: Commit**

```bash
git add .gitignore
git commit -m "Gitignore users/ directory

- Contains private keys, certs, and kubeconfigs generated by user-ctl.sh"
```

---

## Task 5: Create `lib/user-ctl-helpers.sh` with ArgoCD policy generation

**Files:**
- Create: `lib/user-ctl-helpers.sh`

This file contains functions that generate YAML and ArgoCD policy strings. Separating them from the main script keeps `user-ctl.sh` focused on flow and prompts.

- [ ] **Step 1: Create the helpers file with ArgoCD policy generators**

```bash
#!/usr/bin/env bash
# Helper functions for user-ctl.sh
# Sourced by user-ctl.sh; not executable on its own.

# --- ArgoCD policy generation ---

# Generates ArgoCD RBAC policy lines for a given role and preset.
# Usage: generate_argocd_policy <role_name> <preset>
# Prints policy lines (p, ... and g, ...) to stdout.
generate_argocd_policy() {
    local role_name="$1"
    local preset="$2"

    case "$preset" in
        admin-readonly-settings)
            cat <<EOF
p, role:${role_name}, applications, *, */*, allow
p, role:${role_name}, projects, *, *, allow
p, role:${role_name}, repositories, *, *, allow
p, role:${role_name}, clusters, get, *, allow
p, role:${role_name}, certificates, get, *, allow
p, role:${role_name}, accounts, get, *, allow
p, role:${role_name}, logs, get, */*, allow
p, role:${role_name}, exec, create, */*, allow
g, ${role_name}, role:${role_name}
EOF
            ;;
        developer)
            cat <<EOF
p, role:${role_name}, applications, *, */*, allow
p, role:${role_name}, logs, get, */*, allow
p, role:${role_name}, exec, create, */*, allow
g, ${role_name}, role:${role_name}
EOF
            ;;
        viewer)
            cat <<EOF
p, role:${role_name}, applications, get, */*, allow
p, role:${role_name}, projects, get, *, allow
p, role:${role_name}, repositories, get, *, allow
p, role:${role_name}, clusters, get, *, allow
p, role:${role_name}, certificates, get, *, allow
p, role:${role_name}, accounts, get, *, allow
p, role:${role_name}, logs, get, */*, allow
g, ${role_name}, role:${role_name}
EOF
            ;;
    esac
}

# Generates ArgoCD RBAC policy lines from custom resource/action selections.
# Usage: generate_argocd_policy_custom <role_name> <resources_csv> <actions_csv>
#   resources_csv: comma-separated list (e.g., "applications,projects,repositories")
#   actions_csv: comma-separated list (e.g., "get,create,update")
generate_argocd_policy_custom() {
    local role_name="$1"
    local resources_csv="$2"
    local actions_csv="$3"

    IFS=',' read -ra resources <<< "$resources_csv"
    IFS=',' read -ra actions <<< "$actions_csv"

    local resource action
    for resource in "${resources[@]}"; do
        resource="$(echo "$resource" | xargs)"  # trim whitespace
        for action in "${actions[@]}"; do
            action="$(echo "$action" | xargs)"
            # applications and logs use project/app scope; others use plain scope
            case "$resource" in
                applications|logs|exec)
                    echo "p, role:${role_name}, ${resource}, ${action}, */*, allow" ;;
                *)
                    echo "p, role:${role_name}, ${resource}, ${action}, *, allow" ;;
            esac
        done
    done
    echo "g, ${role_name}, role:${role_name}"
}

# --- K8s RBAC manifest generation ---

# Generates a ClusterRole YAML for the admin-readonly-settings preset.
# Usage: generate_k8s_admin_readonly_clusterrole <role_name>
generate_k8s_admin_readonly_clusterrole() {
    local role_name="$1"
    cat <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${role_name}-cluster-readonly
  labels:
    app.kubernetes.io/managed-by: user-ctl
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
EOF
}

# Generates ClusterRoleBinding YAML for the admin-readonly-settings preset.
# Two bindings: one for built-in admin (namespaced), one for custom cluster-readonly.
# Usage: generate_k8s_admin_readonly_bindings <role_name>
generate_k8s_admin_readonly_bindings() {
    local role_name="$1"
    cat <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${role_name}-admin
  labels:
    app.kubernetes.io/managed-by: user-ctl
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: admin
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: ${role_name}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${role_name}-cluster-readonly
  labels:
    app.kubernetes.io/managed-by: user-ctl
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${role_name}-cluster-readonly
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: ${role_name}
EOF
}

# Generates a ClusterRole YAML for the viewer preset.
# Usage: generate_k8s_viewer_clusterrole <role_name>
generate_k8s_viewer_clusterrole() {
    local role_name="$1"
    cat <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${role_name}
  labels:
    app.kubernetes.io/managed-by: user-ctl
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["get", "list", "watch"]
  - nonResourceURLs: ["*"]
    verbs: ["get"]
EOF
}

# Generates a ClusterRoleBinding YAML for the viewer preset.
# Usage: generate_k8s_viewer_binding <role_name>
generate_k8s_viewer_binding() {
    local role_name="$1"
    cat <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${role_name}
  labels:
    app.kubernetes.io/managed-by: user-ctl
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${role_name}
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: ${role_name}
EOF
}

# Generates a Role YAML for the developer preset (one namespace).
# Usage: generate_k8s_developer_role <role_name> <namespace>
generate_k8s_developer_role() {
    local role_name="$1"
    local namespace="$2"
    cat <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${role_name}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/managed-by: user-ctl
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["*"]
EOF
}

# Generates a RoleBinding YAML for the developer preset (one namespace).
# Usage: generate_k8s_developer_rolebinding <role_name> <namespace>
generate_k8s_developer_rolebinding() {
    local role_name="$1"
    local namespace="$2"
    cat <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${role_name}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/managed-by: user-ctl
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${role_name}
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: ${role_name}
EOF
}

# --- Kubeconfig generation ---

# Generates a kubeconfig file for a user with client certificate auth.
# Usage: generate_cert_kubeconfig <username> <cert_file> <key_file> <output_file>
generate_cert_kubeconfig() {
    local username="$1"
    local cert_file="$2"
    local key_file="$3"
    local output_file="$4"

    local cluster_name server ca_data
    cluster_name="$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')"
    server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
    ca_data="$(kubectl config view --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"

    cat > "$output_file" <<EOF
apiVersion: v1
kind: Config
clusters:
  - cluster:
      certificate-authority-data: ${ca_data}
      server: ${server}
    name: ${cluster_name}
contexts:
  - context:
      cluster: ${cluster_name}
      user: ${username}
    name: ${username}@${cluster_name}
current-context: ${username}@${cluster_name}
users:
  - name: ${username}
    user:
      client-certificate-data: $(base64 < "$cert_file" | tr -d '\n')
      client-key-data: $(base64 < "$key_file" | tr -d '\n')
EOF
}

# Generates a kubeconfig file for a service account with token auth.
# Usage: generate_token_kubeconfig <sa_name> <token> <output_file>
generate_token_kubeconfig() {
    local sa_name="$1"
    local token="$2"
    local output_file="$3"

    local cluster_name server ca_data
    cluster_name="$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')"
    server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
    ca_data="$(kubectl config view --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"

    cat > "$output_file" <<EOF
apiVersion: v1
kind: Config
clusters:
  - cluster:
      certificate-authority-data: ${ca_data}
      server: ${server}
    name: ${cluster_name}
contexts:
  - context:
      cluster: ${cluster_name}
      user: ${sa_name}
    name: ${sa_name}@${cluster_name}
current-context: ${sa_name}@${cluster_name}
users:
  - name: ${sa_name}
    user:
      token: ${token}
EOF
}

# --- Values file manipulation ---

# Appends ArgoCD policy lines to the Helm values file.
# Usage: append_argocd_policy <values_file> <policy_lines>
append_argocd_policy() {
    local values_file="$1"
    local policy_lines="$2"

    local existing
    existing="$(yq '.configs.rbac."policy.csv" // ""' "$values_file")"

    local new_policy
    if [[ -z "$existing" ]]; then
        new_policy="$policy_lines"
    else
        new_policy="${existing}
${policy_lines}"
    fi

    yq -i ".configs.rbac.\"policy.csv\" = \"${new_policy}\"" "$values_file"
}

# Adds an ArgoCD local account to the Helm values file.
# Usage: add_argocd_account <values_file> <username>
add_argocd_account() {
    local values_file="$1"
    local username="$2"

    yq -i ".configs.cm.\"accounts.${username}\" = \"apiKey, login\"" "$values_file"
}

# Adds a user-to-group mapping in the ArgoCD policy.
# Usage: add_argocd_user_group <values_file> <username> <group>
add_argocd_user_group() {
    local values_file="$1"
    local username="$2"
    local group="$3"

    local policy_line="g, ${username}, role:${group}"
    append_argocd_policy "$values_file" "$policy_line"
}

# Removes all ArgoCD policy lines containing a role name.
# Usage: remove_argocd_role_policy <values_file> <role_name>
remove_argocd_role_policy() {
    local values_file="$1"
    local role_name="$2"

    local existing
    existing="$(yq '.configs.rbac."policy.csv" // ""' "$values_file")"

    if [[ -z "$existing" ]]; then
        return
    fi

    # Remove lines that reference role:<role_name> or the group mapping line
    local filtered
    filtered="$(echo "$existing" | grep -v "role:${role_name}" | grep -v "^g, ${role_name}," || true)"

    yq -i ".configs.rbac.\"policy.csv\" = \"${filtered}\"" "$values_file"
}

# Removes an ArgoCD account and its group mapping from the values file.
# Usage: remove_argocd_account <values_file> <username>
remove_argocd_account() {
    local values_file="$1"
    local username="$2"

    # Remove account entry
    yq -i "del(.configs.cm.\"accounts.${username}\")" "$values_file"

    # Remove user group mapping from policy
    local existing
    existing="$(yq '.configs.rbac."policy.csv" // ""' "$values_file")"

    if [[ -n "$existing" ]]; then
        local filtered
        filtered="$(echo "$existing" | grep -v "^g, ${username}," || true)"
        yq -i ".configs.rbac.\"policy.csv\" = \"${filtered}\"" "$values_file"
    fi
}

# --- Detection ---

# Checks if a role exists by scanning k8s/platform/ and the values file.
# Usage: role_exists <role_name> <values_file>
# Returns 0 if exists, 1 otherwise.
role_exists() {
    local role_name="$1"
    local values_file="$2"

    # Check k8s manifests
    if ls "${TARGET_DIR}/k8s/platform/${role_name}-"*.yaml &>/dev/null; then
        return 0
    fi

    # Check ArgoCD policy
    local policy
    policy="$(yq '.configs.rbac."policy.csv" // ""' "$values_file")" || true
    if echo "$policy" | grep -q "role:${role_name}"; then
        return 0
    fi

    return 1
}

# Checks if a user or SA account exists in the values file.
# Usage: account_exists <username> <values_file>
# Returns 0 if exists, 1 otherwise.
account_exists() {
    local username="$1"
    local values_file="$2"

    local val
    val="$(yq ".configs.cm.\"accounts.${username}\" // \"\"" "$values_file")" || true
    [[ -n "$val" ]]
}
```

- [ ] **Step 2: Verify syntax**

```bash
bash -n lib/user-ctl-helpers.sh
```

Expected: no output (clean parse).

- [ ] **Step 3: Commit**

```bash
git add lib/user-ctl-helpers.sh
git commit -m "Add user-ctl helper functions

- ArgoCD policy generation for all presets (admin-readonly-settings, developer, viewer, custom)
- K8s RBAC manifest generation (ClusterRole, ClusterRoleBinding, Role, RoleBinding)
- Kubeconfig generation for cert-based and token-based auth
- Values file manipulation via yq (append policy, add/remove accounts)
- Role and account existence detection"
```

---

## Task 6: Create `user-ctl.sh` scaffold with `add-role` command

**Files:**
- Create: `user-ctl.sh`

- [ ] **Step 1: Create `user-ctl.sh` with boilerplate and `add-role`**

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib/common.sh"
source "$(dirname "$0")/lib/user-ctl-helpers.sh"

VALUES_FILE="${SCRIPT_DIR}/helm/argocd-values.yaml"

# --- Commands ---

cmd_add_role() {
    require_gum
    require_cmd "kubectl" "brew install kubectl"
    require_yq
    require_helm

    if [[ $# -lt 1 ]]; then
        print_error "Usage: user-ctl.sh add-role <name>"
        exit 1
    fi

    local role_name="$1"
    validate_k8s_name "$role_name" "Role name"

    if role_exists "$role_name" "$VALUES_FILE"; then
        print_error "Role '${role_name}' already exists."
        exit 1
    fi

    print_header "Add Role: ${role_name}"
    echo ""

    # Choose preset
    local preset
    preset="$(gum choose --header "Permission preset:" \
        "admin-readonly-settings" \
        "developer" \
        "viewer" \
        "custom")"

    local argocd_policy=""
    local created_files=()

    # Generate ArgoCD policy
    case "$preset" in
        admin-readonly-settings|developer|viewer)
            argocd_policy="$(generate_argocd_policy "$role_name" "$preset")"
            ;;
        custom)
            local resources actions
            resources="$(gum choose --no-limit --header "Select ArgoCD resources:" \
                "applications" "projects" "repositories" "clusters" \
                "certificates" "accounts" "logs" "exec" | paste -sd, -)"

            if [[ -z "$resources" ]]; then
                print_error "At least one resource must be selected."
                exit 1
            fi

            actions="$(gum choose --no-limit --header "Select actions:" \
                "get" "create" "update" "delete" "sync" "override" "action" "*" | paste -sd, -)"

            if [[ -z "$actions" ]]; then
                print_error "At least one action must be selected."
                exit 1
            fi

            argocd_policy="$(generate_argocd_policy_custom "$role_name" "$resources" "$actions")"
            ;;
    esac

    # Generate K8s RBAC manifests
    local platform_dir="${TARGET_DIR}/k8s/platform"
    mkdir -p "$platform_dir"

    case "$preset" in
        admin-readonly-settings)
            local cr_file="${platform_dir}/${role_name}-clusterrole.yaml"
            local crb_file="${platform_dir}/${role_name}-clusterrolebinding.yaml"

            generate_k8s_admin_readonly_clusterrole "$role_name" > "$cr_file"
            generate_k8s_admin_readonly_bindings "$role_name" > "$crb_file"
            created_files+=("$cr_file" "$crb_file")
            ;;
        developer)
            # Prompt for namespaces
            local envs
            envs="$(detect_envs)"
            if [[ -z "$envs" ]]; then
                print_error "No environments found. Run 'infra-ctl.sh add-env' first."
                exit 1
            fi

            local selected_namespaces
            selected_namespaces="$(echo "$envs" | gum choose --no-limit --header "Select namespaces for this role:")"

            if [[ -z "$selected_namespaces" ]]; then
                print_error "At least one namespace must be selected."
                exit 1
            fi

            local ns
            while IFS= read -r ns; do
                local role_file="${platform_dir}/${role_name}-role-${ns}.yaml"
                local rb_file="${platform_dir}/${role_name}-rolebinding-${ns}.yaml"

                generate_k8s_developer_role "$role_name" "$ns" > "$role_file"
                generate_k8s_developer_rolebinding "$role_name" "$ns" > "$rb_file"
                created_files+=("$role_file" "$rb_file")
            done <<< "$selected_namespaces"
            ;;
        viewer)
            local cr_file="${platform_dir}/${role_name}-clusterrole.yaml"
            local crb_file="${platform_dir}/${role_name}-clusterrolebinding.yaml"

            generate_k8s_viewer_clusterrole "$role_name" > "$cr_file"
            generate_k8s_viewer_binding "$role_name" > "$crb_file"
            created_files+=("$cr_file" "$crb_file")
            ;;
        custom)
            # For custom, generate a ClusterRole matching the ArgoCD selections.
            # Map ArgoCD resources to k8s API groups/resources as best we can.
            # Custom k8s RBAC uses the same verbs the user selected.
            local cr_file="${platform_dir}/${role_name}-clusterrole.yaml"
            local crb_file="${platform_dir}/${role_name}-clusterrolebinding.yaml"

            # Prompt for k8s RBAC scope since ArgoCD resources don't map 1:1
            print_info "Now configure Kubernetes (kubectl) access for this role."
            local k8s_scope
            k8s_scope="$(gum choose --header "K8s access scope:" \
                "cluster-wide (ClusterRole)" \
                "namespace-scoped (Role per namespace)")"

            if [[ "$k8s_scope" == "cluster-wide (ClusterRole)" ]]; then
                local k8s_verbs
                k8s_verbs="$(gum choose --no-limit --header "Select kubectl verbs:" \
                    "get" "list" "watch" "create" "update" "patch" "delete" "*" | paste -sd',' -)"

                cat > "$cr_file" <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${role_name}
  labels:
    app.kubernetes.io/managed-by: user-ctl
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: [$(echo "$k8s_verbs" | sed 's/,/", "/g; s/^/"/; s/$/"/' )]
  - nonResourceURLs: ["*"]
    verbs: ["get"]
EOF

                generate_k8s_viewer_binding "$role_name" > "$crb_file"
                created_files+=("$cr_file" "$crb_file")
            else
                local envs
                envs="$(detect_envs)"
                if [[ -z "$envs" ]]; then
                    print_error "No environments found."
                    exit 1
                fi

                local selected_ns
                selected_ns="$(echo "$envs" | gum choose --no-limit --header "Select namespaces:")"

                local k8s_verbs
                k8s_verbs="$(gum choose --no-limit --header "Select kubectl verbs:" \
                    "get" "list" "watch" "create" "update" "patch" "delete" "*" | paste -sd',' -)"

                local ns
                while IFS= read -r ns; do
                    local role_file="${platform_dir}/${role_name}-role-${ns}.yaml"
                    local rb_file="${platform_dir}/${role_name}-rolebinding-${ns}.yaml"

                    cat > "$role_file" <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${role_name}
  namespace: ${ns}
  labels:
    app.kubernetes.io/managed-by: user-ctl
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: [$(echo "$k8s_verbs" | sed 's/,/", "/g; s/^/"/; s/$/"/' )]
EOF

                    generate_k8s_developer_rolebinding "$role_name" "$ns" > "$rb_file"
                    created_files+=("$role_file" "$rb_file")
                done <<< "$selected_ns"
            fi
            ;;
    esac

    # Apply k8s manifests
    echo ""
    local f
    for f in "${created_files[@]}"; do
        gum spin --title "Applying $(basename "$f")..." -- \
            kubectl apply -f "$f"
    done
    print_success "K8s RBAC applied."

    # Update ArgoCD values and upgrade
    append_argocd_policy "$VALUES_FILE" "$argocd_policy"
    print_success "ArgoCD policy updated in values file."

    if helm status argocd -n argocd &>/dev/null; then
        gum spin --title "Upgrading ArgoCD to apply RBAC changes..." -- \
            helm upgrade argocd argo/argo-cd \
                --namespace argocd \
                --values "$VALUES_FILE" \
                --wait --timeout 120s
        print_success "ArgoCD upgraded."
    else
        print_warning "ArgoCD not installed. Policy saved to values file; will take effect on next install."
    fi

    echo ""
    print_summary "${created_files[@]}"
    print_info "ArgoCD policy for role '${role_name}' (${preset}):"
    echo "$argocd_policy" | while IFS= read -r line; do
        print_info "  $line"
    done
    echo ""
}

# --- Usage ---

usage() {
    cat <<EOF
Usage: user-ctl.sh <command> [options]

Commands:
  add-role <name>               Create an RBAC role (ArgoCD + Kubernetes)
  remove-role <name>            Remove an RBAC role
  list-roles                    List configured roles

  add <username> <group>        Create a human user with x509 cert
  remove <username>             Remove a human user
  list                          List all users and service accounts

  add-sa <name> <group>         Create a service account with token
  remove-sa <name>              Remove a service account
  refresh-sa <name>             Regenerate a service account token

Global options:
  --target-dir <path>   Directory to operate on (default: current directory)
EOF
}

# --- Main ---

main() {
    parse_global_args "$@"
    set -- ${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}

    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi

    local command="$1"
    shift

    case "$command" in
        add-role)       cmd_add_role "$@" ;;
        remove-role)    cmd_remove_role "$@" ;;
        list-roles)     cmd_list_roles "$@" ;;
        add)            cmd_add "$@" ;;
        remove)         cmd_remove "$@" ;;
        list)           cmd_list "$@" ;;
        add-sa)         cmd_add_sa "$@" ;;
        remove-sa)      cmd_remove_sa "$@" ;;
        refresh-sa)     cmd_refresh_sa "$@" ;;
        -h|--help)      usage ;;
        *)
            print_error "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

main "$@"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x user-ctl.sh
```

- [ ] **Step 3: Verify syntax**

```bash
bash -n user-ctl.sh
```

Expected: will fail because `cmd_remove_role`, `cmd_list_roles`, etc. don't exist yet. That's expected; we'll add them in subsequent tasks.

- [ ] **Step 4: Commit**

```bash
git add user-ctl.sh
git commit -m "Add user-ctl.sh with add-role command

- Interactive role creation with gum prompts
- Four permission presets: admin-readonly-settings, developer, viewer, custom
- Generates both ArgoCD RBAC policy and K8s RBAC manifests
- Applies to cluster and upgrades ArgoCD Helm release
- Dispatcher scaffolded for all planned commands"
```

---

## Task 7: Add `list-roles` and `remove-role` commands to `user-ctl.sh`

**Files:**
- Modify: `user-ctl.sh` (add two functions before `usage()`)

- [ ] **Step 1: Add `cmd_list_roles`**

Insert before the `usage()` function in `user-ctl.sh`:

```bash
cmd_list_roles() {
    require_gum
    require_yq

    print_header "Configured Roles"
    echo ""

    # Extract roles from ArgoCD policy
    local policy
    policy="$(yq '.configs.rbac."policy.csv" // ""' "$VALUES_FILE")" || true

    if [[ -z "$policy" ]]; then
        print_warning "No roles configured."
        echo ""
        return
    fi

    # Extract unique role names from "role:<name>" patterns
    local roles
    roles="$(echo "$policy" | grep -oP 'role:\K[^,\s]+' | sort -u)" || true

    if [[ -z "$roles" ]]; then
        print_warning "No roles configured."
        echo ""
        return
    fi

    while IFS= read -r role; do
        # Count policy lines for this role
        local policy_count
        policy_count="$(echo "$policy" | grep -c "role:${role}" || true)"

        # Check for k8s manifests
        local k8s_files
        k8s_files="$(ls "${TARGET_DIR}/k8s/platform/${role}-"*.yaml 2>/dev/null | wc -l | xargs)" || k8s_files="0"

        print_info "${role}  (${policy_count} ArgoCD policies, ${k8s_files} k8s manifests)"
    done <<< "$roles"
    echo ""
}

cmd_remove_role() {
    require_gum
    require_cmd "kubectl" "brew install kubectl"
    require_yq
    require_helm

    if [[ $# -lt 1 ]]; then
        print_error "Usage: user-ctl.sh remove-role <name>"
        exit 1
    fi

    local role_name="$1"

    if ! role_exists "$role_name" "$VALUES_FILE"; then
        print_error "Role '${role_name}' not found."
        exit 1
    fi

    print_header "Remove Role: ${role_name}"
    echo ""

    if ! gum confirm --prompt.foreground 196 "Remove role '${role_name}'? This removes ArgoCD policy and k8s RBAC."; then
        print_warning "Aborted."
        exit 0
    fi

    # Remove k8s manifests
    local platform_dir="${TARGET_DIR}/k8s/platform"
    local manifest_files
    manifest_files="$(ls "${platform_dir}/${role_name}-"*.yaml 2>/dev/null)" || true

    if [[ -n "$manifest_files" ]]; then
        local f
        while IFS= read -r f; do
            gum spin --title "Removing $(basename "$f") from cluster..." -- \
                kubectl delete -f "$f" --ignore-not-found
            rm "$f"
            print_success "Removed: $f"
        done <<< "$manifest_files"
    fi

    # Remove ArgoCD policy
    remove_argocd_role_policy "$VALUES_FILE" "$role_name"
    print_success "ArgoCD policy removed from values file."

    # Upgrade ArgoCD if installed
    if helm status argocd -n argocd &>/dev/null; then
        gum spin --title "Upgrading ArgoCD to remove RBAC..." -- \
            helm upgrade argocd argo/argo-cd \
                --namespace argocd \
                --values "$VALUES_FILE" \
                --wait --timeout 120s
        print_success "ArgoCD upgraded."
    fi

    echo ""
    print_success "Role '${role_name}' removed."
    echo ""
}
```

- [ ] **Step 2: Verify syntax**

```bash
bash -n user-ctl.sh
```

Expected: will still warn about missing `cmd_add`, `cmd_remove`, etc. functions. Acceptable; they're added next.

- [ ] **Step 3: Commit**

```bash
git add user-ctl.sh
git commit -m "Add list-roles and remove-role commands

- list-roles shows roles with policy and manifest counts
- remove-role cleans up ArgoCD policy, k8s manifests, and cluster state
- Both commands validate role existence before acting"
```

---

## Task 8: Add `add` command (human user with x509 cert)

**Files:**
- Modify: `user-ctl.sh` (add `cmd_add` function)

- [ ] **Step 1: Add `cmd_add` function**

Insert after `cmd_remove_role()` in `user-ctl.sh`:

```bash
cmd_add() {
    require_gum
    require_cmd "kubectl" "brew install kubectl"
    require_cmd "openssl" "Install openssl (usually pre-installed on macOS)"
    require_yq
    require_helm

    if [[ $# -lt 2 ]]; then
        print_error "Usage: user-ctl.sh add <username> <group>"
        exit 1
    fi

    local username="$1"
    local group="$2"
    validate_k8s_name "$username" "Username"
    validate_k8s_name "$group" "Group"

    # Verify role exists for this group
    if ! role_exists "$group" "$VALUES_FILE"; then
        print_error "No role found for group '${group}'."
        print_info "Run 'user-ctl.sh add-role ${group}' first."
        exit 1
    fi

    # Verify account doesn't already exist
    if account_exists "$username" "$VALUES_FILE"; then
        print_error "Account '${username}' already exists."
        exit 1
    fi

    print_header "Add User: ${username} (group: ${group})"
    echo ""

    local users_dir="${TARGET_DIR}/users"
    mkdir -p "$users_dir"

    local key_file="${users_dir}/${username}.key"
    local csr_file="${users_dir}/${username}.csr"
    local crt_file="${users_dir}/${username}.crt"
    local kubeconfig_file="${users_dir}/${username}.kubeconfig"

    # Generate key and CSR
    gum spin --title "Generating RSA key..." -- \
        openssl genrsa -out "$key_file" 4096

    gum spin --title "Generating CSR..." -- \
        openssl req -new -key "$key_file" \
            -subj "/CN=${username}/O=${group}" \
            -out "$csr_file"

    print_success "Key and CSR generated."

    # Submit CSR to Kubernetes
    local csr_b64
    csr_b64="$(base64 < "$csr_file" | tr -d '\n')"

    kubectl apply -f - <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${username}
spec:
  request: ${csr_b64}
  signerName: kubernetes.io/kube-apiserver-client
  usages:
    - client auth
EOF

    # Approve CSR
    gum spin --title "Approving CSR..." -- \
        kubectl certificate approve "$username"

    # Wait for certificate to be issued
    local retries=10
    local cert_data=""
    while [[ $retries -gt 0 ]]; do
        cert_data="$(kubectl get csr "$username" -o jsonpath='{.status.certificate}')" || true
        if [[ -n "$cert_data" ]]; then
            break
        fi
        sleep 1
        retries=$((retries - 1))
    done

    if [[ -z "$cert_data" ]]; then
        print_error "Timed out waiting for certificate to be issued."
        kubectl delete csr "$username" --ignore-not-found
        rm -f "$key_file" "$csr_file"
        exit 1
    fi

    echo "$cert_data" | base64 -d > "$crt_file"
    print_success "Certificate issued and saved."

    # Generate kubeconfig
    generate_cert_kubeconfig "$username" "$crt_file" "$key_file" "$kubeconfig_file"
    print_success "Kubeconfig written to ${kubeconfig_file}"

    # Add ArgoCD account
    add_argocd_account "$VALUES_FILE" "$username"
    add_argocd_user_group "$VALUES_FILE" "$username" "$group"
    print_success "ArgoCD account created."

    # Upgrade ArgoCD if installed
    if helm status argocd -n argocd &>/dev/null; then
        gum spin --title "Upgrading ArgoCD to register account..." -- \
            helm upgrade argocd argo/argo-cd \
                --namespace argocd \
                --values "$VALUES_FILE" \
                --wait --timeout 120s
        print_success "ArgoCD upgraded."
    fi

    # Clean up CSR file
    rm -f "$csr_file"

    echo ""
    print_header "User Created"
    print_info "Kubeconfig: ${kubeconfig_file}"
    echo ""
    print_info "To use kubectl:"
    print_info "  export KUBECONFIG=${kubeconfig_file}"
    echo ""
    print_info "To set ArgoCD password (first login):"
    print_info "  argocd account update-password --account ${username}"
    echo ""
}
```

- [ ] **Step 2: Verify syntax**

```bash
bash -n user-ctl.sh
```

- [ ] **Step 3: Commit**

```bash
git add user-ctl.sh
git commit -m "Add user creation with x509 client certificates

- Generates RSA key and CSR with group in O= field
- Submits and approves CSR via Kubernetes API
- Generates kubeconfig with client cert credentials
- Creates ArgoCD local account with group mapping
- Prints setup instructions for kubectl and ArgoCD"
```

---

## Task 9: Add `remove` and `list` commands for human users

**Files:**
- Modify: `user-ctl.sh` (add `cmd_remove` and `cmd_list` functions)

- [ ] **Step 1: Add `cmd_remove` function**

Insert after `cmd_add()`:

```bash
cmd_remove() {
    require_gum
    require_cmd "kubectl" "brew install kubectl"
    require_yq
    require_helm

    if [[ $# -lt 1 ]]; then
        print_error "Usage: user-ctl.sh remove <username>"
        exit 1
    fi

    local username="$1"

    if ! account_exists "$username" "$VALUES_FILE"; then
        print_error "Account '${username}' not found."
        exit 1
    fi

    print_header "Remove User: ${username}"
    echo ""

    if ! gum confirm --prompt.foreground 196 "Remove user '${username}'?"; then
        print_warning "Aborted."
        exit 0
    fi

    # Delete k8s CSR if it exists
    kubectl delete csr "$username" --ignore-not-found 2>/dev/null || true
    print_success "K8s CSR removed."

    # Remove ArgoCD account
    remove_argocd_account "$VALUES_FILE" "$username"
    print_success "ArgoCD account removed from values file."

    # Upgrade ArgoCD if installed
    if helm status argocd -n argocd &>/dev/null; then
        gum spin --title "Upgrading ArgoCD..." -- \
            helm upgrade argocd argo/argo-cd \
                --namespace argocd \
                --values "$VALUES_FILE" \
                --wait --timeout 120s
        print_success "ArgoCD upgraded."
    fi

    # Clean up local files
    local users_dir="${TARGET_DIR}/users"
    rm -f "${users_dir}/${username}.key" "${users_dir}/${username}.crt" \
          "${users_dir}/${username}.csr" "${users_dir}/${username}.kubeconfig"
    print_success "Local files cleaned up."

    echo ""
    print_success "User '${username}' removed."
    echo ""
}
```

- [ ] **Step 2: Add `cmd_list` function**

Insert after `cmd_remove()`:

```bash
cmd_list() {
    require_gum
    require_yq

    print_header "Users and Service Accounts"
    echo ""

    local policy
    policy="$(yq '.configs.rbac."policy.csv" // ""' "$VALUES_FILE")" || true

    # Find all accounts from configs.cm
    local accounts
    accounts="$(yq '.configs.cm | keys | .[]' "$VALUES_FILE" 2>/dev/null \
        | grep '^accounts\.' | sed 's/^accounts\.//')" || true

    if [[ -z "$accounts" ]]; then
        print_warning "No users or service accounts configured."
        echo ""
        return
    fi

    local users_dir="${TARGET_DIR}/users"

    while IFS= read -r account; do
        # Determine type by checking for cert vs kubeconfig-only
        local type="unknown"
        if [[ -f "${users_dir}/${account}.crt" ]]; then
            type="cert"
        elif [[ -f "${users_dir}/${account}.kubeconfig" ]]; then
            type="token"
        fi

        # Find group from policy
        local group
        group="$(echo "$policy" | grep "^g, ${account}," | head -1 \
            | sed 's/^g, [^,]*, role://')" || group="(none)"

        local type_label
        if [[ "$type" == "cert" ]]; then
            type_label="user"
        elif [[ "$type" == "token" ]]; then
            type_label="service-account"
        else
            type_label="unknown"
        fi

        print_info "${account}  [${type_label}]  group: ${group}"
    done <<< "$accounts"
    echo ""
}
```

- [ ] **Step 3: Verify syntax**

```bash
bash -n user-ctl.sh
```

- [ ] **Step 4: Commit**

```bash
git add user-ctl.sh
git commit -m "Add user remove and list commands

- remove cleans up CSR, ArgoCD account, local files, and upgrades Helm
- list shows all accounts with type (user/service-account) and group"
```

---

## Task 10: Add `add-sa`, `remove-sa`, and `refresh-sa` commands

**Files:**
- Modify: `user-ctl.sh` (add three functions)

- [ ] **Step 1: Add `cmd_add_sa` function**

Insert after `cmd_list()`:

```bash
cmd_add_sa() {
    require_gum
    require_cmd "kubectl" "brew install kubectl"
    require_yq
    require_helm

    if [[ $# -lt 2 ]]; then
        print_error "Usage: user-ctl.sh add-sa <name> <group> [--duration <hours>h]"
        exit 1
    fi

    local sa_name="$1"
    local group="$2"
    shift 2
    validate_k8s_name "$sa_name" "Service account name"
    validate_k8s_name "$group" "Group"

    # Parse optional --duration flag
    local duration="2160h"  # 90 days default
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --duration)
                duration="$2"
                shift 2
                ;;
            *)
                print_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # Verify role exists
    if ! role_exists "$group" "$VALUES_FILE"; then
        print_error "No role found for group '${group}'."
        print_info "Run 'user-ctl.sh add-role ${group}' first."
        exit 1
    fi

    # Verify account doesn't already exist
    if account_exists "$sa_name" "$VALUES_FILE"; then
        print_error "Account '${sa_name}' already exists."
        exit 1
    fi

    print_header "Add Service Account: ${sa_name} (group: ${group})"
    echo ""

    local users_dir="${TARGET_DIR}/users"
    mkdir -p "$users_dir"

    # Create ServiceAccount
    kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${sa_name}
  namespace: kube-system
  labels:
    app.kubernetes.io/managed-by: user-ctl
    user-ctl/group: ${group}
EOF
    print_success "ServiceAccount created in kube-system."

    # Create ClusterRoleBinding for the SA
    # Check if this is a developer role (namespace-scoped) or cluster-scoped
    local platform_dir="${TARGET_DIR}/k8s/platform"
    if ls "${platform_dir}/${group}-role-"*.yaml &>/dev/null; then
        # Developer preset: bind to Role in each namespace
        local role_file
        for role_file in "${platform_dir}/${group}-role-"*.yaml; do
            local ns
            ns="$(basename "$role_file" .yaml | sed "s/${group}-role-//")"
            kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${sa_name}
  namespace: ${ns}
  labels:
    app.kubernetes.io/managed-by: user-ctl
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${group}
subjects:
  - kind: ServiceAccount
    name: ${sa_name}
    namespace: kube-system
EOF
        done
        print_success "RoleBindings created for namespaced access."
    else
        # Cluster-scoped: find the ClusterRole to bind to
        local clusterrole_name
        if [[ -f "${platform_dir}/${group}-clusterrole.yaml" ]]; then
            # viewer or custom preset
            clusterrole_name="$(yq '.metadata.name' "${platform_dir}/${group}-clusterrole.yaml")"
        else
            # admin-readonly-settings: bind to both admin and cluster-readonly
            clusterrole_name="admin"
            kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${sa_name}-cluster-readonly
  labels:
    app.kubernetes.io/managed-by: user-ctl
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${group}-cluster-readonly
subjects:
  - kind: ServiceAccount
    name: ${sa_name}
    namespace: kube-system
EOF
        fi

        kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${sa_name}
  labels:
    app.kubernetes.io/managed-by: user-ctl
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${clusterrole_name}
subjects:
  - kind: ServiceAccount
    name: ${sa_name}
    namespace: kube-system
EOF
        print_success "ClusterRoleBinding created."
    fi

    # Generate token
    local token
    token="$(kubectl create token "$sa_name" --namespace kube-system --duration "$duration")"
    print_success "Token generated (duration: ${duration})."

    # Calculate expiry for display
    local duration_hours
    duration_hours="$(echo "$duration" | sed 's/h$//')"
    local expiry_date
    if date -v+${duration_hours}H "+%Y-%m-%d %H:%M" &>/dev/null; then
        # macOS date
        expiry_date="$(date -v+${duration_hours}H "+%Y-%m-%d %H:%M")"
    else
        # GNU date
        expiry_date="$(date -d "+${duration_hours} hours" "+%Y-%m-%d %H:%M")"
    fi

    # Generate kubeconfig
    local kubeconfig_file="${users_dir}/${sa_name}.kubeconfig"
    generate_token_kubeconfig "$sa_name" "$token" "$kubeconfig_file"
    print_success "Kubeconfig written to ${kubeconfig_file}"

    # Add ArgoCD account
    add_argocd_account "$VALUES_FILE" "$sa_name"
    add_argocd_user_group "$VALUES_FILE" "$sa_name" "$group"
    print_success "ArgoCD account created."

    # Upgrade ArgoCD if installed
    if helm status argocd -n argocd &>/dev/null; then
        gum spin --title "Upgrading ArgoCD..." -- \
            helm upgrade argocd argo/argo-cd \
                --namespace argocd \
                --values "$VALUES_FILE" \
                --wait --timeout 120s
        print_success "ArgoCD upgraded."
    fi

    echo ""
    print_header "Service Account Created"
    print_info "Kubeconfig:   ${kubeconfig_file}"
    print_info "Token expiry: ${expiry_date}"
    echo ""
    print_info "To use kubectl:"
    print_info "  export KUBECONFIG=${kubeconfig_file}"
    echo ""
    print_info "To set ArgoCD password (first login):"
    print_info "  argocd account update-password --account ${sa_name}"
    echo ""
}
```

- [ ] **Step 2: Add `cmd_refresh_sa` function**

```bash
cmd_refresh_sa() {
    require_gum
    require_cmd "kubectl" "brew install kubectl"

    if [[ $# -lt 1 ]]; then
        print_error "Usage: user-ctl.sh refresh-sa <name> [--duration <hours>h]"
        exit 1
    fi

    local sa_name="$1"
    shift

    local duration="2160h"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --duration)
                duration="$2"
                shift 2
                ;;
            *)
                print_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # Verify SA exists
    if ! kubectl get serviceaccount "$sa_name" -n kube-system &>/dev/null; then
        print_error "ServiceAccount '${sa_name}' not found in kube-system."
        exit 1
    fi

    print_header "Refresh Token: ${sa_name}"
    echo ""

    local token
    token="$(kubectl create token "$sa_name" --namespace kube-system --duration "$duration")"

    local users_dir="${TARGET_DIR}/users"
    local kubeconfig_file="${users_dir}/${sa_name}.kubeconfig"

    generate_token_kubeconfig "$sa_name" "$token" "$kubeconfig_file"

    local duration_hours
    duration_hours="$(echo "$duration" | sed 's/h$//')"
    local expiry_date
    if date -v+${duration_hours}H "+%Y-%m-%d %H:%M" &>/dev/null; then
        expiry_date="$(date -v+${duration_hours}H "+%Y-%m-%d %H:%M")"
    else
        expiry_date="$(date -d "+${duration_hours} hours" "+%Y-%m-%d %H:%M")"
    fi

    print_success "Token refreshed."
    print_info "Kubeconfig:   ${kubeconfig_file}"
    print_info "Token expiry: ${expiry_date}"
    echo ""
}
```

- [ ] **Step 3: Add `cmd_remove_sa` function**

```bash
cmd_remove_sa() {
    require_gum
    require_cmd "kubectl" "brew install kubectl"
    require_yq
    require_helm

    if [[ $# -lt 1 ]]; then
        print_error "Usage: user-ctl.sh remove-sa <name>"
        exit 1
    fi

    local sa_name="$1"

    print_header "Remove Service Account: ${sa_name}"
    echo ""

    if ! gum confirm --prompt.foreground 196 "Remove service account '${sa_name}'?"; then
        print_warning "Aborted."
        exit 0
    fi

    # Delete ServiceAccount
    kubectl delete serviceaccount "$sa_name" -n kube-system --ignore-not-found
    print_success "ServiceAccount removed."

    # Delete ClusterRoleBindings and RoleBindings owned by this SA
    kubectl delete clusterrolebinding "$sa_name" --ignore-not-found 2>/dev/null || true
    kubectl delete clusterrolebinding "${sa_name}-cluster-readonly" --ignore-not-found 2>/dev/null || true

    # Delete namespace-scoped rolebindings
    local ns
    for ns in $(kubectl get rolebinding -A -l app.kubernetes.io/managed-by=user-ctl \
            -o jsonpath="{range .items[?(@.metadata.name==\"${sa_name}\")]}{.metadata.namespace}{\"\\n\"}{end}" 2>/dev/null); do
        kubectl delete rolebinding "$sa_name" -n "$ns" --ignore-not-found 2>/dev/null || true
    done
    print_success "RBAC bindings removed."

    # Remove ArgoCD account
    if account_exists "$sa_name" "$VALUES_FILE"; then
        remove_argocd_account "$VALUES_FILE" "$sa_name"
        print_success "ArgoCD account removed."

        if helm status argocd -n argocd &>/dev/null; then
            gum spin --title "Upgrading ArgoCD..." -- \
                helm upgrade argocd argo/argo-cd \
                    --namespace argocd \
                    --values "$VALUES_FILE" \
                    --wait --timeout 120s
            print_success "ArgoCD upgraded."
        fi
    fi

    # Clean up local files
    local users_dir="${TARGET_DIR}/users"
    rm -f "${users_dir}/${sa_name}.kubeconfig"
    print_success "Local files cleaned up."

    echo ""
    print_success "Service account '${sa_name}' removed."
    echo ""
}
```

- [ ] **Step 4: Verify syntax**

```bash
bash -n user-ctl.sh
```

Expected: clean parse (all functions now defined).

- [ ] **Step 5: Commit**

```bash
git add user-ctl.sh
git commit -m "Add service account management commands

- add-sa creates SA, RBAC bindings, short-lived token, kubeconfig, and ArgoCD account
- refresh-sa regenerates token and rewrites kubeconfig
- remove-sa cleans up SA, bindings, ArgoCD account, and local files
- Token duration configurable via --duration flag (default 90 days)"
```

---

## Task 11: Update AGENTS.md documentation

**Files:**
- Modify: `AGENTS.md` (wherever script documentation lives)

- [ ] **Step 1: Read the current AGENTS.md to find the right location**

```bash
cat AGENTS.md
```

- [ ] **Step 2: Add `user-ctl.sh` documentation**

Add a new section for `user-ctl.sh` following the existing pattern for `secret-ctl.sh`. Document:

- Script purpose and responsibilities
- All commands with arguments
- Dependencies (gum, helm, yq, kubectl, openssl)
- File outputs (k8s/platform/, users/, helm/argocd-values.yaml)
- Relationship to cluster-ctl.sh (shares ArgoCD Helm lifecycle)

- [ ] **Step 3: Update `cluster-ctl.sh` documentation**

Update the existing `cluster-ctl.sh` section to document:

- ArgoCD Helm migration (no longer raw manifests)
- New `upgrade-argocd` command
- Updated `status` output (Helm release info)
- New dependency: `helm`

- [ ] **Step 4: Update the "Template placeholders" and "Dependencies" sections if present**

Add `yq`, `helm`, and `openssl` to any dependency tables.

- [ ] **Step 5: Commit**

```bash
git add AGENTS.md
git commit -m "Document user-ctl.sh and ArgoCD Helm migration in AGENTS.md

- Add user-ctl.sh section with all commands and dependencies
- Update cluster-ctl.sh section for Helm-based ArgoCD install
- Add new dependencies: helm, yq, openssl"
```

---

## Task 12: Manual Integration Testing

This task is manual verification against a running cluster. No code changes.

- [ ] **Step 1: Create a test cluster**

```bash
./cluster-ctl.sh init-cluster
```

Select "yes" for ArgoCD. Verify it installs via Helm (check for `helm status argocd -n argocd`).

- [ ] **Step 2: Verify status includes Helm info**

```bash
./cluster-ctl.sh status
```

Expected: see "Helm release:" line in ArgoCD section.

- [ ] **Step 3: Create a role**

```bash
./user-ctl.sh add-role platform-team
```

Select `admin-readonly-settings`. Verify:
- Files created in `k8s/platform/`
- ArgoCD values file updated with policy lines
- `kubectl get clusterrole platform-team-cluster-readonly` succeeds
- `kubectl get clusterrolebinding platform-team-admin` succeeds

- [ ] **Step 4: Add a human user**

```bash
./user-ctl.sh add alice platform-team
```

Verify:
- Files in `users/`: `alice.key`, `alice.crt`, `alice.kubeconfig`
- `kubectl get csr alice` shows Approved
- `KUBECONFIG=users/alice.kubeconfig kubectl get pods -A` works
- ArgoCD values file has `accounts.alice: apiKey, login`

- [ ] **Step 5: Add a service account**

```bash
./user-ctl.sh add-sa ci-deploy platform-team
```

Verify:
- `kubectl get sa ci-deploy -n kube-system` exists
- `users/ci-deploy.kubeconfig` exists
- `KUBECONFIG=users/ci-deploy.kubeconfig kubectl get pods -A` works

- [ ] **Step 6: Test list and remove**

```bash
./user-ctl.sh list
./user-ctl.sh list-roles
./user-ctl.sh remove alice
./user-ctl.sh remove-sa ci-deploy
./user-ctl.sh remove-role platform-team
```

Verify each command cleans up its resources.

- [ ] **Step 7: Test upgrade-argocd**

```bash
# Edit helm/argocd-values.yaml manually (add a comment or change policy.default)
./cluster-ctl.sh upgrade-argocd
```

Verify the change takes effect.

- [ ] **Step 8: Clean up**

```bash
./cluster-ctl.sh delete-cluster
```
