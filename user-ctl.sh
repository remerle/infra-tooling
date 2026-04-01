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
            # For custom, prompt for k8s RBAC scope
            print_info "Now configure Kubernetes (kubectl) access for this role."
            local k8s_scope
            k8s_scope="$(gum choose --header "K8s access scope:" \
                "cluster-wide (ClusterRole)" \
                "namespace-scoped (Role per namespace)")"

            if [[ "$k8s_scope" == "cluster-wide (ClusterRole)" ]]; then
                local k8s_verbs
                k8s_verbs="$(gum choose --no-limit --header "Select kubectl verbs:" \
                    "get" "list" "watch" "create" "update" "patch" "delete" "*" | paste -sd',' -)"

                local cr_file="${platform_dir}/${role_name}-clusterrole.yaml"
                local crb_file="${platform_dir}/${role_name}-clusterrolebinding.yaml"

                cat > "$cr_file" <<CREOF
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
CREOF

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

                    cat > "$role_file" <<REOF
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
REOF

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
    roles="$(echo "$policy" | grep -oE 'role:[^,[:space:]]+' | sed 's/^role://' | sort -u)" || true

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
