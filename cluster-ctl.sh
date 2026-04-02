#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib/common.sh"

# --- Commands ---

cmd_init_cluster() {
    require_gum
    require_cmd "k3d" "brew install k3d  (or visit https://k3d.io)"
    require_cmd "kubectl" "brew install kubectl"
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
    if k3d cluster list -o json 2>/dev/null | grep -q "\"name\":\"${cluster_name}\""; then
        print_error "Cluster '${cluster_name}' already exists."
        print_info "Run 'cluster-ctl.sh delete-cluster' to remove it first."
        exit 1
    fi

    # Prompt for agent nodes
    local agents
    agents="$(gum input --value "1" --prompt "Agent nodes: ")"

    # Prompt for port exposure
    local port_args=()
    if gum confirm "Expose ports 80/443 on localhost? (for ingress)"; then
        port_args=(-p "80:80@loadbalancer" -p "443:443@loadbalancer")
    fi

    # Create cluster
    echo ""
    gum spin --title "Creating k3d cluster '${cluster_name}'..." -- \
        k3d cluster create "$cluster_name" \
            --agents "$agents" \
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
        print_info "ArgoCD UI: http://argocd.localhost (username: admin)"
        print_info "Get the admin password with:"
        print_info "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
        print_info "If your GitOps repo is private, run: cluster-ctl.sh add-repo-creds"
    fi

    # Prompt for Kargo installation
    if gum confirm "Install Kargo?"; then
        echo ""

        gum spin --title "Installing Kargo via Helm (this may take a minute)..." -- \
            helm install kargo \
                oci://ghcr.io/akuity/kargo-charts/kargo \
                --namespace kargo --create-namespace \
                --wait --timeout 120s

        print_success "Kargo installed via Helm."

        # Create Ingress for Kargo dashboard
        kubectl apply -f - <<KARGOINGRESS
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kargo
  namespace: kargo
  annotations:
    traefik.ingress.kubernetes.io/router.tls: "true"
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
                  number: 443
KARGOINGRESS
        print_success "Kargo Ingress created at kargo.localhost"

        # Update .infra-ctl.conf if it exists
        local conf_file="${SCRIPT_DIR}/.infra-ctl.conf"
        if [[ -f "$conf_file" ]]; then
            if grep -q '^KARGO_ENABLED=' "$conf_file"; then
                local tmp
                tmp="$(awk '/^KARGO_ENABLED=/{print "KARGO_ENABLED=true"; next}1' "$conf_file")"
                printf '%s\n' "$tmp" > "$conf_file"
            else
                echo "KARGO_ENABLED=true" >> "$conf_file"
            fi
            print_info "Set KARGO_ENABLED=true in .infra-ctl.conf"
        fi

        echo ""
        print_info "Kargo UI: http://kargo.localhost"
        print_info "If your repo or registry is private, run: cluster-ctl.sh add-kargo-creds <app> (after adding apps)"
    fi

    # Summary
    echo ""
    print_header "Cluster Summary"
    local context
    context="$(kubectl config current-context)"
    print_info "Cluster:  ${cluster_name}"
    print_info "Context:  ${context}"
    print_info "Agents:   ${agents}"
    echo ""
}

cmd_delete_cluster() {
    require_gum
    require_cmd "k3d" "brew install k3d"

    print_header "Delete k3d Cluster"
    echo ""

    # Get list of clusters
    local clusters
    clusters="$(k3d cluster list -o json 2>/dev/null | grep '"name"' | sed 's/.*"name":"\([^"]*\)".*/\1/')"

    if [[ -z "$clusters" ]]; then
        print_warning "No k3d clusters found."
        exit 0
    fi

    # Choose cluster
    local cluster_name
    cluster_name="$(echo "$clusters" | gum choose)"

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
            helm_status="$(helm status argocd -n argocd -o json 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)" || true
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
            kargo_helm_status="$(helm status kargo -n kargo -o json 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)" || true
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
    local pat
    pat="$(gum input --password --prompt "GitHub PAT (needs repo read access): ")"
    if [[ -z "$pat" ]]; then
        print_error "A GitHub PAT is required."
        exit 1
    fi

    # Create or replace the secret
    kubectl create secret generic repo-creds \
        --namespace argocd \
        --from-literal=type=git \
        --from-literal=url="${REPO_URL}" \
        --from-literal=username=git \
        --from-literal=password="${pat}" \
        --dry-run=client -o yaml \
        | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
        | kubectl apply -f -

    echo ""
    print_success "ArgoCD repository credentials configured for ${REPO_URL}"
    echo ""
}

cmd_add_kargo_creds() {
    require_gum
    require_cmd "kubectl" "brew install kubectl"

    if [[ $# -eq 0 ]]; then
        print_error "Usage: cluster-ctl.sh add-kargo-creds <app>"
        exit 1
    fi

    local app_name="$1"
    validate_k8s_name "$app_name" "App name"
    load_conf

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
    local pat
    pat="$(gum input --password --prompt "GitHub PAT (needs repo read+write access): ")"
    if [[ -z "$pat" ]]; then
        print_error "A GitHub PAT is required."
        exit 1
    fi

    # Create Git credential
    kubectl create secret generic gitops-repo-creds \
        --namespace "$app_name" \
        --from-literal=type=git \
        --from-literal=url="${REPO_URL}" \
        --from-literal=username=git \
        --from-literal=password="${pat}" \
        --dry-run=client -o yaml \
        | kubectl label --local -f - kargo.akuity.io/cred-type=git -o yaml \
        | kubectl apply -f -

    print_success "Git credentials configured for ${REPO_URL}"

    # Optionally create registry credential
    echo ""
    if gum confirm "Is the container registry private?"; then
        kubectl create secret generic registry-creds \
            --namespace "$app_name" \
            --from-literal=type=image \
            --from-literal=repoURL="${image_repo}" \
            --from-literal=username=git \
            --from-literal=password="${pat}" \
            --dry-run=client -o yaml \
            | kubectl label --local -f - kargo.akuity.io/cred-type=image -o yaml \
            | kubectl apply -f -

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

usage() {
    cat <<EOF
Usage: cluster-ctl.sh <command> [options]

Commands:
  init-cluster        Create a local k3d cluster and optionally install ArgoCD
  delete-cluster      Tear down a k3d cluster
  add-repo-creds      Configure ArgoCD access to a private Git repository
  add-kargo-creds     Configure Kargo access to a private Git repo and container registry
  upgrade-argocd      Re-apply ArgoCD Helm values (after editing helm/argocd-values.yaml)
  upgrade-kargo       Re-apply Kargo Helm release
  status              Show cluster and ArgoCD health

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
        init-cluster)       cmd_init_cluster "$@" ;;
        delete-cluster)     cmd_delete_cluster "$@" ;;
        add-repo-creds)     cmd_add_repo_creds "$@" ;;
        add-kargo-creds)    cmd_add_kargo_creds "$@" ;;
        upgrade-argocd)     cmd_upgrade_argocd "$@" ;;
        upgrade-kargo)      cmd_upgrade_kargo "$@" ;;
        status)             cmd_status "$@" ;;
        -h|--help)          usage ;;
        *)
            print_error "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

main "$@"
