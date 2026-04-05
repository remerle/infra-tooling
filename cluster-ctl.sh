#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib/common.sh"

# --- Helpers ---

# Generates mkcert certs and applies the TLS Secret + TLSStore to the cluster.
# Used by init-cluster and renew-tls.
apply_local_tls() {
    mkcert -install 2>/dev/null

    # Wildcards against single-label TLDs like .localhost are rejected by
    # most TLS implementations, so we enumerate every hostname explicitly.
    # Core hosts always included; app hostnames come from ingress manifests.
    local hosts=("localhost" "argocd.localhost" "kargo.localhost")

    # Collect <env>.<app>.localhost hostnames from overlay ingresses in the
    # GitOps repo (if any). This keeps the cert SAN list in sync with the
    # Ingress resources that Traefik will serve.
    local ingress_file
    while IFS= read -r ingress_file; do
        local host
        host="$(grep -m1 '^[[:space:]]*-[[:space:]]*host:' "$ingress_file" 2>/dev/null | sed 's/.*host:[[:space:]]*//')"
        [[ -n "$host" ]] && hosts+=("$host")
    done < <(find "${TARGET_DIR}/k8s/apps" -type f -path '*/overlays/*/ingress.yaml' 2>/dev/null | sort -u)

    local tls_dir
    tls_dir="$(mktemp -d)"
    mkcert -cert-file "${tls_dir}/tls.crt" -key-file "${tls_dir}/tls.key" \
        "${hosts[@]}" >/dev/null 2>&1

    run_cmd_sh "Configuring TLS..." \
        --explain "The TLS Secret stores the mkcert-generated certificate and key. The TLSStore (a Traefik CRD) sets it as Traefik's cluster-wide default, so every Ingress route uses the locally-trusted cert automatically. These are cluster-specific resources (not persisted in the GitOps repo) -- to regenerate them, run 'cluster-ctl.sh renew-tls'." \
        '
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
}

# --- Commands ---

cmd_init_cluster() {
    require_gum
    require_cmd "k3d" "brew install k3d  (or visit https://k3d.io)"
    require_cmd "kubectl" "brew install kubectl"
    require_cmd "jq" "brew install jq"
    require_cmd "docker" "https://docs.docker.com/get-docker/"
    require_helm

    # Verify Docker daemon is running (docker CLI exists but daemon may be stopped)
    if ! docker info &>/dev/null; then
        print_error "Docker daemon is not running."
        print_info "Start Docker (or OrbStack) and try again."
        exit 1
    fi

    print_header "Initialize k3d Cluster"

    # Prompt for cluster name
    local default_name
    default_name="$(basename "${TARGET_DIR}")"
    local cluster_name
    cluster_name="$(gum input --value "$default_name" --prompt "Cluster name: ")"

    if [[ -z "$cluster_name" ]]; then
        print_error "Cluster name is required."
        exit 1
    fi

    validate_k8s_name "$cluster_name" "Cluster name"

    # Check if cluster already exists
    if k3d cluster list -o json 2>/dev/null | jq -e --arg name "$cluster_name" '.[] | select(.name == $name)' &>/dev/null; then
        print_error "Cluster '${cluster_name}' already exists."
        print_info "Run 'cluster-ctl.sh delete-cluster' to remove it first."
        exit 1
    fi

    # Prompt for agent nodes
    local agents
    while true; do
        agents="$(gum input --value "3" --prompt "Agent nodes: ")"
        validate_positive_integer "$agents" "Agent nodes" && break
    done

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
    run_cmd "Creating k3d cluster '${cluster_name}'..." \
        --explain "k3d creates a lightweight Kubernetes cluster by running k3s inside Docker containers. --agents sets the number of worker nodes. --env patches agent nodes with a working KUBECONFIG path so the k3d entrypoint's 'kubectl uncordon' loop can reach the API server -- without it, kubectl defaults to localhost:8080 which doesn't exist on agent nodes. --wait blocks until all nodes are Ready." \
        k3d cluster create "$cluster_name" \
        --agents "$agents" \
        --env "KUBECONFIG=/var/lib/rancher/k3s/agent/kubelet.kubeconfig@agent:*" \
        ${port_args[@]+"${port_args[@]}"} \
        --wait
    print_success "Cluster '${cluster_name}' created."

    # k3s bundles Metrics Server (powers 'kubectl top' and HPA).
    # No patching needed -- k3s manages its own kubelet certs.
    if run_cmd "Waiting for Metrics Server to be ready..." \
        --explain "k3s bundles Metrics Server, which collects CPU/memory usage from kubelets. It powers 'kubectl top nodes/pods' and is required by the Horizontal Pod Autoscaler (HPA). No installation needed -- just waiting for it to start." \
        kubectl wait --for=condition=available deployment/metrics-server -n kube-system --timeout=60s; then
        print_success "Metrics Server is ready (kubectl top enabled)."
    else
        print_warning "Metrics Server not ready yet. It may need a moment to stabilize."
    fi

    local argocd_installed=false
    local kargo_installed=false
    local tls_enabled=false

    # Prompt for local HTTPS
    if command -v mkcert &>/dev/null; then
        if gum confirm "Enable HTTPS with trusted local certs? (via mkcert)"; then
            apply_local_tls
            tls_enabled=true
            print_success "HTTPS enabled with trusted local certs."
        fi
    fi

    # Prompt for ArgoCD installation
    if gum confirm "Install ArgoCD?"; then
        local values_file="${SCRIPT_DIR}/helm/argocd-values.yaml"
        if [[ ! -f "$values_file" ]]; then
            print_error "Helm values file not found: ${values_file}"
            print_info "Expected at: helm/argocd-values.yaml relative to this script."
            exit 1
        fi

        run_cmd "Adding ArgoCD Helm repo..." \
            --explain "Helm pulls charts from named remote repositories. This registers the official Argo project Helm repository under the alias 'argo' so subsequent helm commands can reference charts as 'argo/argo-cd'." \
            helm repo add argo https://argoproj.github.io/argo-helm

        run_cmd "Updating Helm repos..." \
            --explain "Helm caches repository index files locally. This refreshes the cache so the latest chart versions and metadata are available. Without this, helm install may use stale data." \
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
        if run_cmd_sh "Installing ArgoCD via Helm (this may take a minute)..." \
            --explain "ArgoCD is a GitOps continuous delivery tool. It watches Git repositories for Kubernetes manifests and automatically syncs the cluster state to match. Installed into its own 'argocd' namespace. --wait blocks until all ArgoCD pods are running." \
            "$argocd_cmd"; then
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
        # Kargo requires cert-manager for webhook server TLS certificates
        # (Kubernetes API server requires TLS for admission webhooks, and
        # Kargo uses cert-manager to generate self-signed certs for them)
        if ! kubectl get crd certificates.cert-manager.io &>/dev/null; then
            helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null 2>&1
            run_cmd_sh "Installing cert-manager (required by Kargo)..." \
                --explain "Kargo uses admission webhooks to validate its custom resources. Kubernetes requires webhook servers to serve TLS. cert-manager automates the issuance of those TLS certificates via its Certificate and Issuer resources, which Kargo's Helm chart relies on." \
                "helm install cert-manager jetstack/cert-manager \
                --namespace cert-manager --create-namespace \
                --set crds.enabled=true \
                --wait --timeout 120s >/dev/null 2>&1"
            print_success "cert-manager installed."
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
        if run_cmd_sh "Installing Kargo via Helm (this may take a minute)..." \
            --explain "Kargo is a progressive delivery tool that promotes container images through a pipeline of stages (e.g., dev -> staging -> prod). It tracks image versions in a Warehouse and applies promotions via Git commits. TLS is terminated at Traefik, so api.tls.enabled=false turns off TLS inside Kargo itself, and api.tls.terminatedUpstream=true tells Kargo an upstream proxy already handled TLS so it sets secure cookie flags correctly." \
            "helm install kargo \
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

            run_cmd_sh "Creating Kargo Ingress..." \
                --explain "An Ingress resource tells Traefik (the cluster's ingress controller) how to route external HTTP/HTTPS traffic to an in-cluster Service. Without this, the Kargo API server is only reachable inside the cluster. The rule maps kargo.localhost to the kargo-api Service on port 80." \
                "kubectl apply -f - <<'KARGOINGRESS'
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
KARGOINGRESS"
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

            kargo_installed=true
        else
            print_error "Kargo installation failed:"
            cat "$kargo_log" >&2
        fi
        rm -f "$kargo_log"
    fi

    # Summary
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
        local argocd_password
        argocd_password="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
        print_info "ArgoCD UI: ${proto}://argocd.localhost (username: admin)"
        print_info "ArgoCD admin password: ${argocd_password}"
    fi

    if [[ "${kargo_installed:-}" == true ]]; then
        print_info "Kargo UI: ${proto}://kargo.localhost (username: admin)"
    fi

    # Next steps
    print_header "Next Steps"
    print_info "1. Initialize your GitOps repo:       infra-ctl.sh init"
    print_info "2. If using a private registry:       cluster-ctl.sh add-registry-creds"
}

cmd_delete_cluster() {
    require_gum
    require_cmd "k3d" "brew install k3d"
    require_cmd "jq" "brew install jq"

    local cluster_name="${1:-}"

    if [[ -z "$cluster_name" ]]; then
        print_header "Delete k3d Cluster"

        cluster_name="$(k3d cluster list -o json 2>/dev/null | jq -r '.[].name' \
            | choose_from "Select cluster to delete:" "No k3d clusters found.")" || exit 0
    else
        print_header "Delete k3d Cluster: ${cluster_name}"
    fi

    confirm_destructive_or_abort "Delete cluster '${cluster_name}'? This cannot be undone."

    run_cmd "Deleting cluster '${cluster_name}'..." \
        --explain "k3d cluster delete stops and removes all Docker containers that make up the cluster (server, agents, load balancer) and cleans up the kubeconfig entry. This is irreversible -- all workloads and persistent volumes in the cluster are destroyed." \
        k3d cluster delete "$cluster_name"

    print_success "Cluster '${cluster_name}' deleted."
}

cmd_status() {
    require_gum
    require_cmd "k3d" "brew install k3d"
    require_cmd "kubectl" "brew install kubectl"

    print_header "Cluster Status"

    # k3d clusters
    local clusters
    clusters="$(k3d cluster list 2>/dev/null)" || true
    if [[ -n "$clusters" ]]; then
        echo "$clusters"
    else
        print_warning "No k3d clusters found."
    fi

    # Current context
    local context
    context="$(kubectl config current-context 2>/dev/null)" || context="(none)"
    print_info "Current kubectl context: ${context}"

    # ArgoCD status
    if kubectl get namespace argocd &>/dev/null; then
        print_header "ArgoCD Status"
        kubectl get pods -n argocd --no-headers 2>/dev/null | while IFS= read -r line; do
            print_info "$line"
        done

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
}

cmd_add_argo_creds() {
    require_gum
    require_gh
    require_cmd "kubectl" "brew install kubectl"
    load_conf

    print_header "Configure ArgoCD Repository Credentials"

    # Verify ArgoCD is installed
    if ! kubectl get namespace argocd &>/dev/null; then
        print_error "ArgoCD namespace not found."
        print_info "Run 'cluster-ctl.sh init-cluster' and install ArgoCD first."
        exit 1
    fi

    print_info "Repository: ${REPO_URL}"

    # Check for existing credential
    local existing
    existing="$(kubectl get secret repo-creds -n argocd -o name 2>/dev/null)" || true
    if [[ -n "$existing" ]]; then
        print_warning "Repository credentials already exist."
        confirm_or_abort "Overwrite existing credentials?"
    fi

    # Prompt for PAT
    print_info "A classic GitHub PAT is required. Create one at:"
    print_info "  https://github.com/settings/tokens/new"
    print_info ""
    print_info "Required scope: repo"
    local pat
    while true; do
        pat="$(gum input --password --prompt "GitHub PAT: ")"
        if [[ -z "$pat" ]]; then
            print_error "A GitHub PAT is required."
            continue
        fi
        if validate_github_pat "$pat" "repo"; then
            break
        fi
        print_info "Please enter a valid PAT with the required scopes."
    done

    # Create or replace the secret
    run_cmd_sh "Configuring ArgoCD repo credentials..." \
        --explain "ArgoCD discovers repository credentials by watching for Secrets labeled with 'argocd.argoproj.io/secret-type=repository'. The label is the signal -- ArgoCD ignores unlabeled Secrets. Piping through 'kubectl label --local' adds the label before applying, avoiding a separate patch step." \
        '
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

    print_success "ArgoCD repository credentials configured for ${REPO_URL}"
}

cmd_add_registry_creds() {
    require_gum
    require_cmd "kubectl" "brew install kubectl"
    load_conf

    print_header "Configure Container Registry Credentials"

    # Prompt for registry server
    local registry
    registry="$(gum input --value "ghcr.io" --prompt "Registry server: ")"
    if [[ -z "$registry" ]]; then
        print_error "Registry server is required."
        exit 1
    fi

    # Prompt for username
    local default_username="${REPO_OWNER:-}"
    local username
    username="$(gum input --value "$default_username" --prompt "Registry username: ")"
    if [[ -z "$username" ]]; then
        print_error "Username is required."
        exit 1
    fi

    # Prompt for PAT
    local pat_hint="A token with read access to the container registry."
    if [[ "$registry" == "ghcr.io" ]]; then
        pat_hint="A classic GitHub PAT is required."
        print_info "Create one at: https://github.com/settings/tokens/new"
        print_info "Required scope: read:packages"
    fi
    print_info "$pat_hint"

    local pat
    while true; do
        pat="$(gum input --password --prompt "Registry token: ")"
        if [[ -z "$pat" ]]; then
            print_error "A token is required."
            continue
        fi
        if [[ "$registry" == "ghcr.io" ]]; then
            if validate_github_pat "$pat" "read:packages"; then
                break
            fi
            print_info "Please enter a valid PAT with the read:packages scope."
        else
            break
        fi
    done

    # Detect environments from GitOps repo
    local envs=()
    readarray -t envs < <(detect_envs)

    if [[ ${#envs[@]} -eq 0 ]]; then
        print_error "No environments found in k8s/namespaces/."
        print_info "Run 'infra-ctl.sh add-env <name>' to create environments first."
        exit 1
    fi

    # Multi-select namespaces (all selected by default)
    local selected=()
    if [[ ${#envs[@]} -eq 1 ]]; then
        selected=("${envs[0]}")
        print_info "Namespace: ${selected[0]}"
    else
        readarray -t selected < <(printf '%s\n' "${envs[@]}" \
            | gum choose --no-limit --selected="$(printf '%s,' "${envs[@]}" | sed 's/,$//')" \
                --header "Select namespaces:")
    fi

    if [[ ${#selected[@]} -eq 0 ]]; then
        print_warning "No namespaces selected."
        return
    fi

    print_info "Registry:   ${registry}"
    print_info "Username:   ${username}"
    print_info "Namespaces: ${selected[*]}"

    local ns
    for ns in "${selected[@]}"; do
        # Create namespace if it doesn't exist
        run_cmd_sh "Ensuring namespace '${ns}' exists..." \
            --explain "Namespaces must exist before Secrets can be created in them. ArgoCD normally creates namespaces via CreateNamespace=true during sync, but registry credentials must be in place before the first sync so kubelet can pull images. Creating the namespace ahead of time is harmless -- ArgoCD's CreateNamespace is a no-op if the namespace already exists." \
            "kubectl create namespace \"$ns\" --dry-run=client -o yaml | kubectl apply -f -"

        # Create docker-registry secret
        run_cmd_sh "Creating registry credentials in '${ns}'..." \
            --explain "Kubelet (the node agent that pulls container images) needs its own credentials for private registries. ArgoCD's Git credentials only give ArgoCD access to read Git repos -- they do not help kubelet pull container images. A kubernetes.io/dockerconfigjson Secret stores registry auth in the format kubelet expects." \
            "kubectl create secret docker-registry registry-creds \
                --namespace \"$ns\" \
                --docker-server=\"$registry\" \
                --docker-username=\"$username\" \
                --docker-password=\"$pat\" \
                --dry-run=client -o yaml | kubectl apply -f -"

        # Patch default ServiceAccount to use the secret
        run_cmd_sh "Patching default ServiceAccount in '${ns}'..." \
            --explain "Every pod that does not specify a serviceAccountName runs as the 'default' ServiceAccount. By adding imagePullSecrets to this ServiceAccount, all pods in the namespace automatically inherit the registry credentials without any changes to individual workload manifests." \
            "kubectl patch serviceaccount default -n \"$ns\" \
                -p '{\"imagePullSecrets\": [{\"name\": \"registry-creds\"}]}'"
    done

    print_success "Registry credentials configured for: ${selected[*]}"
}

cmd_add_kargo_creds() {
    require_gum
    require_gh
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

    # Verify namespace exists in cluster
    if ! kubectl get namespace "$app_name" &>/dev/null; then
        print_error "Namespace '${app_name}' not found in the cluster."
        print_info "The Kargo Project resource creates this namespace."
        print_info "Push your changes and let ArgoCD sync, or apply it manually:"
        print_info "  kubectl apply -f kargo/${app_name}/project.yaml"
        exit 1
    fi

    # Prompt for PAT
    print_info "A classic GitHub PAT is required. Kargo needs write access to"
    print_info "commit image tag updates during promotions. Create one at:"
    print_info "  https://github.com/settings/tokens/new"
    print_info ""
    print_info "Required scopes: repo, read:packages (if the container registry is private)"
    local pat
    while true; do
        pat="$(gum input --password --prompt "GitHub PAT: ")"
        if [[ -z "$pat" ]]; then
            print_error "A GitHub PAT is required."
            continue
        fi
        if validate_github_pat "$pat" "repo" "read:packages"; then
            break
        fi
        print_info "Please enter a valid PAT with the required scopes."
    done

    # Create Git credential
    run_cmd_sh "Configuring Kargo Git credentials..." \
        --explain "Kargo discovers Git credentials by watching for Secrets labeled 'kargo.akuity.io/cred-type=git' inside the app's namespace (its Kargo Project namespace). Kargo needs write access to the GitOps repo so it can commit image tag updates when promoting a new image version through stages." \
        '
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
    if gum confirm "Is the container registry private?"; then
        run_cmd_sh "Configuring registry credentials..." \
            --explain "Kargo's Warehouse polls the container registry to detect new image tags. For private registries it needs pull credentials, stored as a Secret labeled 'kargo.akuity.io/cred-type=image' in the app namespace. The repoURL field scopes the credential to a specific registry/repository prefix." \
            '
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

}

cmd_upgrade_argocd() {
    require_gum
    require_cmd "kubectl" "brew install kubectl"
    require_helm

    print_header "Upgrade ArgoCD"

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

    run_cmd "Upgrading ArgoCD..." \
        --explain "helm upgrade applies any changes made to argocd-values.yaml (custom settings like Ingress hostnames, resource limits, or plugin config) without reinstalling ArgoCD from scratch. --wait ensures the rollout completes and all pods are healthy before the command returns." \
        helm upgrade argocd argo/argo-cd \
        --namespace argocd \
        --values "$values_file" \
        --wait --timeout 120s

    print_success "ArgoCD upgraded."
}

cmd_upgrade_kargo() {
    require_gum
    require_cmd "kubectl" "brew install kubectl"
    require_helm

    print_header "Upgrade Kargo"

    if ! helm status kargo -n kargo &>/dev/null; then
        print_error "Kargo Helm release not found in namespace 'kargo'."
        print_info "Run 'cluster-ctl.sh init-cluster' to install Kargo first."
        exit 1
    fi

    run_cmd "Upgrading Kargo..." \
        --explain "helm upgrade pulls the latest version of the Kargo chart from the OCI registry at ghcr.io and applies it to the running installation. This is how you pick up Kargo bug fixes and new features. --wait blocks until the new pods are running and healthy." \
        helm upgrade kargo \
        oci://ghcr.io/akuity/kargo-charts/kargo \
        --namespace kargo \
        --wait --timeout 120s

    print_success "Kargo upgraded."
}

cmd_renew_tls() {
    require_gum
    require_cmd "kubectl" "brew install kubectl"
    require_cmd "mkcert" "brew install mkcert"

    print_header "Renew Local TLS Certificates"

    # Verify a cluster is reachable
    if ! kubectl cluster-info &>/dev/null; then
        print_error "No reachable cluster found."
        print_info "Make sure your kubectl context points to a running cluster."
        exit 1
    fi

    # Count ingress hostnames we'll include in the cert
    local ingress_count
    ingress_count="$(find "${TARGET_DIR}/k8s/apps" -type f -path '*/overlays/*/ingress.yaml' 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$ingress_count" -gt 0 ]]; then
        print_info "Including ${ingress_count} ingress hostname(s) from ${TARGET_DIR}/k8s/apps/*/overlays/*/ingress.yaml"
    else
        print_info "No overlay ingress manifests found in ${TARGET_DIR}/k8s/apps/. Only core hostnames (localhost, argocd.localhost, kargo.localhost) will be in the cert."
    fi

    apply_local_tls
    print_success "TLS certificates renewed."
}

cmd_argo_init() {
    require_gum
    require_cmd "kubectl" "brew install kubectl"
    load_conf

    # Verify a cluster is reachable
    if ! kubectl cluster-info &>/dev/null; then
        print_error "No reachable cluster found."
        print_info "Make sure your kubectl context points to a running cluster."
        exit 1
    fi

    # Verify ArgoCD is installed
    if ! kubectl get namespace argocd &>/dev/null; then
        print_error "ArgoCD is not installed in the current cluster."
        print_info "Run: cluster-ctl.sh init-cluster"
        exit 1
    fi

    local parent_app="${TARGET_DIR}/argocd/parent-app.yaml"
    if [[ ! -f "$parent_app" ]]; then
        print_error "parent-app.yaml not found at ${parent_app}"
        print_info "Run: infra-ctl.sh init"
        exit 1
    fi

    print_header "ArgoCD Init"

    # Check if parent-app already exists
    if kubectl get application parent-app -n argocd &>/dev/null; then
        local existing_status
        existing_status="$(kubectl get application parent-app -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null)" || true
        local existing_condition
        existing_condition="$(kubectl get application parent-app -n argocd -o jsonpath='{.status.conditions[0].message}' 2>/dev/null)" || true

        if [[ -n "$existing_condition" && ("$existing_condition" == *"authorization failed"* || "$existing_condition" == *"not granted"*) ]]; then
            print_error "parent-app exists but cannot access the repository."
            print_info "$existing_condition"
            print_info "Run: cluster-ctl.sh add-argo-creds"
            exit 1
        fi

        print_warning "parent-app already exists in the cluster (status: ${existing_status:-Unknown})."
        print_info "Use 'cluster-ctl.sh argo-sync' to sync."
        return
    fi

    run_cmd "Applying parent-app to cluster..." \
        --explain "The parent-app is the bootstrap Application that tells ArgoCD to watch argocd/apps/ for child Application manifests. This is a one-time step; after this, ArgoCD manages everything via Git." \
        kubectl apply -f "$parent_app" -n argocd

    # Wait for ArgoCD to reconcile and check for errors
    print_info "Waiting for ArgoCD to reconcile the parent-app..."
    sleep 5

    local sync_status
    sync_status="$(kubectl get application parent-app -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null)" || true

    local condition_msg
    condition_msg="$(kubectl get application parent-app -n argocd -o jsonpath='{.status.conditions[0].message}' 2>/dev/null)" || true

    if [[ "$sync_status" == "Synced" ]]; then
        print_success "ArgoCD initialized. The parent-app is synced."
        print_info "Run 'cluster-ctl.sh argo-sync' to sync all child applications."
    elif [[ -n "$condition_msg" ]]; then
        print_error "parent-app failed to sync."
        print_info "$condition_msg"
        if [[ "$condition_msg" == *"authorization failed"* || "$condition_msg" == *"not granted"* ]]; then
            print_info "If this is a private repo, run: cluster-ctl.sh add-argo-creds"
        fi
        exit 1
    else
        print_warning "parent-app sync status: ${sync_status:-Unknown}"
        print_info "Check the ArgoCD UI or run: kubectl get application parent-app -n argocd -o yaml"
    fi
}

cmd_argo_sync() {
    require_gum
    require_cmd "kubectl" "brew install kubectl"

    # Verify a cluster is reachable
    if ! kubectl cluster-info &>/dev/null; then
        print_error "No reachable cluster found."
        print_info "Make sure your kubectl context points to a running cluster."
        exit 1
    fi

    # Verify ArgoCD is installed
    if ! kubectl get namespace argocd &>/dev/null; then
        print_error "ArgoCD is not installed in the current cluster."
        print_info "Run: cluster-ctl.sh init-cluster"
        exit 1
    fi

    # Verify the ArgoCD server is ready
    if ! kubectl -n argocd get deploy argocd-server &>/dev/null; then
        print_error "ArgoCD server deployment not found."
        exit 1
    fi

    # Bootstrap if parent-app doesn't exist yet
    if ! kubectl get application parent-app -n argocd &>/dev/null; then
        print_info "parent-app not found in cluster. Running argo-init first..."
        cmd_argo_init
    fi

    print_header "ArgoCD Sync"

    # Get the ArgoCD admin password for CLI login
    local argocd_password
    argocd_password="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)" || true

    if [[ -z "$argocd_password" ]]; then
        print_error "Could not retrieve ArgoCD admin password."
        print_info "The argocd-initial-admin-secret may have been deleted."
        exit 1
    fi

    # All argocd commands run inside the server pod where the CLI can reach
    # the API server on localhost:8080 without port-forwarding.
    local argocd_exec=(kubectl -n argocd exec deploy/argocd-server --)

    run_cmd "Logging in to ArgoCD..." \
        --explain "Authenticates with the ArgoCD API server using the admin credentials. The CLI runs inside the server pod and connects to localhost:8080 (the API server's plaintext port)." \
        "${argocd_exec[@]}" argocd login localhost:8080 --insecure --plaintext --username admin --password "$argocd_password"

    # Sync parent app first so child apps are discovered
    run_cmd "Syncing parent-app..." \
        --explain "The parent-app is the 'app of apps' that discovers all Application manifests in argocd/apps/. Syncing it first ensures ArgoCD knows about all child applications." \
        "${argocd_exec[@]}" argocd app sync parent-app --plaintext

    # Brief wait for child apps to be discovered
    sleep 3

    # Get all apps and sync them
    local apps
    apps="$("${argocd_exec[@]}" argocd app list --plaintext -o name 2>/dev/null | grep -v '^parent-app$' || true)"

    if [[ -n "$apps" ]]; then
        local app
        while IFS= read -r app; do
            [[ -z "$app" ]] && continue
            run_cmd "Syncing ${app}..." \
                --explain "Triggers an immediate sync for ${app}, applying the latest Git state to the cluster without waiting for the default 3-minute poll interval." \
                "${argocd_exec[@]}" argocd app sync "$app" --plaintext
        done <<<"$apps"
    fi

    print_success "All applications synced."
}

cmd_argo_status() {
    require_gum
    require_cmd "kubectl" "brew install kubectl"

    # Verify a cluster is reachable
    if ! kubectl cluster-info &>/dev/null; then
        print_error "No reachable cluster found."
        exit 1
    fi

    if ! kubectl get namespace argocd &>/dev/null; then
        print_error "ArgoCD is not installed in the current cluster."
        exit 1
    fi

    print_header "ArgoCD Application Status"

    # Get all applications as JSON for parsing
    local apps_json
    apps_json="$(kubectl get applications -n argocd -o json 2>/dev/null)" || {
        print_warning "No applications found."
        return
    }

    local app_count
    app_count="$(echo "$apps_json" | jq '.items | length')"

    if [[ "$app_count" -eq 0 ]]; then
        print_warning "No applications found. Run: cluster-ctl.sh argo-init"
        return
    fi

    # Summary counts
    local synced degraded progressing errors
    synced="$(echo "$apps_json" | jq '[.items[] | select(.status.sync.status == "Synced")] | length')"
    degraded="$(echo "$apps_json" | jq '[.items[] | select(.status.health.status == "Degraded")] | length')"
    progressing="$(echo "$apps_json" | jq '[.items[] | select(.status.health.status == "Progressing")] | length')"
    errors="$(echo "$apps_json" | jq '[.items[] | select(.status.conditions != null and (.status.conditions | length > 0))] | length')"

    print_info "Applications: ${app_count}  Synced: ${synced}  Progressing: ${progressing}  Degraded: ${degraded}  Errors: ${errors}"
    echo ""

    # Per-app details
    local i
    for ((i = 0; i < app_count; i++)); do
        local name sync health namespace
        name="$(echo "$apps_json" | jq -r ".items[$i].metadata.name")"
        sync="$(echo "$apps_json" | jq -r ".items[$i].status.sync.status // \"Unknown\"")"
        health="$(echo "$apps_json" | jq -r ".items[$i].status.health.status // \"Unknown\"")"
        namespace="$(echo "$apps_json" | jq -r ".items[$i].spec.destination.namespace // \"-\"")"

        # Color-code the status
        local sync_display="$sync"
        local health_display="$health"
        case "$sync" in
            Synced) sync_display="$(gum style --foreground 2 "$sync")" ;;
            OutOfSync) sync_display="$(gum style --foreground 3 "$sync")" ;;
            Unknown) sync_display="$(gum style --foreground 1 "$sync")" ;;
        esac
        case "$health" in
            Healthy) health_display="$(gum style --foreground 2 "$health")" ;;
            Progressing) health_display="$(gum style --foreground 3 "$health")" ;;
            Degraded | Missing) health_display="$(gum style --foreground 1 "$health")" ;;
        esac

        printf "  %-22s  sync: %-12s  health: %-12s  ns: %s\n" "$name" "$sync_display" "$health_display" "$namespace"

        # Show error conditions if any
        local condition
        condition="$(echo "$apps_json" | jq -r ".items[$i].status.conditions[0].message // empty")"
        if [[ -n "$condition" ]]; then
            # Truncate long messages
            if [[ ${#condition} -gt 120 ]]; then
                condition="${condition:0:117}..."
            fi
            print_error "    $condition"
        fi
    done
}

doctor_usage() {
    cat <<EOF
Usage: cluster-ctl.sh doctor [options]

Run cross-layer diagnostic checks against the repo and cluster.

Options:
  --scope <val>       Limit checks to: repo | cluster | all (default: all)
  --app <name>        Limit checks to a single application
  --env <name>        Limit checks to a single environment
  --verbose           Show additional diagnostic detail
  -h, --help          Show this help message
EOF
}

# --- Doctor finding emitters ---
#
# Each doctor_layer_* function resets the three DOCTOR_CURRENT_LAYER_* arrays
# at entry, calls doctor_error/doctor_warn/doctor_info to append findings,
# then calls render_doctor_layer at exit. Findings are stored as
# unit-separator (\x1f) delimited strings to keep each finding as a single
# array element while allowing multi-field payloads.
#
# Field layout:
#   errors/warnings:  subject\x1fmessage\x1fwhy\x1ffix\x1fevidence
#   infos:            subject\x1fmessage
DOCTOR_CURRENT_LAYER_ERRORS=()
DOCTOR_CURRENT_LAYER_WARNINGS=()
DOCTOR_CURRENT_LAYER_INFOS=()

doctor_error() {
    local subject="$1" msg="$2" why="$3" fix="$4"
    shift 4
    local evidence=""
    if [[ $# -gt 0 ]]; then
        evidence="$(printf '%s\n' "$@")"
    fi
    DOCTOR_CURRENT_LAYER_ERRORS+=("${subject}"$'\x1f'"${msg}"$'\x1f'"${why}"$'\x1f'"${fix}"$'\x1f'"${evidence}")
    DOCTOR_ERRORS=$((DOCTOR_ERRORS + 1))
}

doctor_warn() {
    local subject="$1" msg="$2" why="$3" fix="$4"
    shift 4
    local evidence=""
    if [[ $# -gt 0 ]]; then
        evidence="$(printf '%s\n' "$@")"
    fi
    DOCTOR_CURRENT_LAYER_WARNINGS+=("${subject}"$'\x1f'"${msg}"$'\x1f'"${why}"$'\x1f'"${fix}"$'\x1f'"${evidence}")
    DOCTOR_WARNINGS=$((DOCTOR_WARNINGS + 1))
}

doctor_info() {
    local subject="$1" msg="$2"
    DOCTOR_CURRENT_LAYER_INFOS+=("${subject}"$'\x1f'"${msg}")
    DOCTOR_INFOS=$((DOCTOR_INFOS + 1))
}

# Marker for layers with no findings. No-op; render_doctor_layer handles the
# empty case directly.
doctor_clean() {
    :
}

# Gate used by layers that require a live cluster. Appends to
# DOCTOR_SKIPPED_LAYERS and prints a one-liner when the layer can't run.
# Returns 0 when the layer can proceed, 1 when the caller should return early.
needs_cluster_or_skip() {
    local layer_name="$1"
    local reason=""
    if [[ "$DOCTOR_SCOPE" == "repo" ]]; then
        reason="scope=repo"
    elif [[ "$DOCTOR_CLUSTER_REACHABLE" -eq 0 ]]; then
        reason="cluster unreachable"
    else
        return 0
    fi
    DOCTOR_SKIPPED_LAYERS+=("${layer_name} (${reason})")
    local marker header reason_styled
    marker="$(gum style --faint "○")"
    header="$(gum style --bold "${layer_name}")"
    reason_styled="$(gum style --faint "skipped (${reason})")"
    printf "▸ %s %s %s\n" "$header" "$marker" "$reason_styled"
    return 1
}

# Returns 0 if the given app/env pass the --app / --env filters, 1 otherwise.
# An empty app or env argument means "this dimension is not applicable to the
# finding" and will not be checked against the corresponding filter.
doctor_matches_filter() {
    local app="$1" env="$2"
    [[ -n "$DOCTOR_APP" && -n "$app" && "$app" != "$DOCTOR_APP" ]] && return 1
    [[ -n "$DOCTOR_ENV" && -n "$env" && "$env" != "$DOCTOR_ENV" ]] && return 1
    return 0
}

# Reads DOCTOR_CURRENT_LAYER_* arrays and prints either a clean one-liner
# or a gum-bordered box of findings.
render_doctor_layer() {
    local layer_name="$1"

    if [[ ${#DOCTOR_CURRENT_LAYER_ERRORS[@]} -eq 0 \
          && ${#DOCTOR_CURRENT_LAYER_WARNINGS[@]} -eq 0 \
          && ${#DOCTOR_CURRENT_LAYER_INFOS[@]} -eq 0 ]]; then
        local check
        check="$(gum style --foreground 2 "✓")"
        local header
        header="$(gum style --bold "${layer_name}")"
        printf "▸ %s %s\n" "$header" "$check"
        return 0
    fi

    local content=""
    content+="$(gum style --bold "${layer_name}")"$'\n'

    local entry subject msg why fix evidence
    local icon_err icon_warn icon_info
    icon_err="$(gum style --foreground 1 --bold "✗")"
    icon_warn="$(gum style --foreground 3 --bold "⚠")"
    icon_info="$(gum style --faint "ℹ")"

    local first=1
    local -a fields
    for entry in "${DOCTOR_CURRENT_LAYER_ERRORS[@]}"; do
        IFS=$'\x1f' read -r -d '' -a fields < <(printf '%s\x1f\x00' "$entry")
        subject="${fields[0]}"; msg="${fields[1]}"; why="${fields[2]}"; fix="${fields[3]}"; evidence="${fields[4]}"
        if [[ $first -eq 0 ]]; then content+=$'\n'; fi
        first=0
        content+="${icon_err} $(gum style --bold "${subject}")"$'\n'
        content+="    ${msg}"$'\n'
        content+="    $(gum style --faint "why:") ${why}"$'\n'
        content+="    $(gum style --faint "fix:") ${fix}"
        if [[ "$DOCTOR_VERBOSE" -eq 1 && -n "$evidence" ]]; then
            content+=$'\n'"    $(gum style --faint "evidence:")"
            while IFS= read -r line; do
                content+=$'\n'"      ${line}"
            done <<<"$evidence"
        fi
    done

    for entry in "${DOCTOR_CURRENT_LAYER_WARNINGS[@]}"; do
        IFS=$'\x1f' read -r -d '' -a fields < <(printf '%s\x1f\x00' "$entry")
        subject="${fields[0]}"; msg="${fields[1]}"; why="${fields[2]}"; fix="${fields[3]}"; evidence="${fields[4]}"
        if [[ $first -eq 0 ]]; then content+=$'\n'; fi
        first=0
        content+="${icon_warn} $(gum style --bold "${subject}")"$'\n'
        content+="    ${msg}"$'\n'
        content+="    $(gum style --faint "why:") ${why}"$'\n'
        content+="    $(gum style --faint "fix:") ${fix}"
        if [[ "$DOCTOR_VERBOSE" -eq 1 && -n "$evidence" ]]; then
            content+=$'\n'"    $(gum style --faint "evidence:")"
            while IFS= read -r line; do
                content+=$'\n'"      ${line}"
            done <<<"$evidence"
        fi
    done

    for entry in "${DOCTOR_CURRENT_LAYER_INFOS[@]}"; do
        IFS=$'\x1f' read -r -d '' -a fields < <(printf '%s\x1f\x00' "$entry")
        subject="${fields[0]}"; msg="${fields[1]}"
        if [[ $first -eq 0 ]]; then content+=$'\n'; fi
        first=0
        content+="${icon_info} $(gum style --faint "${subject}"): ${msg}"
    done

    gum style --border rounded --padding "0 1" "$content"
}

# Returns the doctor exit code based on accumulated counters:
#   0 = clean (nothing emitted)
#   1 = warnings and/or infos only
#   2 = any errors
doctor_exit_code() {
    if [[ "$DOCTOR_ERRORS" -gt 0 ]]; then
        echo 2
    elif [[ "$DOCTOR_WARNINGS" -gt 0 || "$DOCTOR_INFOS" -gt 0 ]]; then
        echo 1
    else
        echo 0
    fi
}

render_doctor_summary() {
    local layers_checked=9
    local skipped=${#DOCTOR_SKIPPED_LAYERS[@]}
    local code
    code="$(doctor_exit_code)"

    local icon_err icon_warn icon_info
    icon_err="$(gum style --foreground 1 --bold "✗")"
    icon_warn="$(gum style --foreground 3 --bold "⚠")"
    icon_info="$(gum style --faint "ℹ")"

    local content=""
    content+="$(gum style --bold "Summary")"$'\n'
    content+="${layers_checked} layers checked, ${skipped} skipped"$'\n'
    content+="${icon_err} ${DOCTOR_ERRORS} errors  ${icon_warn} ${DOCTOR_WARNINGS} warnings  ${icon_info} ${DOCTOR_INFOS} infos"$'\n'
    content+="Exit: ${code}"

    gum style --border rounded --padding "0 1" "$content"
}

doctor_layer_1_prereqs() {
    DOCTOR_CURRENT_LAYER_ERRORS=()
    DOCTOR_CURRENT_LAYER_WARNINGS=()
    DOCTOR_CURRENT_LAYER_INFOS=()

    local tool
    for tool in kubectl jq helm k3d docker curl; do
        if ! command -v "$tool" &>/dev/null; then
            doctor_error "$tool" \
                "Required CLI not found on PATH" \
                "cluster-ctl.sh doctor depends on \`${tool}\` for cluster inspection" \
                "brew install ${tool}"
        fi
    done

    if ! docker info &>/dev/null; then
        doctor_error "docker" \
            "Docker daemon not running" \
            "kubectl and k3d both need Docker to reach the cluster" \
            "Start Docker Desktop or OrbStack"
    fi

    if [[ "$DOCTOR_SCOPE" != "repo" ]]; then
        if kubectl cluster-info &>/dev/null; then
            DOCTOR_CLUSTER_REACHABLE=1
        else
            doctor_warn "cluster" \
                "Kubernetes cluster not reachable via current kubeconfig context" \
                "layers 2/5/6/7/8/9 need a live cluster" \
                "Run 'cluster-ctl.sh init-cluster' or check your kubeconfig context with 'kubectl config current-context'"
        fi
    fi

    render_doctor_layer "Layer 1: Prerequisites"
}

doctor_layer_2_controllers() {
    DOCTOR_CURRENT_LAYER_ERRORS=()
    DOCTOR_CURRENT_LAYER_WARNINGS=()
    DOCTOR_CURRENT_LAYER_INFOS=()
    needs_cluster_or_skip "Layer 2: Controllers" || return 0

    if ! kubectl get ns argocd &>/dev/null; then
        doctor_error "argocd" \
            "argocd namespace does not exist" \
            "ArgoCD is not installed in this cluster" \
            "Run 'cluster-ctl.sh init-cluster' to install ArgoCD"
        render_doctor_layer "Layer 2: Controllers"
        return 0
    fi

    local deploy avail
    for deploy in argocd-server argocd-repo-server argocd-applicationset-controller; do
        avail="$(kubectl -n argocd get deploy "$deploy" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)"
        if [[ -z "$avail" || "$avail" -eq 0 ]]; then
            doctor_error "$deploy" \
                "ArgoCD deployment not Ready" \
                "${deploy} has 0 available replicas" \
                "Check pod logs: 'kubectl -n argocd describe deploy ${deploy}'"
        fi
    done

    if find "${TARGET_DIR}/k8s/apps" -type f -name 'sealed-secret.yaml' -path '*/overlays/*' 2>/dev/null | grep -q .; then
        avail="$(kubectl -n kube-system get deploy sealed-secrets-controller -o jsonpath='{.status.availableReplicas}' 2>/dev/null)"
        if [[ -z "$avail" || "$avail" -eq 0 ]]; then
            doctor_error "sealed-secrets-controller" \
                "sealed-secrets controller not Ready" \
                "repo contains sealed-secret.yaml overlays but the controller has 0 available replicas" \
                "Run 'secret-ctl.sh init' to install the sealed-secrets controller"
        fi
    fi

    if is_kargo_enabled; then
        avail="$(kubectl -n cert-manager get deploy cert-manager-webhook -o jsonpath='{.status.availableReplicas}' 2>/dev/null)"
        if [[ -z "$avail" || "$avail" -eq 0 ]]; then
            doctor_error "cert-manager-webhook" \
                "cert-manager webhook not Ready" \
                "cert-manager-webhook has 0 available replicas; Kargo depends on cert-manager" \
                "Run 'cluster-ctl.sh upgrade-kargo' or install cert-manager"
        fi

        local kargo_deploy
        for kargo_deploy in kargo-api kargo-controller; do
            avail="$(kubectl -n kargo get deploy "$kargo_deploy" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)"
            if [[ -z "$avail" || "$avail" -eq 0 ]]; then
                doctor_error "$kargo_deploy" \
                    "Kargo deployment not Ready" \
                    "${kargo_deploy} has 0 available replicas" \
                    "Run 'cluster-ctl.sh upgrade-kargo'"
            fi
        done
    fi

    render_doctor_layer "Layer 2: Controllers"
}

doctor_layer_3_repo_structure() {
    DOCTOR_CURRENT_LAYER_ERRORS=()
    DOCTOR_CURRENT_LAYER_WARNINGS=()
    DOCTOR_CURRENT_LAYER_INFOS=()

    if [[ "$DOCTOR_SCOPE" == "cluster" ]]; then
        DOCTOR_SKIPPED_LAYERS+=("Layer 3: Repo structure (scope=cluster)")
        printf "▸ %s %s\n" \
            "$(gum style --bold "Layer 3: Repo structure")" \
            "$(gum style --faint "○ skipped (scope=cluster)")"
        return 0
    fi

    local apps_dir="${TARGET_DIR}/argocd/apps"
    local first_manifest_url=""
    local app_file basename_file meta_name app env app_path app_repo app_project

    if [[ -d "$apps_dir" ]]; then
        for app_file in "$apps_dir"/*.yaml; do
            [[ -f "$app_file" ]] || continue
            basename_file="$(basename "$app_file")"
            # Skip umbrella apps
            [[ "$basename_file" == "projects.yaml" || "$basename_file" == "kargo.yaml" ]] && continue

            meta_name="$(yq eval '.metadata.name // ""' "$app_file" 2>/dev/null)"
            app_path="$(yq eval '.spec.source.path // ""' "$app_file" 2>/dev/null)"
            app_repo="$(yq eval '.spec.source.repoURL // ""' "$app_file" 2>/dev/null)"
            app_project="$(yq eval '.spec.project // ""' "$app_file" 2>/dev/null)"

            # Parse app/env from metadata name: split on last hyphen
            if [[ "$meta_name" == *-* ]]; then
                app="${meta_name%-*}"
                env="${meta_name##*-}"
            else
                app="$meta_name"
                env=""
            fi

            doctor_matches_filter "$app" "$env" || continue

            # Remember first manifest's repoURL for drift check
            if [[ -z "$first_manifest_url" && -n "$app_repo" ]]; then
                first_manifest_url="$app_repo"
            fi

            # Step 2: overlay path existence
            if [[ -n "$app_path" && ! -d "${TARGET_DIR}/${app_path}" ]]; then
                doctor_error "${meta_name}" \
                    "Application references missing overlay path" \
                    "'${app_path}' does not exist under ${TARGET_DIR}" \
                    "Create the overlay directory or fix 'spec.source.path' in argocd/apps/${basename_file}"
            fi

            # Step 3: AppProject existence
            if [[ -n "$app_project" && "$app_project" != "default" ]]; then
                if [[ ! -f "${TARGET_DIR}/argocd/projects/${app_project}.yaml" ]]; then
                    doctor_error "${meta_name}" \
                        "Application references missing AppProject" \
                        "project '${app_project}' has no manifest in argocd/projects/" \
                        "Run 'infra-ctl.sh add-project <name>' or change to 'default' project"
                fi
            fi
        done
    fi

    # Step 4: Kargo promotion-order envs
    if is_kargo_enabled; then
        read_promotion_order
        local promo_env
        for promo_env in "${PROMOTION_ORDER[@]}"; do
            if [[ ! -f "${TARGET_DIR}/k8s/namespaces/${promo_env}.yaml" ]]; then
                doctor_warn "promotion-order" \
                    "Promotion order references env without namespace" \
                    "env '${promo_env}' in kargo/promotion-order.txt has no k8s/namespaces/${promo_env}.yaml" \
                    "Run 'infra-ctl.sh add-env ${promo_env}' or remove from kargo/promotion-order.txt"
            fi
        done
    fi

    # Step 5: Repo URL drift
    if [[ -f "${TARGET_DIR}/.infra-ctl.conf" && -n "$first_manifest_url" ]]; then
        load_conf
        if [[ -n "$REPO_URL" && "$REPO_URL" != "$first_manifest_url" ]]; then
            doctor_warn ".infra-ctl.conf" \
                "REPO_URL differs from Application manifests" \
                "conf says '${REPO_URL}', first Application manifest says '${first_manifest_url}'" \
                "Update .infra-ctl.conf REPO_URL or fix Application manifests"
        fi
    fi

    render_doctor_layer "Layer 3: Repo structure"
}

# Returns distinct Secret names referenced by a workload's base manifests.
# Scans for secretKeyRef.name and envFrom[].secretRef.name in Deployment and
# StatefulSet manifests under k8s/apps/<app>/base/.
# Usage: scan_workload_secret_refs <app>
scan_workload_secret_refs() {
    local app="$1"
    local base_dir="${TARGET_DIR}/k8s/apps/${app}/base"
    [[ ! -d "$base_dir" ]] && return 0

    local file
    {
        for file in "$base_dir"/*.yaml; do
            [[ ! -f "$file" ]] && continue
            yq eval '.. | select(has("secretKeyRef")).secretKeyRef.name' "$file" 2>/dev/null
            yq eval '.. | select(has("secretRef")).secretRef.name' "$file" 2>/dev/null
        done
    } | awk 'NF && $0 != "null"' | sort -u
}

# Returns distinct ConfigMap names referenced by a workload's base manifests.
# Usage: scan_workload_configmap_refs <app>
scan_workload_configmap_refs() {
    local app="$1"
    local base_dir="${TARGET_DIR}/k8s/apps/${app}/base"
    [[ ! -d "$base_dir" ]] && return 0

    local file
    {
        for file in "$base_dir"/*.yaml; do
            [[ ! -f "$file" ]] && continue
            yq eval '.. | select(has("configMapKeyRef")).configMapKeyRef.name' "$file" 2>/dev/null
            yq eval '.. | select(has("configMapRef")).configMapRef.name' "$file" 2>/dev/null
        done
    } | awk 'NF && $0 != "null"' | sort -u
}

# Returns 0 if the overlay supplies a Secret/SealedSecret with the given name,
# 1 otherwise. Checks:
#   (a) any file in the overlay's kustomization resources list defines a
#       Secret or SealedSecret with metadata.name == <secret_name>
#   (b) the overlay's kustomization has a secretGenerator with that name
# Checks the base kustomization's secretGenerator as fallback.
# Usage: overlay_has_secret_manifest <app> <env> <secret_name>
overlay_has_secret_manifest() {
    local app="$1" env="$2" secret_name="$3"
    local overlay_kust="${TARGET_DIR}/k8s/apps/${app}/overlays/${env}/kustomization.yaml"
    local overlay_dir="${TARGET_DIR}/k8s/apps/${app}/overlays/${env}"
    local base_kust="${TARGET_DIR}/k8s/apps/${app}/base/kustomization.yaml"

    # Check (b) overlay secretGenerator
    if [[ -f "$overlay_kust" ]]; then
        local gen_names
        gen_names="$(yq eval '.secretGenerator[]?.name' "$overlay_kust" 2>/dev/null)"
        if grep -Fqx -- "$secret_name" <<<"$gen_names"; then
            return 0
        fi
    fi

    # Check (a) resources listed in overlay kustomization that define the Secret
    local resource resource_path
    while IFS= read -r resource; do
        [[ -z "$resource" ]] && continue
        # Skip directory references and non-local refs
        [[ "$resource" == *..* || "$resource" == /* || "$resource" == http* ]] && continue
        resource_path="${overlay_dir}/${resource}"
        [[ ! -f "$resource_path" ]] && continue
        # Check if this file defines a Secret or SealedSecret with the right name.
        # Files may contain multiple docs; use yq to select matching doc.
        local found_name
        found_name="$(yq eval 'select(.kind == "Secret" or .kind == "SealedSecret") | .metadata.name' "$resource_path" 2>/dev/null | grep -Fxv "" | head -n 1)"
        if [[ "$found_name" == "$secret_name" ]]; then
            return 0
        fi
    done < <(kustomization_resources "$overlay_kust")

    # Check base kustomization's secretGenerator (rarely used but valid)
    if [[ -f "$base_kust" ]]; then
        local base_gen_names
        base_gen_names="$(yq eval '.secretGenerator[]?.name' "$base_kust" 2>/dev/null)"
        if grep -Fqx -- "$secret_name" <<<"$base_gen_names"; then
            return 0
        fi
    fi

    return 1
}

# Returns 0 if the overlay supplies a ConfigMap with the given name, 1 otherwise.
# Mirrors overlay_has_secret_manifest but checks configMapGenerator and
# kind: ConfigMap. Also checks the base kustomization's configMapGenerator.
# Usage: overlay_has_configmap_manifest <app> <env> <cm_name>
overlay_has_configmap_manifest() {
    local app="$1" env="$2" cm_name="$3"
    local overlay_kust="${TARGET_DIR}/k8s/apps/${app}/overlays/${env}/kustomization.yaml"
    local overlay_dir="${TARGET_DIR}/k8s/apps/${app}/overlays/${env}"
    local base_kust="${TARGET_DIR}/k8s/apps/${app}/base/kustomization.yaml"

    # Check overlay configMapGenerator
    if [[ -f "$overlay_kust" ]]; then
        local gen_names
        gen_names="$(yq eval '.configMapGenerator[]?.name' "$overlay_kust" 2>/dev/null)"
        if grep -Fqx -- "$cm_name" <<<"$gen_names"; then
            return 0
        fi
    fi

    # Check resources listed in overlay kustomization that define the ConfigMap
    local resource resource_path
    while IFS= read -r resource; do
        [[ -z "$resource" ]] && continue
        [[ "$resource" == *..* || "$resource" == /* || "$resource" == http* ]] && continue
        resource_path="${overlay_dir}/${resource}"
        [[ ! -f "$resource_path" ]] && continue
        local found_name
        found_name="$(yq eval 'select(.kind == "ConfigMap") | .metadata.name' "$resource_path" 2>/dev/null | grep -Fxv "" | head -n 1)"
        if [[ "$found_name" == "$cm_name" ]]; then
            return 0
        fi
    done < <(kustomization_resources "$overlay_kust")

    # Check base kustomization's configMapGenerator (typical case)
    if [[ -f "$base_kust" ]]; then
        local base_gen_names
        base_gen_names="$(yq eval '.configMapGenerator[]?.name' "$base_kust" 2>/dev/null)"
        if grep -Fqx -- "$cm_name" <<<"$base_gen_names"; then
            return 0
        fi
    fi

    return 1
}

doctor_layer_4_alignment() {
    DOCTOR_CURRENT_LAYER_ERRORS=()
    DOCTOR_CURRENT_LAYER_WARNINGS=()
    DOCTOR_CURRENT_LAYER_INFOS=()

    if [[ "$DOCTOR_SCOPE" == "cluster" ]]; then
        DOCTOR_SKIPPED_LAYERS+=("Layer 4: Alignment (scope=cluster)")
        printf "▸ %s %s\n" \
            "$(gum style --bold "Layer 4: Alignment")" \
            "$(gum style --faint "○ skipped (scope=cluster)")"
        return 0
    fi

    local apps_dir="${TARGET_DIR}/argocd/apps"
    local app_file basename_file meta_name app env

    if [[ -d "$apps_dir" ]]; then
        for app_file in "$apps_dir"/*.yaml; do
            [[ -f "$app_file" ]] || continue
            basename_file="$(basename "$app_file")"
            [[ "$basename_file" == "projects.yaml" || "$basename_file" == "kargo.yaml" ]] && continue

            meta_name="$(yq eval '.metadata.name // ""' "$app_file" 2>/dev/null)"
            [[ -z "$meta_name" ]] && continue

            if [[ "$meta_name" == *-* ]]; then
                app="${meta_name%-*}"
                env="${meta_name##*-}"
            else
                app="$meta_name"
                env=""
            fi

            doctor_matches_filter "$app" "$env" || continue
            seen_pairs+=("${app}:${env}")

            # Secret refs
            local secrets secret
            secrets="$(scan_workload_secret_refs "$app")"
            while IFS= read -r secret; do
                [[ -z "$secret" ]] && continue
                if ! overlay_has_secret_manifest "$app" "$env" "$secret"; then
                    doctor_error "${app}-${env}" \
                        "Secret '${secret}' referenced but not in overlay" \
                        "base manifest uses secretKeyRef/envFrom for '${secret}', but overlays/${env}/kustomization.yaml does not include a sealed-secret or secretGenerator for it" \
                        "secret-ctl.sh add ${app} ${env}" \
                        "k8s/apps/${app}/base/ references secretKeyRef.name: ${secret}" \
                        "k8s/apps/${app}/overlays/${env}/kustomization.yaml does not provide the secret"
                fi
            done <<<"$secrets"

            # ConfigMap refs (warnings)
            local configmaps cm
            configmaps="$(scan_workload_configmap_refs "$app")"
            while IFS= read -r cm; do
                [[ -z "$cm" ]] && continue
                if ! overlay_has_configmap_manifest "$app" "$env" "$cm"; then
                    doctor_warn "${app}-${env}" \
                        "ConfigMap '${cm}' referenced but not in overlay" \
                        "base manifest uses configMapKeyRef/envFrom for '${cm}', but neither base nor overlays/${env}/kustomization.yaml provides a configMapGenerator or ConfigMap manifest for it" \
                        "Add configMapGenerator to k8s/apps/${app}/base/kustomization.yaml or overlays/${env}/kustomization.yaml" \
                        "k8s/apps/${app}/base/ references configMapRef/configMapKeyRef name: ${cm}" \
                        "neither base nor overlays/${env} supplies a ConfigMap named '${cm}'"
                fi
            done <<<"$configmaps"
        done
    fi

    # Orphaned sealed-secret check
    local ss_file rel path_in_repo orphan_app orphan_env overlay_kust resources_list
    for ss_file in "${TARGET_DIR}"/k8s/apps/*/overlays/*/sealed-secret.yaml; do
        [[ -f "$ss_file" ]] || continue
        # Extract app and env from path: .../k8s/apps/<app>/overlays/<env>/sealed-secret.yaml
        rel="${ss_file#${TARGET_DIR}/k8s/apps/}"
        orphan_app="${rel%%/*}"
        rel="${rel#*/overlays/}"
        orphan_env="${rel%%/*}"

        doctor_matches_filter "$orphan_app" "$orphan_env" || continue

        overlay_kust="${TARGET_DIR}/k8s/apps/${orphan_app}/overlays/${orphan_env}/kustomization.yaml"
        [[ -f "$overlay_kust" ]] || continue
        resources_list="$(kustomization_resources "$overlay_kust")"
        if ! grep -Fqx -- "sealed-secret.yaml" <<<"$resources_list"; then
            doctor_error "${orphan_app}-${orphan_env}" \
                "sealed-secret.yaml exists but not wired into kustomization" \
                "k8s/apps/${orphan_app}/overlays/${orphan_env}/sealed-secret.yaml is on disk but not listed in the kustomization's resources" \
                "Add '- sealed-secret.yaml' to the resources list in k8s/apps/${orphan_app}/overlays/${orphan_env}/kustomization.yaml" \
                "file exists: k8s/apps/${orphan_app}/overlays/${orphan_env}/sealed-secret.yaml" \
                "overlay kustomization.yaml resources list does not reference it"
        fi
    done

    render_doctor_layer "Layer 4: Alignment"
}

doctor_layer_5_credentials() {
    DOCTOR_CURRENT_LAYER_ERRORS=()
    DOCTOR_CURRENT_LAYER_WARNINGS=()
    DOCTOR_CURRENT_LAYER_INFOS=()

    needs_cluster_or_skip "Layer 5: Credentials" || return 0

    # --- Private repo check: ArgoCD repo credentials ---
    local is_private="" repo_full_name=""
    if [[ -f "${TARGET_DIR}/.infra-ctl.conf" ]]; then
        load_conf
        if [[ -n "${REPO_URL:-}" ]]; then
            repo_full_name="$(echo "$REPO_URL" | sed -E 's|^https?://github\.com/||; s|\.git$||')"
            if command -v gh >/dev/null 2>&1; then
                is_private="$(gh repo view "$repo_full_name" --json isPrivate -q .isPrivate 2>/dev/null)" || is_private=""
            fi
        fi
    else
        doctor_info ".infra-ctl.conf" "missing; skipping private-repo credential checks"
    fi

    if [[ "$is_private" == "true" ]]; then
        local repo_secrets_count
        repo_secrets_count="$(kubectl -n argocd get secrets -l argocd.argoproj.io/secret-type=repository -o name 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "$repo_secrets_count" == "0" ]]; then
            doctor_error "argocd-repo-creds" \
                "Private repo without ArgoCD repo credentials" \
                "ArgoCD cannot sync from a private repository without authentication; repo ${repo_full_name} is private" \
                "Run 'cluster-ctl.sh add-argo-creds'"
        fi
    elif [[ -z "$is_private" && -n "$repo_full_name" ]]; then
        doctor_info "gh" "could not determine privacy of ${repo_full_name}; skipping ArgoCD repo-cred check"
    fi

    # --- Registry credentials check per environment ---
    declare -A seen=()
    local env
    while IFS= read -r env; do
        [[ -z "$env" ]] && continue
        doctor_matches_filter "" "$env" || continue
        # Namespace may not exist yet
        kubectl get ns "$env" >/dev/null 2>&1 || continue
        local images
        images="$(kubectl -n "$env" get pods -o jsonpath='{.items[*].spec.containers[*].image}' 2>/dev/null | tr ' ' '\n' | sort -u)"
        [[ -z "$images" ]] && continue
        local has_pull_secrets
        has_pull_secrets="$(kubectl -n "$env" get sa default -o jsonpath='{.imagePullSecrets}' 2>/dev/null)"
        local image first_segment registry key
        while IFS= read -r image; do
            [[ -z "$image" ]] && continue
            first_segment="${image%%/*}"
            if [[ "$image" == *"/"* && ( "$first_segment" == *.* || "$first_segment" == *:* || "$first_segment" == "localhost" ) ]]; then
                registry="$first_segment"
            else
                registry="docker.io"
            fi
            [[ "$registry" == "docker.io" ]] && continue
            [[ -n "$has_pull_secrets" ]] && continue
            key="${env}:${registry}"
            if [[ -z "${seen[$key]:-}" ]]; then
                seen[$key]=1
                doctor_warn "${env}/${registry}" \
                    "Non-docker.io image without imagePullSecret" \
                    "pods in namespace '${env}' use images from '${registry}', but the namespace's default ServiceAccount has no imagePullSecrets configured" \
                    "Run 'cluster-ctl.sh add-registry-creds'"
            fi
        done <<<"$images"
    done < <(detect_envs)

    # --- Kargo git credentials check (private repo + Kargo enabled) ---
    if is_kargo_enabled && [[ "$is_private" == "true" ]]; then
        local kargo_app_dir kargo_ns kargo_git_secrets
        if [[ -d "${TARGET_DIR}/kargo" ]]; then
            for kargo_app_dir in "${TARGET_DIR}"/kargo/*/; do
                [[ -d "$kargo_app_dir" ]] || continue
                kargo_ns="$(basename "$kargo_app_dir")"
                # Namespace may not exist yet; skip silently
                kubectl get ns "$kargo_ns" >/dev/null 2>&1 || continue
                kargo_git_secrets="$(kubectl -n "$kargo_ns" get secrets -l kargo.akuity.io/cred-type=git -o name 2>/dev/null | wc -l | tr -d ' ')"
                if [[ "$kargo_git_secrets" == "0" ]]; then
                    doctor_warn "${kargo_ns}" \
                        "Kargo missing git credentials for private repo" \
                        "Kargo cannot discover freight from a private git repo without credentials" \
                        "Run 'cluster-ctl.sh add-kargo-creds'"
                fi
            done
        fi
    fi

    render_doctor_layer "Layer 5: Credentials"
}

doctor_layer_6_runtime() {
    DOCTOR_CURRENT_LAYER_ERRORS=()
    DOCTOR_CURRENT_LAYER_WARNINGS=()
    DOCTOR_CURRENT_LAYER_INFOS=()

    needs_cluster_or_skip "Layer 6: Runtime" || return 0

    local apps_json
    apps_json="$(kubectl get applications -n argocd -o json 2>/dev/null)" || apps_json=""
    if [[ -z "$apps_json" ]]; then
        render_doctor_layer "Layer 6: Runtime"
        return 0
    fi

    # --- ArgoCD Application health summary ---
    # Emit rows: name<TAB>sync<TAB>health<TAB>destNs<TAB>condMsg
    # Skip umbrella apps (projects, kargo, or destination ns == argocd).
    local app_rows
    app_rows="$(jq -r '
        .items[]
        | select(.metadata.name != "projects" and .metadata.name != "kargo")
        | select((.spec.destination.namespace // "") != "argocd")
        | [
            .metadata.name,
            (.status.sync.status // "Unknown"),
            (.status.health.status // "Unknown"),
            (.spec.destination.namespace // ""),
            (.status.conditions[0].message // "")
          ] | @tsv
    ' <<<"$apps_json")"

    # Collect the set of target namespaces from the filtered apps.
    declare -A target_namespaces=()

    local line name sync health dest_ns cond_msg app env why
    while IFS=$'\t' read -r name sync health dest_ns cond_msg; do
        [[ -z "$name" ]] && continue
        # Parse app / env via last-hyphen split.
        app="${name%-*}"
        env="${name##*-}"
        doctor_matches_filter "$app" "$env" || continue

        # Record destination namespace for the pod/pvc/svc scans below.
        [[ -n "$dest_ns" ]] && target_namespaces["$dest_ns"]=1

        # Healthy + Synced: nothing to report.
        if [[ "$health" == "Healthy" && "$sync" == "Synced" ]]; then
            continue
        fi

        why="$cond_msg"
        [[ -z "$why" ]] && why="sync=${sync} health=${health}"
        if [[ ${#why} -gt 120 ]]; then
            why="${why:0:117}..."
        fi

        if [[ "$health" == "Degraded" || "$health" == "Missing" ]]; then
            doctor_error "$name" \
                "ArgoCD Application is ${health}" \
                "$why" \
                "Check 'kubectl -n argocd describe app ${name}'"
        elif [[ "$health" == "Progressing" ]]; then
            doctor_warn "$name" \
                "ArgoCD Application has not converged (Progressing)" \
                "$why" \
                "Check pod events: 'kubectl -n ${dest_ns} get events --sort-by=.lastTimestamp'"
        elif [[ "$health" == "Unknown" || "$sync" == "Unknown" ]]; then
            doctor_warn "$name" \
                "ArgoCD Application status is Unknown" \
                "$why" \
                "Check 'kubectl -n argocd describe app ${name}'"
        fi
    done <<<"$app_rows"

    # --- Pod failure scan across target namespaces ---
    local ns pod_rows pod_name reason wait_msg
    for ns in "${!target_namespaces[@]}"; do
        doctor_matches_filter "" "$ns" || continue
        kubectl get ns "$ns" >/dev/null 2>&1 || continue
        pod_rows="$(kubectl get pods -n "$ns" -o json 2>/dev/null | jq -r '
            .items[]
            | select(
                (.status.containerStatuses // []) | any(
                    (.state.waiting.reason // "") as $r
                    | $r == "CreateContainerConfigError"
                      or $r == "ImagePullBackOff"
                      or $r == "ErrImagePull"
                      or $r == "CrashLoopBackOff"
                )
              )
            | [
                .metadata.name,
                ((.status.containerStatuses // [])
                    | map(select((.state.waiting.reason // "") != "")) | .[0].state.waiting.reason // ""),
                ((.status.containerStatuses // [])
                    | map(select((.state.waiting.reason // "") != "")) | .[0].state.waiting.message // "")
              ] | @tsv
        ')" || pod_rows=""
        [[ -z "$pod_rows" ]] && continue
        while IFS=$'\t' read -r pod_name reason wait_msg; do
            [[ -z "$pod_name" ]] && continue
            [[ -z "$wait_msg" ]] && wait_msg="check pod events"
            if [[ ${#wait_msg} -gt 120 ]]; then
                wait_msg="${wait_msg:0:117}..."
            fi
            doctor_error "${ns}/${pod_name}" \
                "Pod in \`${reason}\` state" \
                "$wait_msg" \
                "Check 'kubectl -n ${ns} describe pod ${pod_name}'"
        done <<<"$pod_rows"
    done

    # --- PVC scan: stuck Pending ---
    local pvc_name pvc_rows
    for ns in "${!target_namespaces[@]}"; do
        doctor_matches_filter "" "$ns" || continue
        kubectl get ns "$ns" >/dev/null 2>&1 || continue
        pvc_rows="$(kubectl -n "$ns" get pvc -o json 2>/dev/null | jq -r '
            .items[] | select(.status.phase == "Pending") | .metadata.name
        ')" || pvc_rows=""
        [[ -z "$pvc_rows" ]] && continue
        while IFS= read -r pvc_name; do
            [[ -z "$pvc_name" ]] && continue
            doctor_error "${ns}/${pvc_name}" \
                "PVC stuck in Pending" \
                "no storage class or provisioner available" \
                "Check 'kubectl get storageclass' and 'kubectl -n ${ns} describe pvc ${pvc_name}'"
        done <<<"$pvc_rows"
    done

    # --- Service endpoints scan: services with no ready backends ---
    # We check for services whose Endpoints object has no ready addresses across
    # all subsets. notReadyAddresses are excluded (e.g., pods stuck init/CCE).
    local svc_name svc_list ready_count
    for ns in "${!target_namespaces[@]}"; do
        doctor_matches_filter "" "$ns" || continue
        kubectl get ns "$ns" >/dev/null 2>&1 || continue
        svc_list="$(kubectl -n "$ns" get svc -o json 2>/dev/null | jq -r '
            .items[]
            | select((.spec.selector // {}) | length > 0)
            | .metadata.name
        ')" || svc_list=""
        [[ -z "$svc_list" ]] && continue
        while IFS= read -r svc_name; do
            [[ -z "$svc_name" ]] && continue
            ready_count="$(kubectl -n "$ns" get endpoints "$svc_name" -o json 2>/dev/null \
                | jq -r '[(.subsets // [])[] | (.addresses // [])[]] | length' 2>/dev/null)"
            ready_count="${ready_count:-0}"
            if [[ "$ready_count" == "0" ]]; then
                doctor_warn "${ns}/${svc_name}" \
                    "Service has no endpoints" \
                    "selector may not match any ready pods" \
                    "Verify pod labels match service selector; check 'kubectl -n ${ns} get endpoints ${svc_name}'"
            fi
        done <<<"$svc_list"
    done

    render_doctor_layer "Layer 6: Runtime"
}

doctor_layer_7_images() {
    DOCTOR_CURRENT_LAYER_ERRORS=()
    DOCTOR_CURRENT_LAYER_WARNINGS=()
    DOCTOR_CURRENT_LAYER_INFOS=()

    needs_cluster_or_skip "Layer 7: Image reachability" || return 0

    if ! command -v crane &>/dev/null; then
        echo ""
        if gum confirm "crane enables image reachability checks. Install via 'brew install crane'?"; then
            if ! run_cmd "Installing crane..." \
                --explain "crane is the google/go-containerregistry CLI for inspecting container image manifests. Doctor uses 'crane digest' to verify each image tag referenced by pods actually exists in its registry." \
                brew install crane; then
                doctor_info "crane" "crane install failed; skipping image reachability checks"
                DOCTOR_SKIPPED_LAYERS+=("Layer 7: Image reachability (install failed)")
                render_doctor_layer "Layer 7: Image reachability"
                return 0
            fi
        else
            DOCTOR_SKIPPED_LAYERS+=("Layer 7: Image reachability (crane not installed)")
            printf "▸ %s %s\n" \
                "$(gum style --bold "Layer 7: Image reachability")" \
                "$(gum style --faint "○ skipped (install crane later to enable)")"
            return 0
        fi
    fi

    # Collect target namespaces from ArgoCD Applications (same pattern as Layer 6).
    local apps_json
    apps_json="$(kubectl get applications -n argocd -o json 2>/dev/null)" || apps_json=""
    if [[ -z "$apps_json" ]]; then
        render_doctor_layer "Layer 7: Image reachability"
        return 0
    fi

    local app_rows
    app_rows="$(jq -r '
        .items[]
        | select(.metadata.name != "projects" and .metadata.name != "kargo")
        | select((.spec.destination.namespace // "") != "argocd")
        | [
            .metadata.name,
            (.spec.destination.namespace // "")
          ] | @tsv
    ' <<<"$apps_json")"

    declare -A target_namespaces=()
    local line name dest_ns app env
    while IFS=$'\t' read -r name dest_ns; do
        [[ -z "$name" ]] && continue
        app="${name%-*}"
        env="${name##*-}"
        doctor_matches_filter "$app" "$env" || continue
        [[ -n "$dest_ns" ]] && target_namespaces["$dest_ns"]=1
    done <<<"$app_rows"

    # Collect distinct image refs from pods in target namespaces.
    local -A seen_images=()
    local ns image
    for ns in "${!target_namespaces[@]}"; do
        doctor_matches_filter "" "$ns" || continue
        kubectl get ns "$ns" >/dev/null 2>&1 || continue
        while IFS= read -r image; do
            [[ -z "$image" ]] && continue
            seen_images["$image"]=1
        done < <(kubectl -n "$ns" get pods -o jsonpath='{.items[*].spec.containers[*].image}' 2>/dev/null | tr ' ' '\n' | sort -u)
    done

    # Check each distinct image via 'crane digest'.
    for image in "${!seen_images[@]}"; do
        if ! crane digest "$image" &>/dev/null; then
            doctor_warn "$image" \
                "Image tag not resolvable via registry" \
                "'crane digest' could not fetch the manifest for this image; tag may be wrong, the image may not exist, or the registry may require authentication" \
                "Check for typos in the image ref; if private registry, run 'cluster-ctl.sh add-registry-creds'" \
                "crane digest ${image} → failed"
        fi
    done

    render_doctor_layer "Layer 7: Image reachability"
}

doctor_layer_8_ingress() {
    DOCTOR_CURRENT_LAYER_ERRORS=()
    DOCTOR_CURRENT_LAYER_WARNINGS=()
    DOCTOR_CURRENT_LAYER_INFOS=()
    render_doctor_layer "Layer 8: Ingress"
}

doctor_layer_9_hygiene() {
    DOCTOR_CURRENT_LAYER_ERRORS=()
    DOCTOR_CURRENT_LAYER_WARNINGS=()
    DOCTOR_CURRENT_LAYER_INFOS=()
    render_doctor_layer "Layer 9: Hygiene"
}

cmd_doctor() {
    # --- Doctor state (shared across layer_* functions) ---
    # These globals are intentionally shared because each doctor_layer_* function
    # needs to read DOCTOR_VERBOSE/DOCTOR_SCOPE/etc and mutate the counters.
    # Declared here (not `local`) so layer functions can access them.
    DOCTOR_ERRORS=0
    DOCTOR_WARNINGS=0
    DOCTOR_INFOS=0
    DOCTOR_SKIPPED_LAYERS=()
    DOCTOR_VERBOSE=0
    DOCTOR_SCOPE="all"
    DOCTOR_APP=""
    DOCTOR_ENV=""
    DOCTOR_CLUSTER_REACHABLE=0

    # Parse flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --scope=*)
                DOCTOR_SCOPE="${1#*=}"
                shift
                ;;
            --scope)
                if [[ $# -lt 2 ]]; then
                    print_error "--scope requires a value (repo|cluster|all)"
                    exit 1
                fi
                DOCTOR_SCOPE="$2"
                shift 2
                ;;
            --app=*)
                DOCTOR_APP="${1#*=}"
                shift
                ;;
            --app)
                if [[ $# -lt 2 ]]; then
                    print_error "--app requires a value"
                    exit 1
                fi
                DOCTOR_APP="$2"
                shift 2
                ;;
            --env=*)
                DOCTOR_ENV="${1#*=}"
                shift
                ;;
            --env)
                if [[ $# -lt 2 ]]; then
                    print_error "--env requires a value"
                    exit 1
                fi
                DOCTOR_ENV="$2"
                shift 2
                ;;
            --verbose)
                DOCTOR_VERBOSE=1
                shift
                ;;
            -h | --help)
                doctor_usage
                exit 0
                ;;
            *)
                print_error "Unknown flag: $1"
                doctor_usage
                exit 1
                ;;
        esac
    done

    # Validate scope
    case "$DOCTOR_SCOPE" in
        repo | cluster | all) ;;
        *)
            print_error "Invalid --scope value: '$DOCTOR_SCOPE' (must be repo|cluster|all)"
            exit 1
            ;;
    esac

    # Validate --app against detect_apps
    if [[ -n "$DOCTOR_APP" ]]; then
        local valid_apps
        valid_apps="$(detect_apps)"
        if ! grep -Fqx -- "$DOCTOR_APP" <<<"$valid_apps"; then
            print_error "Unknown app: '$DOCTOR_APP'"
            if [[ -n "$valid_apps" ]]; then
                print_info "Available apps:"
                while IFS= read -r a; do
                    [[ -z "$a" ]] && continue
                    print_info "  - $a"
                done <<<"$valid_apps"
            fi
            exit 1
        fi
    fi

    # Validate --env against detect_envs
    if [[ -n "$DOCTOR_ENV" ]]; then
        local valid_envs
        valid_envs="$(detect_envs)"
        if ! grep -Fqx -- "$DOCTOR_ENV" <<<"$valid_envs"; then
            print_error "Unknown env: '$DOCTOR_ENV'"
            if [[ -n "$valid_envs" ]]; then
                print_info "Available envs:"
                while IFS= read -r e; do
                    [[ -z "$e" ]] && continue
                    print_info "  - $e"
                done <<<"$valid_envs"
            fi
            exit 1
        fi
    fi

    print_header "Cluster Doctor"

    doctor_layer_1_prereqs
    doctor_layer_2_controllers
    doctor_layer_3_repo_structure
    doctor_layer_4_alignment
    doctor_layer_5_credentials
    doctor_layer_6_runtime
    doctor_layer_7_images
    doctor_layer_8_ingress
    doctor_layer_9_hygiene

    echo ""
    render_doctor_summary
    return "$(doctor_exit_code)"
}

# --- Usage ---

cmd_preflight_check() {
    echo "  cluster-ctl.sh dependencies:"
    preflight_check \
        "gum:brew install gum" \
        "gh:brew install gh" \
        "k3d:brew install k3d" \
        "kubectl:brew install kubectl" \
        "jq:brew install jq" \
        "helm:brew install helm" \
        "docker:https://docs.docker.com/get-docker/"

    if command -v docker &>/dev/null; then
        if docker info &>/dev/null; then
            printf "  ✓ %-12s %s\n" "docker" "daemon running"
        else
            printf "  ✗ %-12s %s\n" "docker" "daemon NOT running (start Docker or OrbStack)"
        fi
    fi
}

usage() {
    cat <<EOF
Usage: cluster-ctl.sh <command> [options]

Commands:
  init-cluster        Create a local k3d cluster and optionally install ArgoCD
  delete-cluster [name]  Tear down a k3d cluster
  add-argo-creds      Configure ArgoCD access to a private Git repository
  add-registry-creds  Configure container registry credentials for image pulls
  add-kargo-creds     Configure Kargo access to a private Git repo and container registry
  upgrade-argocd      Re-apply ArgoCD Helm values (after editing helm/argocd-values.yaml)
  upgrade-kargo       Re-apply Kargo Helm release
  argo-init           Bootstrap ArgoCD by applying the parent-app to the cluster
  argo-sync           Force ArgoCD to sync all applications immediately
  argo-status         Show sync status, health, and errors for all ArgoCD applications
  doctor              Run cross-layer diagnostic checks against repo and cluster
  renew-tls           Regenerate mkcert certificates and update the cluster
  status              Show cluster and ArgoCD health
  preflight-check     Verify all required tools are installed
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
        init-cluster) cmd_init_cluster "$@" ;;
        delete-cluster) cmd_delete_cluster "$@" ;;
        add-argo-creds) cmd_add_argo_creds "$@" ;;
        add-registry-creds) cmd_add_registry_creds "$@" ;;
        add-kargo-creds) cmd_add_kargo_creds "$@" ;;
        upgrade-argocd) cmd_upgrade_argocd "$@" ;;
        upgrade-kargo) cmd_upgrade_kargo "$@" ;;
        argo-init) cmd_argo_init "$@" ;;
        argo-sync) cmd_argo_sync "$@" ;;
        argo-status) cmd_argo_status "$@" ;;
        doctor) cmd_doctor "$@" ;;
        renew-tls) cmd_renew_tls "$@" ;;
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
