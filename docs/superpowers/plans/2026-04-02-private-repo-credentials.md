# Private Repository Credentials Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `add-repo-creds` and `add-kargo-creds` commands to `cluster-ctl.sh` so users can configure ArgoCD and Kargo access to private Git repos and container registries.

**Architecture:** Two new `cmd_` functions in `cluster-ctl.sh`, registered in `main()` and `usage()`. Post-install hints added to `cmd_init_cluster`. README walkthrough rewritten to assume Kargo is enabled with private repos.

**Tech Stack:** Bash, kubectl, gum

---

### Task 1: Add `cmd_add_repo_creds` to `cluster-ctl.sh`

**Files:**
- Modify: `cluster-ctl.sh:266-320` (insert new function before `cmd_upgrade_argocd`)

- [ ] **Step 1: Add the `cmd_add_repo_creds` function**

Insert before `cmd_upgrade_argocd` (line 267):

```bash
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
```

- [ ] **Step 2: Test manually**

This is a bash script with interactive prompts and cluster dependencies, so manual testing is appropriate. Verify:
1. Without ArgoCD namespace: `cluster-ctl.sh add-repo-creds` prints error and exits
2. Without `.infra-ctl.conf`: prints error about running `init` first
3. With ArgoCD running: prompts for PAT, creates secret, verify with `kubectl get secret repo-creds -n argocd -o yaml`
4. Running again: detects existing secret, prompts to overwrite

- [ ] **Step 3: Commit**

```bash
git add cluster-ctl.sh
git commit -m "Add add-repo-creds command to cluster-ctl.sh

- Creates ArgoCD repository Secret for private Git repo access
- Reads REPO_URL from .infra-ctl.conf
- Idempotent: detects existing creds and prompts to overwrite"
```

---

### Task 2: Add `cmd_add_kargo_creds` to `cluster-ctl.sh`

**Files:**
- Modify: `cluster-ctl.sh` (insert new function after `cmd_add_repo_creds`)

- [ ] **Step 1: Add the `cmd_add_kargo_creds` function**

Insert immediately after `cmd_add_repo_creds`:

```bash
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
```

- [ ] **Step 2: Test manually**

Verify:
1. Without app argument: prints usage error
2. Without `kargo/<app>/` directory: prints error about missing Kargo resources
3. Without namespace in cluster: prints error with hint about applying the Project
4. With everything in place: prompts for PAT, creates git secret, asks about registry
5. Running again: `kubectl apply` updates the existing secret (idempotent via `--dry-run=client | apply`)
6. With private registry: creates both secrets

- [ ] **Step 3: Commit**

```bash
git add cluster-ctl.sh
git commit -m "Add add-kargo-creds command to cluster-ctl.sh

- Creates Git write credential in Kargo Project namespace
- Optionally creates registry read credential for private registries
- Reads REPO_URL from .infra-ctl.conf and IMAGE_REPO from warehouse.yaml
- Idempotent via kubectl apply"
```

---

### Task 3: Register commands in `main()` and `usage()`

**Files:**
- Modify: `cluster-ctl.sh` (usage function and main case statement)

- [ ] **Step 1: Update the `usage()` function**

Replace the current usage `Commands:` block with:

```bash
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
```

- [ ] **Step 2: Add cases to the `main()` dispatcher**

Add these two lines to the `case` block, after the `delete-cluster` case:

```bash
        add-repo-creds)     cmd_add_repo_creds "$@" ;;
        add-kargo-creds)    cmd_add_kargo_creds "$@" ;;
```

The full case block becomes:

```bash
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
```

- [ ] **Step 3: Verify help output**

```bash
cluster-ctl.sh --help
```

Expected: the updated usage text with `add-repo-creds` and `add-kargo-creds` listed.

- [ ] **Step 4: Commit**

```bash
git add cluster-ctl.sh
git commit -m "Register add-repo-creds and add-kargo-creds in cluster-ctl.sh

- Add both commands to usage text and main dispatcher"
```

---

### Task 4: Add post-install hints to `cmd_init_cluster`

**Files:**
- Modify: `cluster-ctl.sh` (inside `cmd_init_cluster`, after ArgoCD and Kargo install blocks)

- [ ] **Step 1: Add hint after ArgoCD install**

After line 103 (`print_info "  kubectl -n argocd get secret ..."`), add:

```bash
        print_info "If your GitOps repo is private, run: cluster-ctl.sh add-repo-creds"
```

- [ ] **Step 2: Add hint after Kargo install**

After line 156 (`print_info "Kargo UI: http://kargo.localhost"`), add:

```bash
        print_info "If your repo or registry is private, run: cluster-ctl.sh add-kargo-creds <app> (after adding apps)"
```

- [ ] **Step 3: Commit**

```bash
git add cluster-ctl.sh
git commit -m "Add post-install credential hints to init-cluster

- Remind users about add-repo-creds after ArgoCD install
- Remind users about add-kargo-creds after Kargo install"
```

---

### Task 5: Update README walkthrough

**Files:**
- Modify: `README.md` (lines 241-488, the "Example: Deploying an Application" section)

- [ ] **Step 1: Update Step 1 to include Kargo**

Replace the current step 1 content (lines 247-257) with:

```markdown
### 1. Create the cluster and initialize the repo

```bash
# Create a local k3d cluster with ArgoCD and Kargo
cluster-ctl.sh init-cluster
# Answer: expose ports 80/443? yes, install ArgoCD? yes, install Kargo? yes

# Initialize the GitOps repo structure
infra-ctl.sh init
# Enter your repo URL when prompted
```
```

- [ ] **Step 2: Update Step 3 to mention Kargo resources**

Replace the current step 3 content (lines 268-284) with:

```markdown
### 3. Add the applications

```bash
# Backend API (Deployment, port 3000)
infra-ctl.sh add-app backend
# Choose: Deployment, port 3000
# Kargo: accept default image ghcr.io/remerle/k8s-practice-backend

# Frontend (Deployment, port 3000)
infra-ctl.sh add-app frontend
# Choose: Deployment, port 3000
# Kargo: accept default image ghcr.io/remerle/k8s-practice-frontend

# PostgreSQL (StatefulSet, port 5432)
infra-ctl.sh add-app postgres
# Choose: StatefulSet, port 5432
# Kargo: not applicable (postgres uses a public upstream image, not built by CI)
```

Each command generates a Kustomize base, per-env overlays, and ArgoCD Application manifests. For backend and frontend, Kargo resources are also generated: a Warehouse (watches the container registry for new tags) and Stages (one per environment in the promotion pipeline). Postgres doesn't get Kargo resources because it uses `postgres:16-alpine` directly rather than a CI-built image.
```

- [ ] **Step 3: Insert new Step 6 for repository credentials**

After the current step 5 (secrets, ending at line 459) and before the current step 6 (commit and push), insert:

```markdown
### 6. Configure repository credentials

For a private GitOps repo, ArgoCD needs read access and Kargo needs read+write access. Both commands prompt for a GitHub Personal Access Token.

```bash
# ArgoCD: repo read access (one-time, cluster-wide)
cluster-ctl.sh add-repo-creds
# Enter a GitHub PAT with repo read access

# Kargo: Git write + optional registry read (per app)
cluster-ctl.sh add-kargo-creds backend
# Enter a GitHub PAT with repo read+write access
# Answer: is the container registry private? (yes if ghcr.io repo is private)

cluster-ctl.sh add-kargo-creds frontend
# Same PAT works, same registry answer
```

Postgres doesn't need Kargo credentials because it has no Kargo resources (no Warehouse or Stages were generated for it).

For a public repo, skip this step entirely. ArgoCD can read public repos without credentials, and Kargo only needs credentials for private repos and registries.
```

- [ ] **Step 4: Renumber steps 6 and 7 to 7 and 8**

The current "6. Commit and push" becomes "7. Commit and push". The current "7. Verify" becomes "8. Verify".

Update the verify section to include Kargo:

```markdown
### 8. Verify

```bash
# Check ArgoCD sync status
kubectl get applications -n argocd

# Check Kargo stages
kubectl get stages -n backend
kubectl get stages -n frontend

# Check running pods
kubectl get pods -n dev

# Open the frontend (no port-forward needed)
open http://app.localhost

# Open Kargo dashboard
open http://kargo.localhost
```
```

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "Update README walkthrough for Kargo and private repo credentials

- Step 1 includes Kargo install
- Step 3 explains Kargo resource generation (and why postgres is excluded)
- New step 6 covers add-repo-creds and add-kargo-creds
- Step 8 adds Kargo verification commands"
```
