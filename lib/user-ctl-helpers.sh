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
    chmod 600 "$output_file"
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
    chmod 600 "$output_file"
}

# --- Helm operations ---

# Upgrades ArgoCD Helm release if it is currently installed.
# No-op with a warning if ArgoCD is not installed.
# Usage: upgrade_argocd_if_installed <values_file>
upgrade_argocd_if_installed() {
    local values_file="$1"

    if helm status argocd -n argocd &>/dev/null; then
        gum spin --title "Upgrading ArgoCD..." -- \
            helm upgrade argocd argo/argo-cd \
                --namespace argocd \
                --values "$values_file" \
                --wait --timeout 120s
        print_success "ArgoCD upgraded."
    else
        print_warning "ArgoCD not installed. Changes saved to values file; will take effect on next install."
    fi
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

    new_policy="$new_policy" yq -i '.configs.rbac."policy.csv" = env(new_policy)' "$values_file"
}

# Adds an ArgoCD local account to the Helm values file.
# Usage: add_argocd_account <values_file> <username>
add_argocd_account() {
    local values_file="$1"
    local username="$2"

    local yq_path=".configs.cm.\"accounts.${username}\""
    yq -i "${yq_path} = \"apiKey, login\"" "$values_file"
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

    # Remove lines that reference this exact role (word-bounded) or the group mapping line
    local filtered
    filtered="$(echo "$existing" | grep -v "role:${role_name}[, ]" | grep -v "role:${role_name}$" | grep -v "^g, ${role_name}," || true)"

    filtered="$filtered" yq -i '.configs.rbac."policy.csv" = env(filtered)' "$values_file"
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
        filtered="$filtered" yq -i '.configs.rbac."policy.csv" = env(filtered)' "$values_file"
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
    if echo "$policy" | grep -qE "role:${role_name}([, ]|$)"; then
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
