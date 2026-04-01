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
        print_info "Get the admin password with:"
        print_info "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
        echo ""
        print_info "Port-forward the ArgoCD UI:"
        print_info "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
        print_info "  Then open: https://localhost:8080 (username: admin)"
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

# --- Usage ---

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
        upgrade-argocd)     cmd_upgrade_argocd "$@" ;;
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
