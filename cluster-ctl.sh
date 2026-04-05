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

    # --- Parse flags ---
    local name_flag="" agents_flag=""
    local expose_flag="" tls_flag="" argocd_flag="" kargo_flag=""
    local kargo_password_flag=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)
                require_flag_value "--name" "${2:-}"
                name_flag="$2"
                shift 2
                ;;
            --agents)
                require_flag_value "--agents" "${2:-}"
                agents_flag="$2"
                shift 2
                ;;
            --expose-ports)
                expose_flag="true"
                shift
                ;;
            --no-expose-ports)
                expose_flag="false"
                shift
                ;;
            --tls)
                tls_flag="true"
                shift
                ;;
            --no-tls)
                tls_flag="false"
                shift
                ;;
            --argocd)
                argocd_flag="true"
                shift
                ;;
            --no-argocd)
                argocd_flag="false"
                shift
                ;;
            --kargo)
                kargo_flag="true"
                shift
                ;;
            --no-kargo)
                kargo_flag="false"
                shift
                ;;
            --kargo-password)
                require_flag_value "--kargo-password" "${2:-}"
                kargo_password_flag="$2"
                shift 2
                ;;
            -h | --help)
                cat <<EOF
Usage: cluster-ctl.sh init-cluster [flags]

Flags:
  --name <string>        Cluster name (default: current dir basename)
  --agents <n>           Agent node count (default: 3)
  --expose-ports         Expose 80/443 on localhost (for ingress)
  --no-expose-ports      Don't expose ports (default)
  --tls                  Enable HTTPS via mkcert
  --no-tls               Disable HTTPS (default)
  --argocd               Install ArgoCD
  --no-argocd            Skip ArgoCD (default)
  --kargo                Install Kargo (requires --kargo-password non-interactively)
  --no-kargo             Skip Kargo (default)
  --kargo-password <pw>  Kargo admin password
                         WARNING: passing secrets inline exposes them via
                         'ps', shell history, and CI logs. Prefer interactive
                         entry, an env var, or a secret manager.
EOF
                exit 0
                ;;
            -*)
                print_error "Unknown flag: $1"
                exit 1
                ;;
            *)
                print_error "Unexpected argument: $1"
                exit 1
                ;;
        esac
    done

    # Verify Docker daemon is running (docker CLI exists but daemon may be stopped)
    if ! docker info &>/dev/null; then
        print_error "Docker daemon is not running."
        print_info "Start Docker (or OrbStack) and try again."
        exit 1
    fi

    print_header "Initialize k3d Cluster"

    # Cluster name: flag wins, else prompt, else default
    local default_name
    default_name="$(basename "${TARGET_DIR}")"
    local cluster_name
    if [[ -n "$name_flag" ]]; then
        cluster_name="$name_flag"
    elif [[ -t 0 ]]; then
        cluster_name="$(gum input --value "$default_name" --prompt "Cluster name: ")"
    else
        cluster_name="$default_name"
    fi

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

    # Agent nodes: flag wins, else prompt, else 3
    local agents
    if [[ -n "$agents_flag" ]]; then
        agents="$agents_flag"
    elif [[ -t 0 ]]; then
        while true; do
            agents="$(gum input --value "3" --prompt "Agent nodes: ")"
            validate_positive_integer "$agents" "Agent nodes" && break
        done
    else
        agents="3"
    fi
    validate_positive_integer "$agents" "Agent nodes" || exit 1

    # Port exposure: flag wins, else prompt, else no
    local port_args=()
    local expose="no"
    if [[ "$expose_flag" == "true" ]]; then
        expose="yes"
    elif [[ "$expose_flag" == "false" ]]; then
        expose="no"
    elif [[ -t 0 ]]; then
        gum confirm "Expose ports 80/443 on localhost? (for ingress)" && expose="yes"
    fi
    if [[ "$expose" == "yes" ]]; then
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

    # Local HTTPS: flag wins, else prompt, else no
    local enable_tls="no"
    if [[ "$tls_flag" == "true" ]]; then
        enable_tls="yes"
    elif [[ "$tls_flag" == "false" ]]; then
        enable_tls="no"
    elif command -v mkcert &>/dev/null && [[ -t 0 ]]; then
        gum confirm "Enable HTTPS with trusted local certs? (via mkcert)" && enable_tls="yes"
    fi
    if [[ "$enable_tls" == "yes" ]]; then
        if ! command -v mkcert &>/dev/null; then
            print_error "--tls requires mkcert to be installed"
            exit 1
        fi
        apply_local_tls
        tls_enabled=true
        print_success "HTTPS enabled with trusted local certs."
    fi

    # ArgoCD install: flag wins, else prompt, else no
    local install_argocd="no"
    if [[ "$argocd_flag" == "true" ]]; then
        install_argocd="yes"
    elif [[ "$argocd_flag" == "false" ]]; then
        install_argocd="no"
    elif [[ -t 0 ]]; then
        gum confirm "Install ArgoCD?" && install_argocd="yes"
    fi
    if [[ "$install_argocd" == "yes" ]]; then
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

    # Kargo install: flag wins, else prompt, else no
    local install_kargo="no"
    if [[ "$kargo_flag" == "true" ]]; then
        install_kargo="yes"
    elif [[ "$kargo_flag" == "false" ]]; then
        install_kargo="no"
    elif [[ -t 0 ]]; then
        gum confirm "Install Kargo?" && install_kargo="yes"
    fi
    if [[ "$install_kargo" == "yes" ]]; then
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

        local kargo_password
        if [[ -n "$kargo_password_flag" ]]; then
            warn_inline_secret_flag "--kargo-password" "$kargo_password_flag"
            kargo_password="$kargo_password_flag"
            if [[ -z "$kargo_password" ]]; then
                print_error "--kargo-password cannot be empty"
                exit 1
            fi
        elif [[ -t 0 ]]; then
            local kargo_password_confirm
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
        else
            print_error "--kargo-password is required when installing Kargo non-interactively"
            exit 1
        fi

        local kargo_hash
        kargo_hash="$(htpasswd -bnBC 10 "" "$kargo_password" | tr -d ':\n')"
        local kargo_signing_key
        kargo_signing_key="$(openssl rand -base64 48 | tr -d '=+/' | head -c 32)"

        # TLS termination happens at the Traefik level, not in Kargo;
        # api.tls.enabled=false disables TLS on the Kargo API server itself,
        # api.tls.terminatedUpstream=true signals that an upstream proxy already terminated TLS.
        # Use argv-form run_cmd so the bcrypt hash ($2y$10$...) and the random signing key
        # are not re-expanded by bash -c (which would strip every $N as an empty positional param).
        if run_cmd "Installing Kargo via Helm (this may take a minute)..." \
            --explain "Kargo is a progressive delivery tool that promotes container images through a pipeline of stages (e.g., dev -> staging -> prod). It tracks image versions in a Warehouse and applies promotions via Git commits. TLS is terminated at Traefik, so api.tls.enabled=false turns off TLS inside Kargo itself, and api.tls.terminatedUpstream=true tells Kargo an upstream proxy already handled TLS so it sets secure cookie flags correctly." \
            helm install kargo \
            oci://ghcr.io/akuity/kargo-charts/kargo \
            --namespace kargo --create-namespace \
            --set "api.adminAccount.passwordHash=${kargo_hash}" \
            --set "api.adminAccount.tokenSigningKey=${kargo_signing_key}" \
            --set api.tls.enabled=false \
            --set api.tls.terminatedUpstream=true \
            --wait --timeout 120s; then
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
            print_error "Kargo installation failed."
        fi
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

    local name_flag="" yes="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)
                require_flag_value "--name" "${2:-}"
                name_flag="$2"
                shift 2
                ;;
            --yes | -y)
                yes="true"
                shift
                ;;
            -h | --help)
                echo "Usage: cluster-ctl.sh delete-cluster [name] [--yes]"
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

    local cluster_name="$name_flag"

    if [[ -z "$cluster_name" ]]; then
        if [[ -t 0 ]]; then
            print_header "Delete k3d Cluster"
            cluster_name="$(k3d cluster list -o json 2>/dev/null | jq -r '.[].name' \
                | choose_from "Select cluster to delete:" "No k3d clusters found.")" || exit 0
        else
            print_error "--name is required when not running interactively"
            exit 1
        fi
    else
        print_header "Delete k3d Cluster: ${cluster_name}"
    fi

    require_yes "$yes" "delete cluster '${cluster_name}' (cannot be undone)"

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

    local pat_flag="" yes="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pat)
                require_flag_value "--pat" "${2:-}"
                pat_flag="$2"
                shift 2
                ;;
            --yes | -y)
                yes="true"
                shift
                ;;
            -h | --help)
                cat <<EOF
Usage: cluster-ctl.sh add-argo-creds [--pat <token>] [--yes]

WARNING: passing --pat inline exposes the token via 'ps', shell history, and
CI logs. Prefer running this command interactively so it can prompt with
hidden input.
EOF
                exit 0
                ;;
            -*)
                print_error "Unknown flag: $1"
                exit 1
                ;;
            *)
                print_error "Unexpected: $1"
                exit 1
                ;;
        esac
    done

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
        require_yes "$yes" "overwrite existing ArgoCD repo credentials"
    fi

    # PAT: flag wins, else prompt, else die
    local pat
    if [[ -n "$pat_flag" ]]; then
        warn_inline_secret_flag "--pat" "$pat_flag"
        pat="$pat_flag"
        if ! validate_github_pat "$pat" "repo"; then
            print_error "--pat did not validate with required scope 'repo'"
            exit 1
        fi
    elif [[ -t 0 ]]; then
        print_info "A classic GitHub PAT is required. Create one at:"
        print_info "  https://github.com/settings/tokens/new"
        print_info ""
        print_info "Required scope: repo"
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
    else
        print_error "--pat is required when not running interactively"
        exit 1
    fi

    # Create or replace the secret.
    # Build YAML via kubectl subshells (no bash -c re-parse), then pipe to apply.
    # This prevents $-containing values in REPO_URL or pat from being re-expanded.
    print_info "Configuring ArgoCD repo credentials..."
    if [[ "$EXPLAIN" == "1" ]]; then
        gum style --faint --italic "    ArgoCD discovers repository credentials by watching for Secrets labeled with 'argocd.argoproj.io/secret-type=repository'. The label is the signal; piping through 'kubectl label --local' adds the label before applying."
    fi
    kubectl create secret generic repo-creds \
        --namespace argocd \
        --from-literal=type=git \
        --from-literal=url="${REPO_URL}" \
        --from-literal=username=git \
        --from-literal=password="${pat}" \
        --dry-run=client -o yaml \
        | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
        | kubectl apply -f -

    print_success "ArgoCD repository credentials configured for ${REPO_URL}"
}

cmd_add_registry_creds() {
    require_gum
    require_cmd "kubectl" "brew install kubectl"
    load_conf

    local registry_flag="" username_flag="" token_flag="" yes="false"
    local env_flags=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --registry)
                require_flag_value "--registry" "${2:-}"
                registry_flag="$2"
                shift 2
                ;;
            --username)
                require_flag_value "--username" "${2:-}"
                username_flag="$2"
                shift 2
                ;;
            --token)
                require_flag_value "--token" "${2:-}"
                token_flag="$2"
                shift 2
                ;;
            --env)
                require_flag_value "--env" "${2:-}"
                env_flags+=("$2")
                shift 2
                ;;
            --yes | -y)
                yes="true"
                shift
                ;;
            -h | --help)
                cat <<EOF
Usage: cluster-ctl.sh add-registry-creds [--registry <host>] [--username <user>] [--token <pat>] [--env <ns>]... [--yes]

WARNING: passing --token inline exposes the token via 'ps', shell history, and
CI logs. Prefer running this command interactively so it can prompt with
hidden input.
EOF
                exit 0
                ;;
            -*)
                print_error "Unknown flag: $1"
                exit 1
                ;;
            *)
                print_error "Unexpected: $1"
                exit 1
                ;;
        esac
    done

    print_header "Configure Container Registry Credentials"

    # Registry: flag wins, else prompt, else ghcr.io
    local registry
    if [[ -n "$registry_flag" ]]; then
        registry="$registry_flag"
    elif [[ -t 0 ]]; then
        registry="$(gum input --value "ghcr.io" --prompt "Registry server: ")"
    else
        registry="ghcr.io"
    fi
    if [[ -z "$registry" ]]; then
        print_error "Registry server is required."
        exit 1
    fi

    # Username: flag wins, else prompt, else die
    local default_username="${REPO_OWNER:-}"
    local username
    if [[ -n "$username_flag" ]]; then
        username="$username_flag"
    elif [[ -t 0 ]]; then
        username="$(gum input --value "$default_username" --prompt "Registry username: ")"
    elif [[ -n "$default_username" ]]; then
        username="$default_username"
    else
        print_error "--username is required when not running interactively"
        exit 1
    fi
    if [[ -z "$username" ]]; then
        print_error "Username is required."
        exit 1
    fi

    # Token: flag wins, else prompt, else die
    local pat
    if [[ -n "$token_flag" ]]; then
        warn_inline_secret_flag "--token" "$token_flag"
        pat="$token_flag"
        if [[ "$registry" == "ghcr.io" ]] && ! validate_github_pat "$pat" "read:packages"; then
            print_error "--token did not validate with required scope 'read:packages'"
            exit 1
        fi
    elif [[ -t 0 ]]; then
        local pat_hint="A token with read access to the container registry."
        if [[ "$registry" == "ghcr.io" ]]; then
            pat_hint="A classic GitHub PAT is required."
            print_info "Create one at: https://github.com/settings/tokens/new"
            print_info "Required scope: read:packages"
        fi
        print_info "$pat_hint"
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
    else
        print_error "--token is required when not running interactively"
        exit 1
    fi

    # Detect environments from GitOps repo
    local envs=()
    readarray -t envs < <(detect_envs)

    if [[ ${#envs[@]} -eq 0 ]]; then
        print_error "No environments found in k8s/namespaces/."
        print_info "Run 'infra-ctl.sh add-env <name>' to create environments first."
        exit 1
    fi

    # Multi-select namespaces: flags win, else prompt, else all
    local selected=()
    if [[ ${#env_flags[@]} -gt 0 ]]; then
        local ef e found
        for ef in "${env_flags[@]}"; do
            found=0
            for e in "${envs[@]}"; do
                [[ "$ef" == "$e" ]] && {
                    found=1
                    break
                }
            done
            [[ "$found" -eq 0 ]] && {
                print_error "Env '${ef}' not found in k8s/namespaces/"
                exit 1
            }
        done
        selected=("${env_flags[@]}")
    elif [[ ${#envs[@]} -eq 1 ]]; then
        selected=("${envs[0]}")
        print_info "Namespace: ${selected[0]}"
    elif [[ -t 0 ]]; then
        readarray -t selected < <(printf '%s\n' "${envs[@]}" \
            | gum choose --no-limit --selected="$(printf '%s,' "${envs[@]}" | sed 's/,$//')" \
                --header "Select namespaces:")
    else
        selected=("${envs[@]}")
    fi

    if [[ ${#selected[@]} -eq 0 ]]; then
        print_warning "No namespaces selected."
        return
    fi

    print_info "Registry:   ${registry}"
    print_info "Username:   ${username}"
    print_info "Namespaces: ${selected[*]}"

    # Warn if registry-creds already exists in any selected namespace, and
    # require --yes to overwrite.
    local existing_ns=()
    local ns
    for ns in "${selected[@]}"; do
        if kubectl get secret registry-creds -n "$ns" &>/dev/null; then
            existing_ns+=("$ns")
        fi
    done
    if [[ ${#existing_ns[@]} -gt 0 ]]; then
        print_warning "registry-creds already exists in: ${existing_ns[*]}"
        require_yes "$yes" "overwrite existing registry credentials in ${#existing_ns[@]} namespace(s)"
    fi

    # All kubectl calls below use argv form + stdin piping so flag-sourced values
    # ($registry, $username, $pat) cannot be re-parsed as shell.
    for ns in "${selected[@]}"; do
        # Create namespace if it doesn't exist
        print_info "Ensuring namespace '${ns}' exists..."
        if [[ "$EXPLAIN" == "1" ]]; then
            gum style --faint --italic "    Namespaces must exist before Secrets can be created in them. Creating ahead of time is harmless; ArgoCD's CreateNamespace is a no-op if the namespace already exists."
        fi
        kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -

        # Create docker-registry secret (argv form - no shell re-parse)
        print_info "Creating registry credentials in '${ns}'..."
        if [[ "$EXPLAIN" == "1" ]]; then
            gum style --faint --italic "    Kubelet needs its own credentials for private registries; a kubernetes.io/dockerconfigjson Secret stores registry auth in the format kubelet expects."
        fi
        kubectl create secret docker-registry registry-creds \
            --namespace "$ns" \
            --docker-server="$registry" \
            --docker-username="$username" \
            --docker-password="$pat" \
            --dry-run=client -o yaml | kubectl apply -f -

        # Patch default ServiceAccount to use the secret (argv form)
        run_cmd "Patching default ServiceAccount in '${ns}'..." \
            --explain "Every pod that does not specify a serviceAccountName runs as the 'default' ServiceAccount. By adding imagePullSecrets to this ServiceAccount, all pods in the namespace automatically inherit the registry credentials." \
            kubectl patch serviceaccount default -n "$ns" \
            -p '{"imagePullSecrets": [{"name": "registry-creds"}]}'
    done

    print_success "Registry credentials configured for: ${selected[*]}"
}

cmd_add_kargo_creds() {
    require_gum
    require_gh
    require_cmd "kubectl" "brew install kubectl"
    load_conf

    local app_flag="" pat_flag="" private_flag="" yes="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app)
                require_flag_value "--app" "${2:-}"
                app_flag="$2"
                shift 2
                ;;
            --pat)
                require_flag_value "--pat" "${2:-}"
                pat_flag="$2"
                shift 2
                ;;
            --private-registry)
                private_flag="true"
                shift
                ;;
            --no-private-registry)
                private_flag="false"
                shift
                ;;
            --yes | -y)
                yes="true"
                shift
                ;;
            -h | --help)
                cat <<EOF
Usage: cluster-ctl.sh add-kargo-creds [app] [--pat <token>] [--private-registry] [--yes]

WARNING: passing --pat inline exposes the token via 'ps', shell history, and
CI logs. Prefer running this command interactively so it can prompt with
hidden input.
EOF
                exit 0
                ;;
            -*)
                print_error "Unknown flag: $1"
                exit 1
                ;;
            *)
                if [[ -z "$app_flag" ]]; then app_flag="$1"; else
                    print_error "Unexpected: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    local app_name="$app_flag"

    if [[ -z "$app_name" ]]; then
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
        elif [[ -t 0 ]]; then
            app_name="$(printf '%s\n' "${kargo_apps[@]}" | gum choose --header "Select app:")"
        else
            print_error "--app is required when not running interactively"
            exit 1
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

    # PAT: flag wins, else prompt, else die
    local pat
    if [[ -n "$pat_flag" ]]; then
        warn_inline_secret_flag "--pat" "$pat_flag"
        pat="$pat_flag"
        if ! validate_github_pat "$pat" "repo" "read:packages"; then
            print_error "--pat did not validate with required scopes 'repo' and 'read:packages'"
            exit 1
        fi
    elif [[ -t 0 ]]; then
        print_info "A classic GitHub PAT is required. Kargo needs write access to"
        print_info "commit image tag updates during promotions. Create one at:"
        print_info "  https://github.com/settings/tokens/new"
        print_info ""
        print_info "Required scopes: repo, read:packages (if the container registry is private)"
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
    else
        print_error "--pat is required when not running interactively"
        exit 1
    fi

    # Warn if gitops-repo-creds or registry-creds already exists, require --yes to overwrite.
    local existing_kargo=()
    if kubectl get secret gitops-repo-creds -n "$app_name" &>/dev/null; then
        existing_kargo+=("gitops-repo-creds")
    fi
    if kubectl get secret registry-creds -n "$app_name" &>/dev/null; then
        existing_kargo+=("registry-creds")
    fi
    if [[ ${#existing_kargo[@]} -gt 0 ]]; then
        print_warning "Secret(s) already exist in namespace '${app_name}': ${existing_kargo[*]}"
        require_yes "$yes" "overwrite existing Kargo credentials in namespace '${app_name}'"
    fi

    # Create Git credential (argv form + stdin pipes; no bash -c re-parse)
    print_info "Configuring Kargo Git credentials..."
    if [[ "$EXPLAIN" == "1" ]]; then
        gum style --faint --italic "    Kargo discovers Git credentials by watching for Secrets labeled 'kargo.akuity.io/cred-type=git' inside the app's namespace. Kargo needs write access to commit image-tag promotions."
    fi
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
    local is_private="no"
    if [[ "$private_flag" == "true" ]]; then
        is_private="yes"
    elif [[ "$private_flag" == "false" ]]; then
        is_private="no"
    elif [[ -t 0 ]]; then
        gum confirm "Is the container registry private?" && is_private="yes"
    fi
    if [[ "$is_private" == "yes" ]]; then
        print_info "Configuring registry credentials..."
        if [[ "$EXPLAIN" == "1" ]]; then
            gum style --faint --italic "    Kargo's Warehouse polls the registry to detect new tags; private registries need a Secret labeled 'kargo.akuity.io/cred-type=image'. repoURL scopes the credential to a specific registry/repository prefix."
        fi
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
