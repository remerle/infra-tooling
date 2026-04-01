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
