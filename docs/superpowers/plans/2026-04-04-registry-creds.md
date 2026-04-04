# Registry Credentials Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `add-registry-creds` command to cluster-ctl.sh for configuring kubelet to pull from private container registries, rename `add-repo-creds` to `add-argo-creds`, and add a next-steps hint in `init-cluster`.

**Architecture:** New `cmd_add_registry_creds` function detects environments from the GitOps repo, creates namespaces if needed, creates a `docker-registry` secret, and patches the default ServiceAccount in each namespace. The rename is a straightforward find-and-replace across code, completions, and docs.

**Tech Stack:** Bash, kubectl, gum

---

### Task 1: Rename `add-repo-creds` to `add-argo-creds` in cluster-ctl.sh

**Files:**
- Modify: `cluster-ctl.sh:393` (function name)
- Modify: `cluster-ctl.sh:689,719` (hint messages referencing add-repo-creds)
- Modify: `cluster-ctl.sh:912` (usage text)
- Modify: `cluster-ctl.sh:943` (dispatcher case)

- [ ] **Step 1: Rename function and all internal references**

In `cluster-ctl.sh`, make these changes:

Line 393: rename function
```bash
# Old:
cmd_add_repo_creds() {
# New:
cmd_add_argo_creds() {
```

Line 689: update hint in argo-init error path
```bash
# Old:
            print_info "Run: cluster-ctl.sh add-repo-creds"
# New:
            print_info "Run: cluster-ctl.sh add-argo-creds"
```

Line 719: update hint in argo-init sync error path
```bash
# Old:
            print_info "If this is a private repo, run: cluster-ctl.sh add-repo-creds"
# New:
            print_info "If this is a private repo, run: cluster-ctl.sh add-argo-creds"
```

Line 912: update usage text
```bash
# Old:
  add-repo-creds      Configure ArgoCD access to a private Git repository
# New:
  add-argo-creds      Configure ArgoCD access to a private Git repository
```

Line 943: update dispatcher
```bash
# Old:
        add-repo-creds) cmd_add_repo_creds "$@" ;;
# New:
        add-argo-creds) cmd_add_argo_creds "$@" ;;
```

- [ ] **Step 2: Update infra-ctl.sh hint**

In `infra-ctl.sh`, line 126:
```bash
# Old:
    print_info "  3. If your repo is private:      cluster-ctl.sh add-repo-creds"
# New:
    print_info "  3. If your repo is private:      cluster-ctl.sh add-argo-creds"
```

- [ ] **Step 3: Update completions.zsh**

In `completions.zsh`, line 115:
```bash
# Old:
        'add-repo-creds:Configure ArgoCD access to a private Git repo'
# New:
        'add-argo-creds:Configure ArgoCD access to a private Git repo'
```

- [ ] **Step 4: Run validation**

Run: `make format validate`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add cluster-ctl.sh infra-ctl.sh completions.zsh
git commit -m "Rename add-repo-creds to add-argo-creds

- Rename function, dispatcher, and usage in cluster-ctl.sh
- Update hint messages in argo-init error paths
- Update infra-ctl.sh next-steps hint
- Update completions.zsh entry"
```

---

### Task 2: Add `cmd_add_registry_creds` to cluster-ctl.sh

**Files:**
- Modify: `cluster-ctl.sh` (add function after `cmd_add_argo_creds`, around line 454)

- [ ] **Step 1: Add the function**

Insert `cmd_add_registry_creds` after `cmd_add_argo_creds` (after the closing `}` on line 453):

```bash
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
        pat_hint="A GitHub PAT with read:packages scope."
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
```

- [ ] **Step 2: Run validation**

Run: `make format validate`
Expected: PASS (shfmt may reformat; that's fine)

- [ ] **Step 3: Commit**

```bash
git add cluster-ctl.sh
git commit -m "Add cmd_add_registry_creds function

- Prompts for registry server, username, and token
- Validates read:packages scope for ghcr.io
- Detects environments from k8s/namespaces/*.yaml
- Creates namespace if it doesn't exist
- Creates docker-registry secret named registry-creds
- Patches default ServiceAccount with imagePullSecrets
- Idempotent via --dry-run=client | kubectl apply"
```

---

### Task 3: Register `add-registry-creds` in dispatcher, usage, and completions

**Files:**
- Modify: `cluster-ctl.sh` (usage function ~line 912, dispatcher ~line 943)
- Modify: `completions.zsh` (line ~115)

- [ ] **Step 1: Add to usage**

In the `usage()` function in `cluster-ctl.sh`, add after the `add-argo-creds` line:

```bash
  add-argo-creds      Configure ArgoCD access to a private Git repository
  add-registry-creds  Configure container registry credentials for image pulls
```

- [ ] **Step 2: Add to dispatcher**

In the `case` statement in `main()`, add after the `add-argo-creds` case:

```bash
        add-argo-creds) cmd_add_argo_creds "$@" ;;
        add-registry-creds) cmd_add_registry_creds "$@" ;;
```

- [ ] **Step 3: Add to completions.zsh**

In the `_cluster_ctl` function commands array, add after the `add-argo-creds` entry:

```bash
        'add-argo-creds:Configure ArgoCD access to a private Git repo'
        'add-registry-creds:Configure container registry credentials for image pulls'
```

- [ ] **Step 4: Run validation**

Run: `make format validate`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add cluster-ctl.sh completions.zsh
git commit -m "Register add-registry-creds in dispatcher, usage, and completions

- Add to usage() help text
- Add case in main() dispatcher
- Add entry in completions.zsh"
```

---

### Task 4: Add next-steps hint in `init-cluster`

**Files:**
- Modify: `cluster-ctl.sh:305-308` (Next Steps section at end of init-cluster)

- [ ] **Step 1: Update next steps**

In `cmd_init_cluster`, update the Next Steps section (around line 306-308):

```bash
# Old:
    # Next steps
    print_header "Next Steps"
    print_info "1. Initialize your GitOps repo:  infra-ctl.sh init"

# New:
    # Next steps
    print_header "Next Steps"
    print_info "1. Initialize your GitOps repo:       infra-ctl.sh init"
    print_info "2. If using a private registry:       cluster-ctl.sh add-registry-creds"
```

- [ ] **Step 2: Run validation**

Run: `make format validate`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add cluster-ctl.sh
git commit -m "Add registry-creds hint to init-cluster next steps

- Remind users about add-registry-creds after cluster creation"
```

---

### Task 5: Update AGENTS.md

**Files:**
- Modify: `AGENTS.md:223` (workflow sequence)

- [ ] **Step 1: Update workflow sequence**

In `AGENTS.md`, update the workflow sequence (lines 215-230):

```markdown
## Workflow sequence

1. `cluster-ctl.sh init-cluster` -- create a local cluster and install ArgoCD (optional) and Kargo (optional) via Helm
2. `infra-ctl.sh init` -- bootstrap the repo skeleton (creates .gitignore, directory structure, parent-app, config)
3. `infra-ctl.sh add-project <name>` -- (optional) create access control boundaries
4. `infra-ctl.sh add-env <name>` / `infra-ctl.sh add-app <name>` -- in any order
   (If Kargo enabled, Kargo Warehouse and Stage resources are generated alongside ArgoCD Applications)
4b. `config-ctl.sh add` -- manage configMapGenerator literals
5. `secret-ctl.sh init` -- install Sealed Secrets controller (requires running cluster)
6. `secret-ctl.sh add <app> <env>` -- encrypt and store per-environment secrets
7. `cluster-ctl.sh add-argo-creds` -- (if private repo) give ArgoCD read access
8. `cluster-ctl.sh add-registry-creds` -- (if private registry) configure kubelet pull credentials for each namespace
9. Commit and push the GitOps repo
10. `cluster-ctl.sh argo-init` -- bootstrap ArgoCD by applying the parent-app (one-time)
11. `cluster-ctl.sh argo-sync` -- force immediate sync of all applications
12. `cluster-ctl.sh add-kargo-creds` -- (if private repo/registry) configure Kargo credentials (requires namespaces to exist)
13. `user-ctl.sh add-role <name>` -- create an RBAC role with a permission preset
14. `user-ctl.sh add <username> <group>` -- create a human user with x509 cert
15. `user-ctl.sh add-sa <name> <group>` -- create a service account with token
```

- [ ] **Step 2: Add to cluster-ctl.sh description**

In the architecture section of `AGENTS.md` (around line 9), update the cluster-ctl.sh description:

Find:
```markdown
- **`cluster-ctl.sh`** -- manages the local k3d cluster lifecycle (creation, ArgoCD Helm installation/upgrade, Kargo, teardown) and ArgoCD operations (init, sync, status). Interacts with Docker, Kubernetes, and Helm.
```

Replace with:
```markdown
- **`cluster-ctl.sh`** -- manages the local k3d cluster lifecycle (creation, ArgoCD Helm installation/upgrade, Kargo, teardown), ArgoCD operations (init, sync, status), and credential management (ArgoCD repo access, container registry auth, Kargo credentials). Interacts with Docker, Kubernetes, and Helm.
```

- [ ] **Step 3: Run validation**

Run: `make format validate`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add AGENTS.md
git commit -m "Update AGENTS.md for add-argo-creds rename and add-registry-creds

- Rename add-repo-creds to add-argo-creds in workflow sequence
- Add add-registry-creds step (step 8)
- Update cluster-ctl.sh description to mention credential management"
```

---

### Task 6: Update README.md

**Files:**
- Modify: `README.md:278` (argo-init description)
- Modify: `README.md:502-509` (step 6 example walkthrough)
- Add new section after step 6

- [ ] **Step 1: Update argo-init description**

Line 278, change:
```markdown
Bootstraps ArgoCD by applying the parent-app to the cluster. This is a one-time step that tells ArgoCD to watch the Git repository for Application manifests. Checks for repo access errors and suggests `add-repo-creds` if the repo is private.
```
to:
```markdown
Bootstraps ArgoCD by applying the parent-app to the cluster. This is a one-time step that tells ArgoCD to watch the Git repository for Application manifests. Checks for repo access errors and suggests `add-argo-creds` if the repo is private.
```

- [ ] **Step 2: Add `add-argo-creds` and `add-registry-creds` command docs**

After the `status` command doc block (around line 306), add:

```markdown
#### `add-argo-creds`

Configures ArgoCD to access a private Git repository. Creates a labeled Kubernetes Secret in the `argocd` namespace that ArgoCD auto-discovers for repository authentication.

```bash
cluster-ctl.sh add-argo-creds
```

#### `add-registry-creds`

Configures kubelet to pull container images from a private registry. Creates a `docker-registry` Secret and patches the default ServiceAccount in each selected namespace. Detects environments from the GitOps repo and creates namespaces if they don't exist yet.

```bash
cluster-ctl.sh add-registry-creds
```
```

- [ ] **Step 3: Update example walkthrough step 6**

Replace the step 6 section (lines 502-509):

```markdown
### 6. Configure credentials (if private repo/registry)

For a private GitOps repo, ArgoCD needs read access:

```bash
cluster-ctl.sh add-argo-creds
# Enter a GitHub PAT with repo read access
```

For a private container registry (e.g., ghcr.io), kubelet needs pull credentials. This creates namespaces if they don't exist and configures each one:

```bash
cluster-ctl.sh add-registry-creds
# Enter the registry server (default: ghcr.io), username, and a token with read:packages
# Select which namespaces to configure
```
```

- [ ] **Step 4: Run validation**

Run: `make format validate`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "Update README for add-argo-creds rename and add-registry-creds

- Rename add-repo-creds references to add-argo-creds
- Add command docs for add-argo-creds and add-registry-creds
- Update example walkthrough step 6 with both credential commands"
```
