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

    local name_flag="" preset_flag=""
    local argocd_resources_flag="" actions_flag=""
    local k8s_scope_flag="" k8s_verbs_flag=""
    local ns_flags=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)
                name_flag="$2"
                shift 2
                ;;
            --preset)
                preset_flag="$2"
                shift 2
                ;;
            --argocd-resources)
                argocd_resources_flag="$2"
                shift 2
                ;;
            --actions)
                actions_flag="$2"
                shift 2
                ;;
            --k8s-scope)
                k8s_scope_flag="$2"
                shift 2
                ;;
            --k8s-verbs)
                k8s_verbs_flag="$2"
                shift 2
                ;;
            --namespace)
                ns_flags+=("$2")
                shift 2
                ;;
            -h | --help)
                cat <<EOF
Usage: user-ctl.sh add-role <name> [flags]

Flags:
  --name <string>                 Role name (positional shorthand)
  --preset <preset>               admin-readonly-settings | developer | viewer | custom
  --argocd-resources <csv>        Comma-separated resources (custom preset)
  --actions <csv>                 Comma-separated actions (custom preset)
  --k8s-scope <scope>             cluster-wide | namespace-scoped (custom preset)
  --k8s-verbs <csv>               Comma-separated kubectl verbs (custom preset)
  --namespace <name>              Namespace (repeatable; developer/custom-namespaced)
EOF
                exit 0
                ;;
            -*)
                print_error "Unknown flag: $1"
                exit 1
                ;;
            *)
                if [[ -z "$name_flag" ]]; then name_flag="$1"; else
                    print_error "Unexpected: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    local role_name="$name_flag"
    if [[ -z "$role_name" ]]; then
        role_name=$(prompt_or_die "Role name" "--name")
    fi
    validate_k8s_name "$role_name" "Role name"

    if role_exists "$role_name" "$VALUES_FILE"; then
        print_error "Role '${role_name}' already exists."
        exit 1
    fi

    print_header "Add Role: ${role_name}"

    # Choose preset: flag wins, else prompt, else die
    local preset
    if [[ -n "$preset_flag" ]]; then
        case "$preset_flag" in
            admin-readonly-settings | developer | viewer | custom) preset="$preset_flag" ;;
            *)
                print_error "--preset must be one of: admin-readonly-settings, developer, viewer, custom"
                exit 1
                ;;
        esac
    else
        preset=$(prompt_choose_or_die "Permission preset" "--preset" \
            "admin-readonly-settings" "developer" "viewer" "custom")
    fi

    local argocd_policy=""
    local created_files=()

    # Generate ArgoCD policy
    case "$preset" in
        admin-readonly-settings | developer | viewer)
            argocd_policy="$(generate_argocd_policy "$role_name" "$preset")"
            ;;
        custom)
            local resources actions
            if [[ -n "$argocd_resources_flag" ]]; then
                resources="$argocd_resources_flag"
            elif [[ -t 0 ]]; then
                resources="$(gum choose --no-limit --header "Select ArgoCD resources:" \
                    "applications" "projects" "repositories" "clusters" \
                    "certificates" "accounts" "logs" "exec" | paste -sd, -)"
            else
                print_error "--argocd-resources is required when not running interactively"
                exit 1
            fi

            if [[ -z "$resources" ]]; then
                print_error "At least one resource must be selected."
                exit 1
            fi

            if [[ -n "$actions_flag" ]]; then
                actions="$actions_flag"
            elif [[ -t 0 ]]; then
                actions="$(gum choose --no-limit --header "Select actions:" \
                    "get" "create" "update" "delete" "sync" "override" "action" "*" | paste -sd, -)"
            else
                print_error "--actions is required when not running interactively"
                exit 1
            fi

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

            generate_k8s_admin_readonly_clusterrole "$role_name" >"$cr_file"
            generate_k8s_admin_readonly_bindings "$role_name" >"$crb_file"
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
            if [[ ${#ns_flags[@]} -gt 0 ]]; then
                selected_namespaces="$(printf '%s\n' "${ns_flags[@]}")"
            elif [[ -t 0 ]]; then
                selected_namespaces="$(echo "$envs" | gum choose --no-limit --header "Select namespaces for this role:")"
            else
                print_error "--namespace is required when not running interactively (repeat for multiple)"
                exit 1
            fi

            if [[ -z "$selected_namespaces" ]]; then
                print_error "At least one namespace must be selected."
                exit 1
            fi

            local ns
            while IFS= read -r ns; do
                local role_file="${platform_dir}/${role_name}-role-${ns}.yaml"
                local rb_file="${platform_dir}/${role_name}-rolebinding-${ns}.yaml"

                generate_k8s_developer_role "$role_name" "$ns" >"$role_file"
                generate_k8s_developer_rolebinding "$role_name" "$ns" >"$rb_file"
                created_files+=("$role_file" "$rb_file")
            done <<<"$selected_namespaces"
            ;;
        viewer)
            local cr_file="${platform_dir}/${role_name}-clusterrole.yaml"
            local crb_file="${platform_dir}/${role_name}-clusterrolebinding.yaml"

            generate_k8s_viewer_clusterrole "$role_name" >"$cr_file"
            generate_k8s_viewer_binding "$role_name" >"$crb_file"
            created_files+=("$cr_file" "$crb_file")
            ;;
        custom)
            # K8s scope: flag wins, else prompt, else die
            print_info "Now configure Kubernetes (kubectl) access for this role."
            local k8s_scope
            if [[ -n "$k8s_scope_flag" ]]; then
                case "$k8s_scope_flag" in
                    cluster-wide) k8s_scope="cluster-wide (ClusterRole)" ;;
                    namespace-scoped) k8s_scope="namespace-scoped (Role per namespace)" ;;
                    *)
                        print_error "--k8s-scope must be 'cluster-wide' or 'namespace-scoped'"
                        exit 1
                        ;;
                esac
            elif [[ -t 0 ]]; then
                k8s_scope="$(gum choose --header "K8s access scope:" \
                    "cluster-wide (ClusterRole)" \
                    "namespace-scoped (Role per namespace)")"
            else
                print_error "--k8s-scope is required when not running interactively"
                exit 1
            fi

            if [[ "$k8s_scope" == "cluster-wide (ClusterRole)" ]]; then
                local k8s_verbs
                if [[ -n "$k8s_verbs_flag" ]]; then
                    k8s_verbs="$k8s_verbs_flag"
                elif [[ -t 0 ]]; then
                    k8s_verbs="$(gum choose --no-limit --header "Select kubectl verbs:" \
                        "get" "list" "watch" "create" "update" "patch" "delete" "*" | paste -sd',' -)"
                else
                    print_error "--k8s-verbs is required when not running interactively"
                    exit 1
                fi

                local cr_file="${platform_dir}/${role_name}-clusterrole.yaml"
                local crb_file="${platform_dir}/${role_name}-clusterrolebinding.yaml"

                generate_k8s_custom_clusterrole "$role_name" "$k8s_verbs" >"$cr_file"
                generate_k8s_viewer_binding "$role_name" >"$crb_file"
                created_files+=("$cr_file" "$crb_file")
            else
                local envs
                envs="$(detect_envs)"
                if [[ -z "$envs" ]]; then
                    print_error "No environments found."
                    exit 1
                fi

                local selected_ns
                if [[ ${#ns_flags[@]} -gt 0 ]]; then
                    selected_ns="$(printf '%s\n' "${ns_flags[@]}")"
                elif [[ -t 0 ]]; then
                    selected_ns="$(echo "$envs" | gum choose --no-limit --header "Select namespaces:")"
                else
                    print_error "--namespace is required when not running interactively"
                    exit 1
                fi

                local k8s_verbs
                if [[ -n "$k8s_verbs_flag" ]]; then
                    k8s_verbs="$k8s_verbs_flag"
                elif [[ -t 0 ]]; then
                    k8s_verbs="$(gum choose --no-limit --header "Select kubectl verbs:" \
                        "get" "list" "watch" "create" "update" "patch" "delete" "*" | paste -sd',' -)"
                else
                    print_error "--k8s-verbs is required when not running interactively"
                    exit 1
                fi

                local ns
                while IFS= read -r ns; do
                    local role_file="${platform_dir}/${role_name}-role-${ns}.yaml"
                    local rb_file="${platform_dir}/${role_name}-rolebinding-${ns}.yaml"

                    generate_k8s_custom_role "$role_name" "$ns" "$k8s_verbs" >"$role_file"
                    generate_k8s_developer_rolebinding "$role_name" "$ns" >"$rb_file"
                    created_files+=("$role_file" "$rb_file")
                done <<<"$selected_ns"
            fi
            ;;
    esac

    # Record the preset type for use by add-sa
    echo "$preset" >"${platform_dir}/${role_name}.preset"

    # Apply k8s manifests
    local f
    for f in "${created_files[@]}"; do
        run_cmd "Applying $(basename "$f")..." \
            --explain "kubectl apply creates or updates the RBAC resource (ClusterRole, Role, or Binding) in the cluster, making the permissions immediately effective." \
            kubectl apply -f "$f"
    done
    print_success "K8s RBAC applied."

    # Update ArgoCD values and upgrade
    append_argocd_policy "$VALUES_FILE" "$argocd_policy"
    print_success "ArgoCD policy updated in values file."

    upgrade_argocd_if_installed "$VALUES_FILE"

    print_summary "${created_files[@]}"
    print_info "ArgoCD policy for role '${role_name}' (${preset}):"
    echo "$argocd_policy" | while IFS= read -r line; do
        print_info "  $line"
    done
}

cmd_list_roles() {
    require_gum
    require_yq

    print_header "Configured Roles"

    # Extract roles from ArgoCD policy
    local policy
    policy="$(yq '.configs.rbac."policy.csv" // ""' "$VALUES_FILE")" || true

    if [[ -z "$policy" ]]; then
        print_warning "No roles configured."
        return
    fi

    # Extract unique role names from "role:<name>" patterns
    local roles
    roles="$(echo "$policy" | grep -oE 'role:[^,[:space:]]+' | sed 's/^role://' | sort -u)" || true

    if [[ -z "$roles" ]]; then
        print_warning "No roles configured."
        return
    fi

    while IFS= read -r role; do
        # Count policy lines for this role
        local policy_count
        policy_count="$(echo "$policy" | grep -c "role:${role}" || true)"

        # Check for k8s manifests
        local k8s_files
        k8s_files="$(find "${TARGET_DIR}/k8s/platform" -maxdepth 1 -name "${role}-*.yaml" 2>/dev/null | wc -l | xargs)" || k8s_files="0"

        print_info "${role}  (${policy_count} ArgoCD policies, ${k8s_files} k8s manifests)"
    done <<<"$roles"
}

cmd_remove_role() {
    require_gum
    require_cmd "kubectl" "brew install kubectl"
    require_yq
    require_helm

    local name_flag="" yes="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)
                name_flag="$2"
                shift 2
                ;;
            --yes | -y)
                yes="true"
                shift
                ;;
            -h | --help)
                echo "Usage: user-ctl.sh remove-role [name] [--yes]"
                exit 0
                ;;
            -*)
                print_error "Unknown flag: $1"
                exit 1
                ;;
            *)
                if [[ -z "$name_flag" ]]; then name_flag="$1"; else
                    print_error "Unexpected: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    local role_name="$name_flag"

    if [[ -z "$role_name" ]]; then
        if [[ -t 0 ]]; then
            local policy
            policy="$(yq '.configs.rbac."policy.csv" // ""' "$VALUES_FILE")" || true
            role_name="$(echo "$policy" | grep -oE 'role:[^,[:space:]]+' | sed 's/^role://' | sort -u \
                | choose_from "Select role to remove:" "No roles to remove.")" || exit 0
        else
            print_error "--name is required when not running interactively"
            exit 1
        fi
    fi

    if ! role_exists "$role_name" "$VALUES_FILE"; then
        print_error "Role '${role_name}' not found."
        exit 1
    fi

    print_header "Remove Role: ${role_name}"

    require_yes "$yes" "remove role '${role_name}' (removes ArgoCD policy and k8s RBAC)"

    # Remove k8s manifests
    local platform_dir="${TARGET_DIR}/k8s/platform"
    local manifest_files
    manifest_files="$(ls "${platform_dir}/${role_name}-"*.yaml 2>/dev/null)" || true

    if [[ -n "$manifest_files" ]]; then
        local f
        while IFS= read -r f; do
            run_cmd "Removing $(basename "$f") from cluster..." \
                --explain "Deleting the RBAC resource revokes the permissions immediately for all users/SAs bound to this role." \
                kubectl delete -f "$f" --ignore-not-found
            rm "$f"
            print_success "Removed: $f"
        done <<<"$manifest_files"
    fi

    # Remove preset metadata file
    rm -f "${platform_dir}/${role_name}.preset"

    # Remove ArgoCD policy
    remove_argocd_role_policy "$VALUES_FILE" "$role_name"
    print_success "ArgoCD policy removed from values file."

    upgrade_argocd_if_installed "$VALUES_FILE"

    print_success "Role '${role_name}' removed."
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

    local users_dir="${TARGET_DIR}/users"
    mkdir -p "$users_dir"

    local key_file="${users_dir}/${username}.key"
    local csr_file="${users_dir}/${username}.csr"
    local crt_file="${users_dir}/${username}.crt"
    local kubeconfig_file="${users_dir}/${username}.kubeconfig"

    # Generate key and CSR (umask ensures key is created with 600 permissions)
    run_cmd_sh "Generating RSA key..." \
        --explain "Kubernetes authenticates users via TLS certificates (x509 client cert auth). The private key proves identity; CN= becomes the username, O= becomes the group for RBAC matching." \
        "umask 077 && openssl genrsa -out '$key_file' 4096"

    run_cmd "Generating CSR..." \
        --explain "The Certificate Signing Request packages the public key and identity (CN/O) fields for the Kubernetes CA to sign." \
        openssl req -new -key "$key_file" \
        -subj "/CN=${username}/O=${group}" \
        -out "$csr_file"

    print_success "Key and CSR generated."

    # Submit CSR to Kubernetes
    local csr_b64
    csr_b64="$(base64 <"$csr_file" | tr -d '\n')"

    run_cmd "Submitting CSR to Kubernetes..." \
        --explain "The Kubernetes CSR API: the request is submitted to the cluster where the kube-apiserver-client signer will sign it after approval." \
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
    run_cmd "Approving CSR..." \
        --explain "Approving tells the Kubernetes CA to sign the certificate. In production, this step would be handled by a separate admin or automated approval policy." \
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

    echo "$cert_data" | base64 -d >"$crt_file"
    print_success "Certificate issued and saved."

    # Generate kubeconfig
    generate_cert_kubeconfig "$username" "$crt_file" "$key_file" "$kubeconfig_file"
    print_success "Kubeconfig written to ${kubeconfig_file}"

    # Add ArgoCD account
    add_argocd_account "$VALUES_FILE" "$username"
    add_argocd_user_group "$VALUES_FILE" "$username" "$group"
    print_success "ArgoCD account created."

    upgrade_argocd_if_installed "$VALUES_FILE"

    # Clean up CSR file
    rm -f "$csr_file"

    print_header "User Created"
    print_info "Kubeconfig: ${kubeconfig_file}"
    print_info "To use kubectl:"
    print_info "  export KUBECONFIG=${kubeconfig_file}"
    print_info "To set ArgoCD password (first login):"
    print_info "  argocd account update-password --account ${username}"
}

cmd_remove() {
    require_gum
    require_cmd "kubectl" "brew install kubectl"
    require_yq
    require_helm

    local name_flag="" yes="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)
                name_flag="$2"
                shift 2
                ;;
            --yes | -y)
                yes="true"
                shift
                ;;
            -h | --help)
                echo "Usage: user-ctl.sh remove [username] [--yes]"
                exit 0
                ;;
            -*)
                print_error "Unknown flag: $1"
                exit 1
                ;;
            *)
                if [[ -z "$name_flag" ]]; then name_flag="$1"; else
                    print_error "Unexpected: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    local username="$name_flag"

    if [[ -z "$username" ]]; then
        if [[ -t 0 ]]; then
            username="$(yq '.configs.cm | keys | .[]' "$VALUES_FILE" 2>/dev/null \
                | grep '^accounts\.' | sed 's/^accounts\.//' \
                | choose_from "Select user to remove:" "No users to remove.")" || exit 0
        else
            print_error "--name is required when not running interactively"
            exit 1
        fi
    fi

    if ! account_exists "$username" "$VALUES_FILE"; then
        print_error "Account '${username}' not found."
        exit 1
    fi

    print_header "Remove User: ${username}"

    require_yes "$yes" "remove user '${username}'"

    # Delete k8s CSR if it exists
    run_cmd_sh "Removing K8s CSR..." \
        --explain "Cleaning up the CSR resource from the cluster. Note that the issued certificate cannot be revoked -- Kubernetes has no certificate revocation mechanism." \
        "kubectl delete csr '$username' --ignore-not-found 2>/dev/null || true"
    print_success "K8s CSR removed."

    # Warn about x509 certificate limitation
    # Kubernetes has no certificate revocation. The issued cert remains valid until it
    # expires. RBAC bindings are group-based (shared with other users in the same group),
    # so they cannot be removed per-user. The effective mitigation is:
    # 1. ArgoCD access is revoked immediately (account removed below)
    # 2. kubectl access persists until the cert expires (typically 1 year for kube-apiserver-client)
    # 3. For immediate kubectl revocation, rotate the CA or remove the group's RBAC role
    print_warning "x509 certs cannot be revoked. kubectl access persists until cert expiry."
    print_info "To revoke immediately: run 'user-ctl.sh remove-role <group>' (affects ALL users in that group)."

    # Remove ArgoCD account
    remove_argocd_account "$VALUES_FILE" "$username"
    print_success "ArgoCD account removed from values file."

    upgrade_argocd_if_installed "$VALUES_FILE"

    # Clean up local files
    local users_dir="${TARGET_DIR}/users"
    rm -f "${users_dir}/${username}.key" "${users_dir}/${username}.crt" \
        "${users_dir}/${username}.csr" "${users_dir}/${username}.kubeconfig"
    print_success "Local files cleaned up."

    print_success "User '${username}' removed."
}

cmd_list() {
    require_gum
    require_yq

    print_header "Users and Service Accounts"

    local policy
    policy="$(yq '.configs.rbac."policy.csv" // ""' "$VALUES_FILE")" || true

    # Find all accounts from configs.cm
    local accounts
    accounts="$(yq '.configs.cm | keys | .[]' "$VALUES_FILE" 2>/dev/null \
        | grep '^accounts\.' | sed 's/^accounts\.//')" || true

    if [[ -z "$accounts" ]]; then
        print_warning "No users or service accounts configured."
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

        # Show expiry for service accounts
        local expiry_info=""
        if [[ "$type" == "token" && -f "${users_dir}/${account}.expiry" ]]; then
            expiry_info="  expires: $(cat "${users_dir}/${account}.expiry")"
        fi

        print_info "${account}  [${type_label}]  group: ${group}${expiry_info}"
    done <<<"$accounts"
}

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
    local duration="2160h" # 90 days default
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --duration)
                duration="$2"
                if [[ ! "$duration" =~ ^[0-9]+[hms]$ ]]; then
                    print_error "Invalid duration format: '${duration}'. Use <number><unit> where unit is h (hours), m (minutes), or s (seconds). Example: 2160h"
                    exit 1
                fi
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

    local users_dir="${TARGET_DIR}/users"
    mkdir -p "$users_dir"

    # Create ServiceAccount
    run_cmd "Creating ServiceAccount..." \
        --explain "ServiceAccounts are Kubernetes-native identities for non-human actors. Unlike x509 cert users, they live in-cluster and use short-lived tokens for authentication." \
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

    # Create RBAC bindings based on role preset
    local platform_dir="${TARGET_DIR}/k8s/platform"
    local preset_file="${platform_dir}/${group}.preset"
    local preset=""
    if [[ -f "$preset_file" ]]; then
        preset="$(cat "$preset_file")"
    else
        # Fallback for roles created before preset files existed
        if ls "${platform_dir}/${group}-role-"*.yaml &>/dev/null; then
            preset="developer"
        elif grep -q "name: admin$" "${platform_dir}/${group}-clusterrolebinding.yaml" 2>/dev/null; then
            preset="admin-readonly-settings"
        elif [[ -f "${platform_dir}/${group}-clusterrole.yaml" ]]; then
            preset="viewer"
        fi
    fi

    case "$preset" in
        developer)
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
            ;;
        admin-readonly-settings)
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
  name: admin
subjects:
  - kind: ServiceAccount
    name: ${sa_name}
    namespace: kube-system
EOF
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
            print_success "ClusterRoleBinding created."
            ;;
        viewer | custom)
            local clusterrole_name
            clusterrole_name="$(yq '.metadata.name' "${platform_dir}/${group}-clusterrole.yaml")"
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
            ;;
        *)
            print_error "Could not determine role preset for group '${group}'."
            print_error "Expected ${preset_file} or recognizable RBAC manifests in ${platform_dir}/."
            exit 1
            ;;
    esac

    # Generate token
    local token
    token="$(kubectl create token "$sa_name" --namespace kube-system --duration "$duration")"
    print_success "Token generated (duration: ${duration})."

    # Calculate expiry for display
    local expiry_date
    expiry_date="$(calculate_expiry_date "$duration")"

    # Generate kubeconfig
    local kubeconfig_file="${users_dir}/${sa_name}.kubeconfig"
    generate_token_kubeconfig "$sa_name" "$token" "$kubeconfig_file"
    echo "$expiry_date" >"${users_dir}/${sa_name}.expiry"
    print_success "Kubeconfig written to ${kubeconfig_file}"

    # Add ArgoCD account
    add_argocd_account "$VALUES_FILE" "$sa_name"
    add_argocd_user_group "$VALUES_FILE" "$sa_name" "$group"
    print_success "ArgoCD account created."

    upgrade_argocd_if_installed "$VALUES_FILE"

    print_header "Service Account Created"
    print_info "Kubeconfig:   ${kubeconfig_file}"
    print_info "Token expiry: ${expiry_date}"
    print_info "To use kubectl:"
    print_info "  export KUBECONFIG=${kubeconfig_file}"
    print_info "To set ArgoCD password (first login):"
    print_info "  argocd account update-password --account ${sa_name}"
}

cmd_refresh_sa() {
    require_gum
    require_cmd "kubectl" "brew install kubectl"

    local sa_name=""
    local duration="2160h"

    # Parse: first non-flag arg is the SA name
    if [[ $# -gt 0 && "$1" != --* ]]; then
        sa_name="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --duration)
                duration="$2"
                if [[ ! "$duration" =~ ^[0-9]+[hms]$ ]]; then
                    print_error "Invalid duration format: '${duration}'. Use <number><unit> where unit is h (hours), m (minutes), or s (seconds). Example: 2160h"
                    exit 1
                fi
                shift 2
                ;;
            *)
                print_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # Interactive selection if name not provided
    if [[ -z "$sa_name" ]]; then
        if [[ -t 0 ]]; then
            require_yq
            sa_name="$(detect_sa_accounts "$VALUES_FILE" "${TARGET_DIR}/users" \
                | choose_from "Select service account to refresh:" "No service accounts found.")" || exit 0
        else
            print_error "--name is required when not running interactively"
            exit 1
        fi
    fi

    # Verify SA exists
    if ! kubectl get serviceaccount "$sa_name" -n kube-system &>/dev/null; then
        print_error "ServiceAccount '${sa_name}' not found in kube-system."
        exit 1
    fi

    print_header "Refresh Token: ${sa_name}"

    local token
    token="$(kubectl create token "$sa_name" --namespace kube-system --duration "$duration")"

    local users_dir="${TARGET_DIR}/users"
    local kubeconfig_file="${users_dir}/${sa_name}.kubeconfig"

    generate_token_kubeconfig "$sa_name" "$token" "$kubeconfig_file"

    local expiry_date
    expiry_date="$(calculate_expiry_date "$duration")"

    echo "$expiry_date" >"${users_dir}/${sa_name}.expiry"
    print_success "Token refreshed."
    print_info "Kubeconfig:   ${kubeconfig_file}"
    print_info "Token expiry: ${expiry_date}"
}

cmd_remove_sa() {
    require_gum
    require_cmd "kubectl" "brew install kubectl"
    require_yq
    require_helm

    local name_flag="" yes="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)
                name_flag="$2"
                shift 2
                ;;
            --yes | -y)
                yes="true"
                shift
                ;;
            -h | --help)
                echo "Usage: user-ctl.sh remove-sa [name] [--yes]"
                exit 0
                ;;
            -*)
                print_error "Unknown flag: $1"
                exit 1
                ;;
            *)
                if [[ -z "$name_flag" ]]; then name_flag="$1"; else
                    print_error "Unexpected: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    local sa_name="$name_flag"

    if [[ -z "$sa_name" ]]; then
        if [[ -t 0 ]]; then
            require_yq
            sa_name="$(detect_sa_accounts "$VALUES_FILE" "${TARGET_DIR}/users" \
                | choose_from "Select service account to remove:" "No service accounts to remove.")" || exit 0
        else
            print_error "--name is required when not running interactively"
            exit 1
        fi
    fi

    print_header "Remove Service Account: ${sa_name}"

    require_yes "$yes" "remove service account '${sa_name}'"

    # Delete ServiceAccount and RBAC bindings
    run_cmd_sh "Removing ServiceAccount and RBAC bindings..." \
        --explain "Deleting the ServiceAccount invalidates all tokens immediately (tokens are tied to the SA). Unlike x509 cert users, SA removal is an effective instant revocation." \
        "
        kubectl delete serviceaccount \"${sa_name}\" -n kube-system --ignore-not-found
        kubectl delete clusterrolebinding \"${sa_name}\" --ignore-not-found 2>/dev/null || true
        kubectl delete clusterrolebinding \"${sa_name}-cluster-readonly\" --ignore-not-found 2>/dev/null || true
        for ns in \$(kubectl get rolebinding -A -l app.kubernetes.io/managed-by=user-ctl \
            -o jsonpath=\"{range .items[?(@.metadata.name==\\\"${sa_name}\\\")]}{.metadata.namespace}{\\\"\\\\n\\\"}{end}\" 2>/dev/null); do
            kubectl delete rolebinding \"${sa_name}\" -n \"\$ns\" --ignore-not-found 2>/dev/null || true
        done
    "
    print_success "ServiceAccount and RBAC bindings removed."

    # Remove ArgoCD account
    if account_exists "$sa_name" "$VALUES_FILE"; then
        remove_argocd_account "$VALUES_FILE" "$sa_name"
        print_success "ArgoCD account removed."
        upgrade_argocd_if_installed "$VALUES_FILE"
    fi

    # Clean up local files
    local users_dir="${TARGET_DIR}/users"
    rm -f "${users_dir}/${sa_name}.kubeconfig" "${users_dir}/${sa_name}.expiry"
    print_success "Local files cleaned up."

    print_success "Service account '${sa_name}' removed."
}

# --- Usage ---

cmd_preflight_check() {
    echo "  user-ctl.sh dependencies:"
    preflight_check \
        "gum:brew install gum" \
        "kubectl:brew install kubectl" \
        "openssl:pre-installed on macOS" \
        "yq:brew install yq" \
        "helm:brew install helm"
}

usage() {
    cat <<EOF
Usage: user-ctl.sh <command> [options]

Commands:
  add-role <name>               Create an RBAC role (ArgoCD + Kubernetes)
  remove-role [name]            Remove an RBAC role
  list-roles                    List configured roles

  add <username> <group>        Create a human user with x509 cert
  remove [username]             Remove a human user
  list                          List all users and service accounts

  add-sa <name> <group>         Create a service account with token
  remove-sa [name]              Remove a service account
  refresh-sa [name]             Regenerate a service account token

  preflight-check               Verify all required tools are installed
$(print_global_options)
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
        add-role) cmd_add_role "$@" ;;
        remove-role) cmd_remove_role "$@" ;;
        list-roles) cmd_list_roles "$@" ;;
        add) cmd_add "$@" ;;
        remove) cmd_remove "$@" ;;
        list) cmd_list "$@" ;;
        add-sa) cmd_add_sa "$@" ;;
        remove-sa) cmd_remove_sa "$@" ;;
        refresh-sa) cmd_refresh_sa "$@" ;;
        preflight-check) cmd_preflight_check "$@" ;;
        -h | --help) usage ;;
        *)
            print_error "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

main "$@"
