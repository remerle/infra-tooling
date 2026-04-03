# Explain Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `--explain` / `EXPLAIN=1` mode that enriches `SHOW_ME` output with human-readable explanations of *why* each command is being run, turning the tooling into a learning resource.

**Architecture:** Extend `run_cmd` and `run_cmd_sh` to accept an optional explanation string. Add `EXPLAIN` env var and `--explain` flag (which implies `SHOW_ME`). When active, print the explanation before the command. All changes are additive to the existing `SHOW_ME` infrastructure.

**Tech Stack:** Bash, existing `lib/common.sh` infrastructure

---

### Task 1: Extend `run_cmd` / `run_cmd_sh` to accept an explanation argument

**Files:**
- Modify: `lib/common.sh`

The current signatures are:
```bash
run_cmd "title" command arg1 arg2 ...
run_cmd_sh "title" "shell script"
```

The new signatures add an optional `--explain "text"` before the command:
```bash
run_cmd "title" --explain "why this matters" command arg1 arg2 ...
run_cmd_sh "title" --explain "why this matters" "shell script"
```

When `--explain` is not passed, behavior is unchanged (backward compatible).

- [ ] **Step 1: Add EXPLAIN variable and --explain flag parsing**

In `lib/common.sh`, after the `SHOW_ME` default, add:

```bash
# When EXPLAIN=1 (or --explain flag), also print explanations for each command.
# Implies SHOW_ME=1.
: "${EXPLAIN:=0}"
```

In `parse_global_args`, add a case for `--explain`:

```bash
            --explain)
                EXPLAIN=1
                SHOW_ME=1
                shift
                ;;
```

- [ ] **Step 2: Update run_cmd to parse --explain**

```bash
run_cmd() {
    local title="$1"
    shift

    local explanation=""
    if [[ "${1:-}" == "--explain" ]]; then
        explanation="$2"
        shift 2
    fi

    if [[ "$SHOW_ME" == "1" ]]; then
        print_info "${title}"
        if [[ "$EXPLAIN" == "1" && -n "$explanation" ]]; then
            gum style --faint --italic "    ${explanation}"
        fi
        print_info "  \$ $*"
        "$@"
    else
        gum spin --title "$title" -- "$@"
    fi
}
```

- [ ] **Step 3: Update run_cmd_sh to parse --explain**

```bash
run_cmd_sh() {
    local title="$1"
    shift

    local explanation=""
    if [[ "${1:-}" == "--explain" ]]; then
        explanation="$2"
        shift 2
    fi

    local script="$1"

    if [[ "$SHOW_ME" == "1" ]]; then
        print_info "${title}"
        if [[ "$EXPLAIN" == "1" && -n "$explanation" ]]; then
            gum style --faint --italic "    ${explanation}"
        fi
        print_info "  \$ ${script}"
        bash -c "$script"
    else
        gum spin --title "$title" -- bash -c "$script"
    fi
}
```

- [ ] **Step 4: Verify backward compatibility**

Run: `bash -n lib/common.sh`
Expected: No syntax errors

Existing callers (without `--explain`) must still work unchanged. The `--explain` parsing only triggers if the second arg is literally `--explain`.

- [ ] **Step 5: Commit**

```bash
git add lib/common.sh
git commit -m "Add EXPLAIN mode to run_cmd / run_cmd_sh

- Optional --explain arg prints why a command is being run
- EXPLAIN=1 env var or --explain flag activates (implies SHOW_ME=1)
- Backward compatible: callers without --explain are unchanged"
```

---

### Task 2: Add explanations to `cluster-ctl.sh`

**Files:**
- Modify: `cluster-ctl.sh`

Add `--explain "..."` to every `run_cmd` / `run_cmd_sh` call. The explanations should answer "why is this command necessary?" for someone learning Kubernetes/k3d/ArgoCD/Kargo.

- [ ] **Step 1: Add explanations to init-cluster commands**

For each `run_cmd` / `run_cmd_sh` call in `cmd_init_cluster`, add an `--explain` argument. Use the existing code comments and AGENTS.md context to write explanations. Examples:

```bash
run_cmd "Creating k3d cluster '${cluster_name}'..." \
    --explain "k3d creates a k3s Kubernetes cluster inside Docker containers. --agents sets worker nodes, --env fixes a k3d bug where agent nodes can't reach the API server, --wait blocks until the cluster is ready." \
    k3d cluster create "$cluster_name" \
    ...

run_cmd "Installing Metrics Server ${metrics_server_version}..." \
    --explain "Metrics Server collects CPU/memory usage from kubelets. Required for 'kubectl top' and HPA autoscaling. Not included in k3s by default." \
    kubectl apply -f "https://..."

run_cmd "Patching Metrics Server for k3d..." \
    --explain "k3d uses self-signed kubelet certificates. Metrics Server rejects these by default, so --kubelet-insecure-tls tells it to skip TLS verification when scraping metrics." \
    kubectl patch deployment metrics-server ...
```

Write explanations for all `run_cmd` / `run_cmd_sh` calls in `cmd_init_cluster`:
- k3d cluster create
- Metrics Server install
- Metrics Server patch
- Metrics Server wait
- TLS configuration (mkcert)
- ArgoCD Helm repo add
- Helm repo update
- ArgoCD Helm install
- cert-manager install
- Kargo Helm install
- Kargo Ingress creation
- Kargo KARGO_ENABLED flag

- [ ] **Step 2: Add explanations to other cluster-ctl commands**

Add explanations to `run_cmd` calls in:
- `cmd_delete_cluster`
- `cmd_add_repo_creds`
- `cmd_add_kargo_creds`
- `cmd_upgrade_argocd`
- `cmd_upgrade_kargo`

- [ ] **Step 3: Update usage text**

Add `--explain` to the Global options section:

```
  --explain             Print commands with explanations (learning mode, implies --show-me)
```

- [ ] **Step 4: Verify**

Run: `bash -n cluster-ctl.sh`
Expected: No syntax errors

- [ ] **Step 5: Commit**

```bash
git add cluster-ctl.sh
git commit -m "Add explain mode annotations to cluster-ctl.sh

- Every run_cmd/run_cmd_sh call includes --explain with context
- Explanations cover k3d, Metrics Server, TLS, ArgoCD, Kargo
- Designed as a learning resource for Kubernetes beginners"
```

---

### Task 3: Add explanations to `secret-ctl.sh`

**Files:**
- Modify: `secret-ctl.sh`

- [ ] **Step 1: Add explanations to all run_cmd calls**

Add `--explain` to every `run_cmd` / `run_cmd_sh` call in `secret-ctl.sh`:

- Restoring sealed-secrets key: explain why you'd restore vs generate fresh
- Installing Sealed Secrets controller: explain what it does (runs in-cluster, watches SealedSecret CRDs, decrypts with its private key)
- Waiting for controller: explain why we wait (webhook registration)
- Exporting public cert: explain asymmetric encryption model (public cert encrypts, only the controller's private key decrypts)

- [ ] **Step 2: Update usage text**

Add `--explain` to the Global options section.

- [ ] **Step 3: Verify and commit**

Run: `bash -n secret-ctl.sh`

```bash
git add secret-ctl.sh
git commit -m "Add explain mode annotations to secret-ctl.sh

- Explanations cover Sealed Secrets encryption model and key management"
```

---

### Task 4: Add explanations to `user-ctl.sh`

**Files:**
- Modify: `user-ctl.sh`

- [ ] **Step 1: Add explanations to all run_cmd calls**

Add `--explain` to every `run_cmd` / `run_cmd_sh` call in `user-ctl.sh`:

- RSA key generation: explain x509 client cert auth model
- CSR generation: explain CN= is the username, O= is the group for RBAC
- Submitting CSR: explain Kubernetes CSR API
- Approving CSR: explain the approval flow
- kubectl apply RBAC manifests: explain ClusterRole/Role binding
- kubectl delete for removals: explain what's being cleaned up
- ServiceAccount creation: explain SA vs cert-based auth
- ServiceAccount removal: explain RBAC binding cleanup

- [ ] **Step 2: Update usage text**

Add `--explain` to the Global options section.

- [ ] **Step 3: Verify and commit**

Run: `bash -n user-ctl.sh`

```bash
git add user-ctl.sh
git commit -m "Add explain mode annotations to user-ctl.sh

- Explanations cover x509 auth, CSR flow, RBAC, and ServiceAccounts"
```

---

### Task 5: Update completions and AGENTS.md

**Files:**
- Modify: `completions.zsh`
- Modify: `AGENTS.md`

- [ ] **Step 1: Add --explain to completions**

Add `'--explain[Print commands with explanations (learning mode)]'` to every `_arguments` block, next to `--show-me`.

- [ ] **Step 2: Update usage text in infra-ctl.sh**

Add `--explain` to `infra-ctl.sh` Global options (infra-ctl doesn't call run_cmd today, but the flag is parsed globally so it should be documented).

- [ ] **Step 3: Update AGENTS.md**

In the "When modifying these scripts" section, add:

```
- **Explain mode**: every `run_cmd` / `run_cmd_sh` call MUST include an `--explain` argument that describes why the command is necessary, not just what it does. Write for someone learning Kubernetes. These explanations are shown when the user runs with `--explain` or `EXPLAIN=1`.
```

- [ ] **Step 4: Verify and commit**

```bash
git add completions.zsh infra-ctl.sh AGENTS.md
git commit -m "Add --explain to completions and AGENTS.md conventions

- Mandate --explain annotations on all run_cmd calls
- Add --explain to shell completions for all scripts"
```
