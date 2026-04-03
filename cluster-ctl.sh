#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib/common.sh"

# --- Commands ---

cmd_init_cluster() {
    require_gum
    require_cmd "k3d" "brew install k3d  (or visit https://k3d.io)"
    require_cmd "kubectl" "brew install kubectl"
    require_cmd "jq" "brew install jq"
    require_helm

    print_header "Initialize k3d Cluster"
    echo ""

    # Prompt for cluster name
    local default_name
    default_name="$(basename "${TARGET_DIR}")"
    local cluster_name
    cluster_name="$(gum input --value "$default_name" --prompt "Cluster name: ")"

    if [[ -z "$cluster_name" ]]; then
        print_error "Cluster name is required."
        exit 1
    fi

    # Check if cluster already exists
    if k3d cluster list -o json 2>/dev/null | jq -e --arg name "$cluster_name" '.[] | select(.name == $name)' &>/dev/null; then
        print_error "Cluster '${cluster_name}' already exists."
        print_info "Run 'cluster-ctl.sh delete-cluster' to remove it first."
        exit 1
    fi

    # Prompt for agent nodes
    local agents
    agents="$(gum input --value "3" --prompt "Agent nodes: ")"

    # Prompt for port exposure
    local port_args=()
    if gum confirm "Expose ports 80/443 on localhost? (for ingress)"; then
        port_args=(-p "80:80@loadbalancer" -p "443:443@loadbalancer")
    fi

    # Create cluster
    # Set KUBECONFIG on agent nodes so the k3d entrypoint's "kubectl uncordon"
    # loop can reach the API server. Without this, kubectl defaults to
    # localhost:8080, which doesn't exist on agent nodes, and spams errors.
    # The @agent:* suffix is k3d's node filter syntax: apply this env var to
    # all agent nodes only (server nodes already have API access on localhost).
    echo ""
    gum spin --title "Creating k3d cluster '${cluster_name}'..." -- \
        k3d cluster create "$cluster_name" \
        --agents "$agents" \
        --env "KUBECONFIG=/var/lib/rancher/k3s/agent/kubelet.kubeconfig@agent:*" \
        ${port_args[@]+"${port_args[@]}"} \
        --wait

    print_success "Cluster '${cluster_name}' created."
    echo ""

    # Install Metrics Server (required for kubectl top)
    local metrics_server_version="v0.7.2"
    gum spin --title "Installing Metrics Server ${metrics_server_version}..." -- \
        kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${metrics_server_version}/components.yaml"

    # Metrics Server needs --kubelet-insecure-tls in k3d (self-signed kubelet certs)
    gum spin --title "Patching Metrics Server for k3d..." -- \
        kubectl patch deployment metrics-server -n kube-system \
        --type=json \
        -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

    if gum spin --title "Waiting for Metrics Server to be ready..." -- \
        kubectl wait --for=condition=available deployment/metrics-server -n kube-system --timeout=60s; then
        print_success "Metrics Server is ready (kubectl top enabled)."
    else
        print_warning "Metrics Server not ready yet. It may need a moment to stabilize."
    fi
    echo ""

    local argocd_installed=false
    local kargo_installed=false
    local tls_enabled=false

    # Prompt for local HTTPS
    if command -v mkcert &>/dev/null; then
        if gum confirm "Enable HTTPS with trusted local certs? (via mkcert)"; then
            echo ""
            # Ensure the local CA is installed
            mkcert -install 2>/dev/null

            # Generate cert for localhost domains. Wildcard *.localhost doesn't
            # work reliably -- some TLS implementations (including macOS/LibreSSL)
            # refuse to match wildcards against single-label TLDs like .localhost.
            # List each hostname explicitly instead.
            local tls_dir
            tls_dir="$(mktemp -d)"
            mkcert -cert-file "${tls_dir}/tls.crt" -key-file "${tls_dir}/tls.key" \
                "localhost" "argocd.localhost" "kargo.localhost" "app.localhost" \
                "*.localhost" >/dev/null 2>&1

            # Create TLS secret and default TLSStore in kube-system so Traefik uses it for all routes
            gum spin --title "Configuring TLS..." -- bash -c '
                kubectl create secret tls localhost-tls \
                    --cert="'"${tls_dir}"'/tls.crt" --key="'"${tls_dir}"'/tls.key" \
                    --namespace kube-system --dry-run=client -o yaml | kubectl apply -f -

                kubectl apply -f - <<EOF
apiVersion: traefik.io/v1alpha1
kind: TLSStore
metadata:
  name: default
  namespace: kube-system
spec:
  defaultCertificate:
    secretName: localhost-tls
EOF
            '

            rm -rf "$tls_dir"
            tls_enabled=true
            print_success "HTTPS enabled with trusted local certs."
            echo ""
        fi
    fi

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

        local argocd_tls_args=()
        if [[ "$tls_enabled" == true ]]; then
            argocd_tls_args=(
                --set 'server.ingress.annotations.traefik\.ingress\.kubernetes\.io/router\.tls=true'
            )
        fi

        local argocd_log
        argocd_log="$(mktemp)"
        local argocd_cmd="helm install argocd argo/argo-cd \
            --namespace argocd --create-namespace \
            --values \"$values_file\" \
            ${argocd_tls_args[*]+${argocd_tls_args[*]}} \
            --wait --timeout 120s >\"$argocd_log\" 2>&1"
        if gum spin --title "Installing ArgoCD via Helm (this may take a minute)..." -- \
            bash -c "$argocd_cmd"; then
            print_success "ArgoCD installed via Helm."
            argocd_installed=true
        else
            print_error "ArgoCD installation failed:"
            cat "$argocd_log" >&2
        fi
        rm -f "$argocd_log"
    fi

    # Prompt for Kargo installation
    if gum confirm "Install Kargo?"; then
        echo ""

        # Kargo requires cert-manager for webhook server TLS certificates
        # (Kubernetes API server requires TLS for admission webhooks, and
        # Kargo uses cert-manager to generate self-signed certs for them)
        if ! kubectl get crd certificates.cert-manager.io &>/dev/null; then
            helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null 2>&1
            gum spin --title "Installing cert-manager (required by Kargo)..." -- \
                bash -c "helm install cert-manager jetstack/cert-manager \
                --namespace cert-manager --create-namespace \
                --set crds.enabled=true \
                --wait --timeout 120s >/dev/null 2>&1"
            print_success "cert-manager installed."
            echo ""
        fi

        local kargo_password kargo_password_confirm
        while true; do
            kargo_password="$(gum input --password --prompt "Kargo admin password: ")"
            if [[ -z "$kargo_password" ]]; then
                print_error "Password cannot be empty."
                continue
            fi
            kargo_password_confirm="$(gum input --password --prompt "Confirm password: ")"
            if [[ "$kargo_password" != "$kargo_password_confirm" ]]; then
                print_error "Passwords do not match."
                continue
            fi
            break
        done

        local kargo_hash
        kargo_hash="$(htpasswd -bnBC 10 "" "$kargo_password" | tr -d ':\n')"
        local kargo_signing_key
        kargo_signing_key="$(openssl rand -base64 48 | tr -d '=+/' | head -c 32)"

        # TLS termination happens at the Traefik level, not in Kargo;
        # api.tls.enabled=false disables TLS on the Kargo API server itself,
        # api.tls.terminatedUpstream=true signals that an upstream proxy already terminated TLS.
        local kargo_log
        kargo_log="$(mktemp)"
        if gum spin --title "Installing Kargo via Helm (this may take a minute)..." -- \
            bash -c "helm install kargo \
            oci://ghcr.io/akuity/kargo-charts/kargo \
            --namespace kargo --create-namespace \
            --set \"api.adminAccount.passwordHash=${kargo_hash}\" \
            --set \"api.adminAccount.tokenSigningKey=${kargo_signing_key}\" \
            --set api.tls.enabled=false \
            --set api.tls.terminatedUpstream=true \
            --wait --timeout 120s >\"$kargo_log\" 2>&1"; then
            print_success "Kargo installed via Helm."

            # Create Ingress for Kargo dashboard
            local kargo_annotations=""
            if [[ "$tls_enabled" == true ]]; then
                kargo_annotations='  annotations:
    traefik.ingress.kubernetes.io/router.tls: "true"'
            fi

            gum spin --title "Creating Kargo Ingress..." -- kubectl apply -f - <<KARGOINGRESS
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kargo
  namespace: kargo
${kargo_annotations}
spec:
  rules:
    - host: kargo.localhost
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kargo-api
                port:
                  number: 80
KARGOINGRESS
            print_success "Kargo Ingress created at kargo.localhost"

            # Update .infra-ctl.conf (create if it doesn't exist yet).
            # This is idempotent: appends the flag or updates an existing line.
            local conf_file="${TARGET_DIR}/.infra-ctl.conf"
            if [[ -f "$conf_file" ]] && grep -q '^KARGO_ENABLED=' "$conf_file"; then
                local tmp
                tmp="$(awk '/^KARGO_ENABLED=/{print "KARGO_ENABLED=true"; next}1' "$conf_file")"
                printf '%s\n' "$tmp" >"$conf_file"
            else
                echo "KARGO_ENABLED=true" >>"$conf_file"
            fi
            print_info "Set KARGO_ENABLED=true in .infra-ctl.conf"

            kargo_installed=true
        else
            print_error "Kargo installation failed:"
            cat "$kargo_log" >&2
        fi
        rm -f "$kargo_log"
    fi

    # Summary
    echo ""
    print_header "Cluster Summary"
    local context
    context="$(kubectl config current-context)"
    local proto="http"
    if [[ "$tls_enabled" == true ]]; then
        proto="https"
    fi

    print_info "Cluster:  ${cluster_name}"
    print_info "Context:  ${context}"
    print_info "Agents:   ${agents}"
    if [[ "$tls_enabled" == true ]]; then
        print_info "HTTPS:    enabled (mkcert)"
    fi

    if [[ "${argocd_installed:-}" == true ]]; then
        echo ""
        local argocd_password
        argocd_password="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
        print_info "ArgoCD UI: ${proto}://argocd.localhost (username: admin)"
        print_info "ArgoCD admin password: ${argocd_password}"
    fi

    if [[ "${kargo_installed:-}" == true ]]; then
        echo ""
        print_info "Kargo UI: ${proto}://kargo.localhost (username: admin)"
    fi

    # Next steps
    echo ""
    print_header "Next Steps"
    print_info "1. Initialize your GitOps repo:  infra-ctl.sh init"
    echo ""
}

cmd_delete_cluster() {
    require_gum
    require_cmd "k3d" "brew install k3d"
    require_cmd "jq" "brew install jq"

    local cluster_name="${1:-}"

    if [[ -z "$cluster_name" ]]; then
        print_header "Delete k3d Cluster"
        echo ""

        local clusters
        clusters="$(k3d cluster list -o json 2>/dev/null | jq -r '.[].name')"

        if [[ -z "$clusters" ]]; then
            print_warning "No k3d clusters found."
            exit 0
        fi

        cluster_name="$(echo "$clusters" | gum choose --header "Select cluster to delete:")"
    else
        print_header "Delete k3d Cluster: ${cluster_name}"
        echo ""
    fi

    echo ""
    if ! gum confirm --prompt.foreground 196 "Delete cluster '${cluster_name}'? This cannot be undone."; then
        print_warning "Aborted."
        exit 0
    fi

    gum spin --title "Deleting cluster '${cluster_name}'..." -- \
        k3d cluster delete "$cluster_name"

    print_success "Cluster '${cluster_name}' deleted."
    echo ""
}

cmd_status() {
    require_gum
    require_cmd "k3d" "brew install k3d"
    require_cmd "kubectl" "brew install kubectl"

    print_header "Cluster Status"
    echo ""

    # k3d clusters
    local clusters
    clusters="$(k3d cluster list 2>/dev/null)" || true
    if [[ -n "$clusters" ]]; then
        echo "$clusters"
    else
        print_warning "No k3d clusters found."
    fi
    echo ""

    # Current context
    local context
    context="$(kubectl config current-context 2>/dev/null)" || context="(none)"
    print_info "Current kubectl context: ${context}"
    echo ""

    # ArgoCD status
    if kubectl get namespace argocd &>/dev/null; then
        print_header "ArgoCD Status"
        kubectl get pods -n argocd --no-headers 2>/dev/null | while IFS= read -r line; do
            print_info "$line"
        done

        echo ""
        if helm status argocd -n argocd &>/dev/null; then
            local helm_status
            helm_status="$(helm status argocd -n argocd -o json 2>/dev/null | jq -r '.info.status' 2>/dev/null)" || true
            print_info "Helm release: ${helm_status}"
        else
            print_info "ArgoCD was not installed via Helm."
        fi
    else
        print_info "ArgoCD is not installed in the current cluster."
    fi

    # Kargo status
    if kubectl get namespace kargo &>/dev/null; then
        print_header "Kargo Status"
        kubectl get pods -n kargo --no-headers 2>/dev/null | while IFS= read -r line; do
            print_info "$line"
        done

        echo ""
        if helm status kargo -n kargo &>/dev/null; then
            local kargo_helm_status
            kargo_helm_status="$(helm status kargo -n kargo -o json 2>/dev/null | jq -r '.info.status' 2>/dev/null)" || true
            print_info "Helm release: ${kargo_helm_status}"
        else
            print_info "Kargo was not installed via Helm."
        fi
    else
        print_info "Kargo is not installed in the current cluster."
    fi
    echo ""
}

cmd_add_repo_creds() {
    require_gum
    require_cmd "kubectl" "brew install kubectl"
    load_conf

    print_header "Configure ArgoCD Repository Credentials"
    echo ""

    # Verify ArgoCD is installed
    if ! kubectl get namespace argocd &>/dev/null; then
        print_error "ArgoCD namespace not found."
        print_info "Run 'cluster-ctl.sh init-cluster' and install ArgoCD first."
        exit 1
    fi

    print_info "Repository: ${REPO_URL}"
    echo ""

    # Check for existing credential
    local existing
    existing="$(kubectl get secret repo-creds -n argocd -o name 2>/dev/null)" || true
    if [[ -n "$existing" ]]; then
        print_warning "Repository credentials already exist."
        if ! gum confirm "Overwrite existing credentials?"; then
            print_warning "Aborted."
            exit 0
        fi
        echo ""
    fi

    # Prompt for PAT
    print_info "A fine-grained GitHub PAT is required. Create one at:"
    print_info "  https://github.com/settings/personal-access-tokens/new"
    print_info ""
    print_info "Required permissions on the GitOps repository:"
    print_info "  Contents:  Read-only"
    echo ""
    local pat
    pat="$(gum input --password --prompt "GitHub PAT: ")"
    if [[ -z "$pat" ]]; then
        print_error "A GitHub PAT is required."
        exit 1
    fi

    # Create or replace the secret
    gum spin --title "Configuring ArgoCD repo credentials..." -- bash -c '
        kubectl create secret generic repo-creds \
            --namespace argocd \
            --from-literal=type=git \
            --from-literal=url="'"${REPO_URL}"'" \
            --from-literal=username=git \
            --from-literal=password="'"${pat}"'" \
            --dry-run=client -o yaml \
            | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
            | kubectl apply -f -
    '

    echo ""
    print_success "ArgoCD repository credentials configured for ${REPO_URL}"
    echo ""
}

cmd_add_kargo_creds() {
    require_gum
    require_cmd "kubectl" "brew install kubectl"
    load_conf

    local app_name=""

    if [[ $# -gt 0 ]]; then
        app_name="$1"
    else
        # Detect apps with Kargo resources and let user pick
        local kargo_apps=()
        local dir
        for dir in "${TARGET_DIR}"/kargo/*/; do
            [[ -d "$dir" ]] || continue
            kargo_apps+=("$(basename "$dir")")
        done

        if [[ ${#kargo_apps[@]} -eq 0 ]]; then
            print_error "No Kargo apps found in kargo/."
            print_info "Kargo resources are created by 'infra-ctl.sh add-app' when Kargo is enabled."
            exit 1
        fi

        if [[ ${#kargo_apps[@]} -eq 1 ]]; then
            app_name="${kargo_apps[0]}"
        else
            app_name="$(printf '%s\n' "${kargo_apps[@]}" | gum choose --header "Select app:")"
        fi
    fi

    validate_k8s_name "$app_name" "App name"

    print_header "Configure Kargo Credentials: ${app_name}"
    echo ""

    # Verify Kargo app directory exists
    local kargo_app_dir="${TARGET_DIR}/kargo/${app_name}"
    if [[ ! -d "$kargo_app_dir" ]]; then
        print_error "No Kargo resources found at kargo/${app_name}/"
        print_info "This app may not use Kargo (e.g., it uses a public upstream image)."
        print_info "Kargo resources are created by 'infra-ctl.sh add-app' when Kargo is enabled."
        exit 1
    fi

    # Read image repo from warehouse
    local image_repo
    image_repo="$(grep 'repoURL:' "${kargo_app_dir}/warehouse.yaml" 2>/dev/null \
        | head -1 | sed 's/.*repoURL:\s*//' | xargs)" || true
    if [[ -z "$image_repo" ]]; then
        print_error "Could not read image repo from kargo/${app_name}/warehouse.yaml"
        exit 1
    fi

    print_info "Repository:       ${REPO_URL}"
    print_info "Container image:  ${image_repo}"
    echo ""

    # Verify namespace exists in cluster
    if ! kubectl get namespace "$app_name" &>/dev/null; then
        print_error "Namespace '${app_name}' not found in the cluster."
        print_info "The Kargo Project resource creates this namespace."
        print_info "Push your changes and let ArgoCD sync, or apply it manually:"
        print_info "  kubectl apply -f kargo/${app_name}/project.yaml"
        exit 1
    fi

    # Prompt for PAT
    print_info "A fine-grained GitHub PAT is required. Kargo needs write access to"
    print_info "commit image tag updates during promotions. Create one at:"
    print_info "  https://github.com/settings/personal-access-tokens/new"
    print_info ""
    print_info "Required permissions on the GitOps repository:"
    print_info "  Contents:  Read and write"
    print_info "  Packages:  Read (only if the container registry is private)"
    echo ""
    local pat
    pat="$(gum input --password --prompt "GitHub PAT: ")"
    if [[ -z "$pat" ]]; then
        print_error "A GitHub PAT is required."
        exit 1
    fi

    # Create Git credential
    gum spin --title "Configuring Kargo Git credentials..." -- bash -c '
        kubectl create secret generic gitops-repo-creds \
            --namespace "'"$app_name"'" \
            --from-literal=type=git \
            --from-literal=url="'"${REPO_URL}"'" \
            --from-literal=username=git \
            --from-literal=password="'"${pat}"'" \
            --dry-run=client -o yaml \
            | kubectl label --local -f - kargo.akuity.io/cred-type=git -o yaml \
            | kubectl apply -f -
    '

    print_success "Git credentials configured for ${REPO_URL}"

    # Optionally create registry credential
    echo ""
    if gum confirm "Is the container registry private?"; then
        gum spin --title "Configuring registry credentials..." -- bash -c '
            kubectl create secret generic registry-creds \
                --namespace "'"$app_name"'" \
                --from-literal=type=image \
                --from-literal=repoURL="'"${image_repo}"'" \
                --from-literal=username=git \
                --from-literal=password="'"${pat}"'" \
                --dry-run=client -o yaml \
                | kubectl label --local -f - kargo.akuity.io/cred-type=image -o yaml \
                | kubectl apply -f -
        '

        print_success "Registry credentials configured for ${image_repo}"
    fi

    echo ""
}

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

cmd_upgrade_kargo() {
    require_gum
    require_cmd "kubectl" "brew install kubectl"
    require_helm

    print_header "Upgrade Kargo"
    echo ""

    if ! helm status kargo -n kargo &>/dev/null; then
        print_error "Kargo Helm release not found in namespace 'kargo'."
        print_info "Run 'cluster-ctl.sh init-cluster' to install Kargo first."
        exit 1
    fi

    gum spin --title "Upgrading Kargo..." -- \
        helm upgrade kargo \
        oci://ghcr.io/akuity/kargo-charts/kargo \
        --namespace kargo \
        --wait --timeout 120s

    print_success "Kargo upgraded."
    echo ""
}

# --- Usage ---

cmd_preflight_check() {
    echo ""
    echo "  cluster-ctl.sh dependencies:"
    echo ""
    preflight_check \
        "gum:brew install gum" \
        "k3d:brew install k3d" \
        "kubectl:brew install kubectl" \
        "jq:brew install jq" \
        "helm:brew install helm" \
        "docker:https://docs.docker.com/get-docker/"
}

usage() {
    cat <<EOF
Usage: cluster-ctl.sh <command> [options]

Commands:
  init-cluster        Create a local k3d cluster and optionally install ArgoCD
  delete-cluster [name]  Tear down a k3d cluster
  add-repo-creds      Configure ArgoCD access to a private Git repository
  add-kargo-creds     Configure Kargo access to a private Git repo and container registry
  upgrade-argocd      Re-apply ArgoCD Helm values (after editing helm/argocd-values.yaml)
  upgrade-kargo       Re-apply Kargo Helm release
  status              Show cluster and ArgoCD health
  preflight-check     Verify all required tools are installed

Global options:
  --target-dir <path>   Directory context (default: current directory)
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
        init-cluster) cmd_init_cluster "$@" ;;
        delete-cluster) cmd_delete_cluster "$@" ;;
        add-repo-creds) cmd_add_repo_creds "$@" ;;
        add-kargo-creds) cmd_add_kargo_creds "$@" ;;
        upgrade-argocd) cmd_upgrade_argocd "$@" ;;
        upgrade-kargo) cmd_upgrade_kargo "$@" ;;
        status) cmd_status "$@" ;;
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
