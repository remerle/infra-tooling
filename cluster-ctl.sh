#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib/common.sh"

# --- Commands ---

cmd_init_cluster() {
    require_gum
    require_cmd "k3d" "brew install k3d  (or visit https://k3d.io)"
    require_cmd "kubectl" "brew install kubectl"

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

    # Prompt for ArgoCD installation
    if gum confirm "Install ArgoCD?"; then
        echo ""
        gum spin --title "Creating argocd namespace..." -- \
            kubectl create namespace argocd

        gum spin --title "Installing ArgoCD (this may take a minute)..." -- \
            kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

        print_info "Waiting for ArgoCD pods to be ready..."
        if ! gum spin --title "Waiting for ArgoCD to be ready..." -- \
            kubectl wait --for=condition=available deployment -n argocd --all --timeout=120s; then
            print_warning "ArgoCD pods are not ready yet. Check with:"
            print_info "  kubectl get pods -n argocd"
            print_info "  kubectl describe pods -n argocd"
            print_info "If pods are stuck, check Docker resource allocation."
        else
            print_success "ArgoCD is ready."
        fi

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
    else
        print_info "ArgoCD is not installed in the current cluster."
    fi
    echo ""
}

# --- Usage ---

usage() {
    cat <<EOF
Usage: cluster-ctl.sh <command> [options]

Commands:
  init-cluster      Create a local k3d cluster and optionally install ArgoCD
  delete-cluster    Tear down a k3d cluster
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
