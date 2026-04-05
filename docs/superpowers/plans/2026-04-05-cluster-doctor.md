# `cluster-ctl.sh doctor` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a read-only `doctor` command to `cluster-ctl.sh` that runs nine layered diagnostic checks cross-referencing the GitOps repo against live cluster state, catching misconfigurations (missing secrets, orphan resources, unreachable images/ingresses) that the existing `status`/`argo-status`/`preflight-check` commands don't detect.

**Architecture:** New `cmd_doctor` in `cluster-ctl.sh` plus 9 layer functions executed in dependency order (prereqs → controllers → repo structure → repo alignment → credentials → runtime → images → ingress → hygiene). Shared emitters (`doctor_error`/`doctor_warn`/`doctor_info`/`doctor_clean`) accumulate findings per layer; a renderer emits gum-bordered boxes with icons/colors. Exit codes 0/1/2 for clean/warnings/errors.

**Tech Stack:** Bash, kubectl, jq, yq, gum, curl, crane (optional, install-prompted)

---

## Context

The GitOps practice repo currently has two postgres workloads (staging, prod) stuck in `Progressing` for 18h because their overlay kustomizations don't include a sealed-secret, so `postgres-secrets` is never created in those namespaces. Existing `status`/`argo-status`/`preflight-check` commands don't catch this class of bug — they show that pods are unhealthy but not *why* the manifests are wrong.

This plan implements `cluster-ctl.sh doctor`, a read-only diagnostic with nine layered checks that cross-reference the GitOps repo against live cluster state. Design spec: `docs/superpowers/specs/2026-04-05-cluster-doctor-design.md`.

**Key constraints:**
- Read-only. No `--fix`. Doctor prints the command; user runs it. This is a learning repo.
- Follows existing `cluster-ctl.sh` conventions: `cmd_*` functions, `run_cmd` wrappers with `--explain`, gum-styled output, zsh completions, AGENTS.md inventory.
- No automated test harness (matches current project culture). Each task has a manual verification scenario.
- Nine layers in order: prereqs → controllers → repo structure → repo alignment → credentials → runtime → images → ingress → hygiene.

---

## Files touched

| File | Action | Why |
|---|---|---|
| `cluster-ctl.sh` | Modify | Add `cmd_doctor()`, 9 layer functions, 4 emitters, rendering helper (~400 LOC). Wire into `main()` + `usage()` |
| `lib/common.sh` | Modify | Add `parse_yaml_field()` and `kustomization_resources()` helpers |
| `completions.zsh` | Modify | Add `doctor` command + flag completions (`--scope`, `--app`, `--env`, `--verbose`) with dynamic app/env lookup |
| `AGENTS.md` | Modify | Add `cmd_doctor` to the cluster-ctl.sh command inventory |

No new files. No new templates. Crane becomes a soft dep (prompted on first use of layer 7); curl is assumed present (macOS default).

**Reused existing helpers** (no modification):
- `lib/common.sh`: `detect_envs`, `detect_apps`, `detect_projects`, `detect_app_project`, `is_kargo_enabled`, `read_promotion_order`, `load_conf`, `print_*`, `require_cmd`, `require_gum`, `parse_global_args`, `preflight_check`
- `cluster-ctl.sh` pattern: `cmd_argo_status` (gum styling reference), `cmd_preflight_check` (dependency checking pattern)

---

## Task breakdown

Tasks are sequenced so earlier layers gate later ones. Each task implements one layer (or prerequisite), runs it in isolation against a known-broken state, and confirms the finding/fix hint appears correctly. The current gitops-practice cluster already has enough broken state (postgres-staging/prod missing secrets, backend-staging/prod degraded) that layers 4 and 6 can be verified directly without manually breaking anything.

### Task 1: Scaffold `cmd_doctor` + flag parsing + dispatcher wiring

**Files:**
- Modify: `cluster-ctl.sh` (add function after `cmd_argo_status`, wire into `main()` and `usage()`)

- [ ] **Step 1**: Add bash globals scoped to doctor at the top of `cmd_doctor()`:
```bash
DOCTOR_ERRORS=0
DOCTOR_WARNINGS=0
DOCTOR_INFOS=0
DOCTOR_SKIPPED_LAYERS=()
DOCTOR_VERBOSE=0
DOCTOR_SCOPE="all"
DOCTOR_APP=""
DOCTOR_ENV=""
DOCTOR_CLUSTER_REACHABLE=0
```

- [ ] **Step 2**: Implement flag parser in `cmd_doctor()`: loop over `"$@"`, handle `--scope=<val>`, `--app <name>`, `--env <name>`, `--verbose`, `-h|--help`. Validate `--scope` is one of `repo|cluster|all`; validate `--app`/`--env` against `detect_apps`/`detect_envs`.

- [ ] **Step 3**: Add 9 empty layer function stubs (`doctor_layer_1_prereqs`, ..., `doctor_layer_9_hygiene`) that each call `doctor_clean "Layer N: <name>"`. Call them in order from `cmd_doctor()`.

- [ ] **Step 4**: Wire `doctor` case into `main()` dispatcher and `usage()` text. Add the line between `argo-status` and `renew-tls` to match logical grouping (diagnostic commands).

- [ ] **Step 5**: Verify manually:
```
cluster-ctl.sh doctor --help              # shows usage
cluster-ctl.sh doctor                     # runs through 9 empty layers
cluster-ctl.sh doctor --scope=repo        # runs, skips nothing yet (stubs don't gate)
cluster-ctl.sh doctor --app postgres      # runs (no-op filter)
cluster-ctl.sh doctor --invalid           # errors out
cluster-ctl.sh doctor --scope=bogus       # errors out
```

- [ ] **Step 6**: Commit.
```
git add cluster-ctl.sh
git commit -m "Add doctor command scaffold with flag parsing"
```

---

### Task 2: Finding emitters + layer rendering

**Files:**
- Modify: `cluster-ctl.sh` (add 4 emitter functions + 1 render function alongside `cmd_doctor`)

- [ ] **Step 1**: Implement per-layer finding accumulators. Each layer declares local arrays `_layer_errors=()`, `_layer_warnings=()`, `_layer_infos=()` and emitters append structured strings (using a delimiter like `\x1f` between fields: subject, message, why, fix, evidence).

- [ ] **Step 2**: Implement `doctor_error`, `doctor_warn`, `doctor_info`, `doctor_clean` functions. Emitters increment `DOCTOR_ERRORS`/`DOCTOR_WARNINGS`/`DOCTOR_INFOS` counters and append to the current layer's arrays.

- [ ] **Step 3**: Implement `render_doctor_layer <layer_name>` that receives the layer's arrays and either prints a clean one-liner (`▸ Layer N: <name> ✓`) or a `gum style --border rounded --padding "0 1"` box containing findings with icons (`✗` red, `⚠` yellow, `ℹ` dim), bold subject, dim `why:`/`fix:` labels. Only include `evidence:` block if `DOCTOR_VERBOSE=1`.

- [ ] **Step 4**: Implement summary footer renderer: prints boxed summary with layer count, skipped count, severity counts, and exit code.

- [ ] **Step 4a**: Implement `doctor_matches_filter <app> <env>` returning 0 if the given app/env pass the current filters, 1 otherwise:
```bash
doctor_matches_filter() {
    local app="$1" env="$2"
    [[ -n "$DOCTOR_APP" && "$app" != "$DOCTOR_APP" ]] && return 1
    [[ -n "$DOCTOR_ENV" && "$env" != "$DOCTOR_ENV" ]] && return 1
    return 0
}
```
Every layer that iterates over (app, env) pairs calls this before emitting findings.

- [ ] **Step 5**: Temporarily wire one test call into layer 1 stub to verify rendering: `doctor_error "test-subject" "test message" "test why" "test fix" "evidence line 1"` plus a warn and a clean layer. Run `cluster-ctl.sh doctor` and `cluster-ctl.sh doctor --verbose`, verify colors/icons/box layout match spec §3.

- [ ] **Step 6**: Remove test calls, verify `cluster-ctl.sh doctor` shows all layers clean again.

- [ ] **Step 7**: Verify exit codes:
```
# With test call emitting doctor_error, exit should be 2
# With only doctor_warn, exit should be 1
# With only doctor_clean, exit should be 0
```

- [ ] **Step 8**: Commit.
```
git add cluster-ctl.sh
git commit -m "Add doctor finding emitters and layer rendering"
```

---

### Task 3: Layer 1 — Prerequisites

**Files:**
- Modify: `cluster-ctl.sh` (implement `doctor_layer_1_prereqs`)

- [ ] **Step 1**: Check each required tool on PATH: `kubectl`, `jq`, `helm`, `k3d`, `docker`, `curl`. Each missing tool → `doctor_error` with `fix:` "`brew install <tool>`".

- [ ] **Step 2**: Check docker daemon running via `docker info &>/dev/null`. If fails → `doctor_error` with `fix:` "Start Docker Desktop or OrbStack".

- [ ] **Step 3**: Check cluster reachable via `kubectl cluster-info &>/dev/null`. If yes, set `DOCTOR_CLUSTER_REACHABLE=1`. If no and `DOCTOR_SCOPE != "repo"` → `doctor_warn` with `fix:` "Run `cluster-ctl.sh init-cluster` or check kubeconfig context".

- [ ] **Step 4**: If `DOCTOR_SCOPE == "repo"`, don't require cluster to be reachable (info-only).

- [ ] **Step 5**: Verify manually:
```
cluster-ctl.sh doctor                          # with docker running + cluster up: Layer 1 ✓
# Stop docker or OrbStack, then:
cluster-ctl.sh doctor                          # Layer 1: ✗ docker daemon not running; exit 2
# Restart docker, then:
kubectl config use-context doesnotexist
cluster-ctl.sh doctor                          # Layer 1: ⚠ cluster not reachable; exit 1
cluster-ctl.sh doctor --scope=repo             # Layer 1: ✓ (cluster check skipped); exit 0
kubectl config use-context k3d-gitops-practice
```

- [ ] **Step 6**: Commit.
```
git add cluster-ctl.sh
git commit -m "Add doctor layer 1: prerequisites check"
```

---

### Task 4: Layer gating helper + Layer 2 — Controllers

**Files:**
- Modify: `cluster-ctl.sh` (add `needs_cluster_or_skip` helper + implement `doctor_layer_2_controllers`)

- [ ] **Step 1**: Implement `needs_cluster_or_skip <layer_display_name>` that returns 1 (and appends to `DOCTOR_SKIPPED_LAYERS` with reason) if `DOCTOR_SCOPE == "repo"` OR `DOCTOR_CLUSTER_REACHABLE == 0`.

- [ ] **Step 2**: In `doctor_layer_2_controllers`, call `needs_cluster_or_skip "Layer 2: Controllers"` and `return 0` if it returns 1.

- [ ] **Step 3**: Check `argocd` namespace exists. If not → `doctor_error` with `fix:` "Run `cluster-ctl.sh init-cluster`" and return (no point checking deployments).

- [ ] **Step 4**: For each of: `argocd-server`, `argocd-repo-server`, `argocd-applicationset-controller` in `argocd` namespace, check `.status.availableReplicas > 0` via `kubectl get deploy -o jsonpath`. Each not-ready → `doctor_error` with the deployment name as subject.

- [ ] **Step 5**: Check sealed-secrets controller: if any file under `k8s/apps/*/overlays/*/sealed-secret.yaml` exists in repo, then `sealed-secrets-controller` deployment in `kube-system` must exist and be ready. Missing → `doctor_error` with `fix:` "Run `secret-ctl.sh init`".

- [ ] **Step 6**: If `is_kargo_enabled` returns 0, check cert-manager webhook deployment + kargo-api/kargo-controller deployments in `kargo` namespace. Each not-ready → `doctor_error`.

- [ ] **Step 7**: Verify manually:
```
cluster-ctl.sh doctor                          # current cluster: all controllers up, Layer 2 ✓
cluster-ctl.sh doctor --scope=repo             # Layer 2: ○ skipped (scope=repo)

# Temporarily scale argocd-server to 0:
kubectl -n argocd scale deploy argocd-server --replicas=0
cluster-ctl.sh doctor                          # Layer 2: ✗ argocd-server not ready; exit 2
kubectl -n argocd scale deploy argocd-server --replicas=1
```

- [ ] **Step 8**: Commit.
```
git add cluster-ctl.sh
git commit -m "Add doctor layer 2: controller health check"
```

---

### Task 5: Layer 3 — Repo structure

**Files:**
- Modify: `cluster-ctl.sh` (implement `doctor_layer_3_repo_structure`)

- [ ] **Step 1**: Layer 3 is repo-only (no `needs_cluster_or_skip` gate, but respect `DOCTOR_SCOPE != "cluster"`). Add inverse gate: skip if `DOCTOR_SCOPE == "cluster"`.

- [ ] **Step 2**: For each `argocd/apps/*.yaml` (excluding `projects.yaml`, `kargo.yaml`): parse `.spec.source.path` via yq. If path doesn't exist in `$TARGET_DIR` → `doctor_error` subject=`<app>-<env>` message="Application references missing overlay path `<path>`" fix="Create overlay dir or fix path in argocd/apps/`<file>`".

- [ ] **Step 3**: For each Application, parse `.spec.project`. If not `default`, verify `argocd/projects/<project>.yaml` exists. Missing → `doctor_error` with `fix:` "Run `infra-ctl.sh add-project <name>` or change Application to default project".

- [ ] **Step 4**: If `is_kargo_enabled`, read `kargo/promotion-order.txt` via `read_promotion_order`, check every env exists as `k8s/namespaces/<env>.yaml`. Missing → `doctor_warn` "Promotion order references env `<env>` with no namespace file" fix="Run `infra-ctl.sh add-env <env>` or remove from promotion-order.txt".

- [ ] **Step 5**: Verify `.infra-ctl.conf` `REPO_URL` matches `.spec.source.repoURL` in at least one Application (spot check on first Application). Mismatch → `doctor_warn` "Repo URL drift between .infra-ctl.conf and Application manifests" with `fix:` hint to fix manually.

- [ ] **Step 6**: Apply `DOCTOR_APP`/`DOCTOR_ENV` filters: only emit findings for matching `<app>-<env>` when filters set.

- [ ] **Step 7**: Verify manually:
```
cluster-ctl.sh doctor                                     # Layer 3 ✓ on clean repo

# Break a path:
# Edit argocd/apps/postgres-dev.yaml, change path to k8s/apps/postgres/overlays/bogus
cluster-ctl.sh doctor                                     # Layer 3: ✗ postgres-dev missing overlay; exit 2
# Revert the edit
cluster-ctl.sh doctor --app postgres --env dev            # Filter works: only postgres-dev checked
```

- [ ] **Step 8**: Commit.
```
git add cluster-ctl.sh
git commit -m "Add doctor layer 3: repo structure validation"
```

---

### Task 6: Layer 4 helpers in `lib/common.sh`

**Files:**
- Modify: `lib/common.sh` (add `parse_yaml_field`, `kustomization_resources`)
- Modify: `cluster-ctl.sh` (add doctor-specific scanning helpers)

- [ ] **Step 1**: Add `parse_yaml_field <file> <yq_expr>` to `lib/common.sh`. Wraps `yq eval "$2" "$1"`; returns empty string and prints warning to stderr on yq error.

- [ ] **Step 2**: Add `kustomization_resources <kustomization.yaml>` to `lib/common.sh`. Returns one resource per line using `yq '.resources[]'`. Empty output if `.resources` missing.

- [ ] **Step 3**: Add `scan_workload_secret_refs <app>` to `cluster-ctl.sh` (doctor helper, not common). Greps `k8s/apps/<app>/base/*.yaml` for `secretKeyRef` and `envFrom.*.secretRef` blocks, extracts the Secret names. Returns one secret name per line, deduped.

- [ ] **Step 4**: Add `scan_workload_configmap_refs <app>` to `cluster-ctl.sh`. Same pattern for `configMapKeyRef` and `envFrom.*.configMapRef`.

- [ ] **Step 5**: Add `overlay_has_secret_manifest <app> <env> <secret_name>`. Checks two things: (a) any file listed in `kustomization_resources` for the overlay, when parsed, has `kind: SealedSecret` or `kind: Secret` with `metadata.name: <secret_name>`; OR (b) `configMapGenerator`/`secretGenerator` entries produce that name. Returns 0 if found, 1 otherwise.

- [ ] **Step 6**: Verify helpers manually in a shell:
```bash
source lib/common.sh
# From gitops-practice dir:
scan_workload_secret_refs postgres
# Expected: postgres-secrets

scan_workload_secret_refs frontend
# Expected: (empty)

overlay_has_secret_manifest postgres dev postgres-secrets
# Expected: 0 (dev overlay has sealed-secret.yaml)

overlay_has_secret_manifest postgres staging postgres-secrets
# Expected: 1 (staging overlay missing it — the bug we're catching)
```

- [ ] **Step 7**: Commit.
```
git add lib/common.sh cluster-ctl.sh
git commit -m "Add yaml/kustomization helpers for doctor layer 4"
```

---

### Task 7: Layer 4 — Repo alignment (static analysis)

**Files:**
- Modify: `cluster-ctl.sh` (implement `doctor_layer_4_alignment`)

- [ ] **Step 1**: Repo-only layer. Skip if `DOCTOR_SCOPE == "cluster"`. Loop over `argocd/apps/*.yaml` (excluding infrastructure apps); extract app name and env from filename or manifest.

- [ ] **Step 2**: For each `(app, env)` pair (respecting `DOCTOR_APP`/`DOCTOR_ENV` filters): call `scan_workload_secret_refs <app>` to get required secrets. For each required secret, call `overlay_has_secret_manifest <app> <env> <secret>`. If missing → `doctor_error` subject=`<app>-<env>` message="Secret `<secret>` referenced but not in overlay" why="base manifest uses secretKeyRef/envFrom for `<secret>`, but overlays/`<env>`/kustomization.yaml does not include a sealed-secret or secretGenerator for it" fix="`secret-ctl.sh add <app> <env>`".

- [ ] **Step 3**: Same for configmaps via `scan_workload_configmap_refs`. ConfigMap not resolvable → `doctor_warn` (warn, not error — base `kustomization.yaml` often provides a generator with defaults).

- [ ] **Step 4**: Orphaned sealed-secret check: for each `sealed-secret.yaml` file under `k8s/apps/*/overlays/*/`, verify the file is listed in the overlay's `kustomization.yaml` `resources:`. If not → `doctor_error` subject=`<app>-<env>` message="sealed-secret.yaml exists but not wired into kustomization" fix="Add `- sealed-secret.yaml` to the overlay's kustomization.yaml resources: list".

- [ ] **Step 5**: Overlay directory existence: for each Application, confirm the overlay dir referenced by `.spec.source.path` exists. (Overlaps with Layer 3's path check but from the overlay side — deduplicate by skipping here if Layer 3 already flagged it.)

- [ ] **Step 6**: Verify manually against current broken state:
```
cluster-ctl.sh doctor
# Expected findings in Layer 4:
#   ✗ postgres-staging: Secret 'postgres-secrets' referenced but not in overlay
#   ✗ postgres-prod: Secret 'postgres-secrets' referenced but not in overlay
#   ✗ backend-staging: Secret 'backend-secrets' (or similar) referenced but not in overlay
#   ✗ backend-prod: (same)
# Exit code: 2

cluster-ctl.sh doctor --verbose --app postgres --env staging
# Expected: only postgres-staging finding, with evidence block showing file paths
```

- [ ] **Step 7**: Verify evidence block shows:
```
evidence:
  - k8s/apps/postgres/base/statefulset.yaml:22 (secretKeyRef.name: postgres-secrets)
  - k8s/apps/postgres/overlays/staging/kustomization.yaml (no sealed-secret in resources:)
```

- [ ] **Step 8**: Commit.
```
git add cluster-ctl.sh
git commit -m "Add doctor layer 4: repo alignment static analysis"
```

---

### Task 8: Layer 5 — Credentials

**Files:**
- Modify: `cluster-ctl.sh` (implement `doctor_layer_5_credentials`)

- [ ] **Step 1**: Cluster-required layer. Gate via `needs_cluster_or_skip`.

- [ ] **Step 2**: Private repo check: run `gh repo view <owner>/<repo> --json isPrivate -q .isPrivate` using `REPO_URL` from `.infra-ctl.conf`. If `true`, check for any Secret with label `argocd.argoproj.io/secret-type=repository` in the `argocd` namespace. Missing → `doctor_error` "Private repo without ArgoCD repo creds" fix="`cluster-ctl.sh add-argo-creds`".

- [ ] **Step 3**: Registry credentials check: for each namespace targeted by an Application, list all distinct image refs from pod specs (`kubectl get pods -n <ns> -o jsonpath`). For each image, parse registry host (part before first `/`, falling back to `docker.io`). If host != `docker.io` AND the namespace's default ServiceAccount has no `imagePullSecrets` → `doctor_warn` "Non-docker.io image may need pull creds" fix="`cluster-ctl.sh add-registry-creds`".

- [ ] **Step 4**: Kargo credentials check: if `is_kargo_enabled` AND repo is private, check each `kargo/<app>/` project namespace (`kargo-<app>` or similar — inspect existing Kargo install) for git-repo credentials Secret. Missing → `doctor_warn` "Kargo missing git creds for private repo" fix="`cluster-ctl.sh add-kargo-creds`".

- [ ] **Step 5**: Verify manually (current repo is public, so this is mostly a "clean" verification):
```
cluster-ctl.sh doctor                          # Layer 5 ✓ on public repo

# If repo is public but has private-looking images (ghcr.io), expect:
# Layer 5: ⚠ <ns> ghcr.io images may need pull creds
# (current cluster uses ghcr.io/remerle images — confirm whether creds are set)
```

- [ ] **Step 6**: Commit.
```
git add cluster-ctl.sh
git commit -m "Add doctor layer 5: credentials check"
```

---

### Task 9: Layer 6 — Runtime

**Files:**
- Modify: `cluster-ctl.sh` (implement `doctor_layer_6_runtime`)

- [ ] **Step 1**: Cluster-required layer. Gate via `needs_cluster_or_skip`.

- [ ] **Step 2**: ArgoCD app summary: fetch all Applications via `kubectl get applications -n argocd -o json`. For each non-Healthy app (respecting `DOCTOR_APP`/`DOCTOR_ENV` filters), emit `doctor_warn` (if Progressing) or `doctor_error` (if Degraded/Missing) with subject=app name, why=conditions message (truncated to 120 chars).

- [ ] **Step 3**: Pod failure scan: for each namespace targeted by an Application (or filtered by `DOCTOR_ENV`), list pods with status `CreateContainerConfigError`, `ImagePullBackOff`, `ErrImagePull`, or containers with `restartCount > 3` in `CrashLoopBackOff`. Each → `doctor_error` with pod's last event message as `why:`.

- [ ] **Step 4**: PVC scan: `kubectl get pvc -A` in targeted namespaces, any Pending → `doctor_error` with `fix:` "Check storage class via `kubectl get storageclass`".

- [ ] **Step 5**: Service endpoints: for each Service in targeted namespaces, if `kubectl get endpoints <svc>` has no addresses, emit `doctor_warn` "Service has zero endpoints" fix="Check that pods match service selector (often caused by commonLabels mismatch)".

- [ ] **Step 6**: Verify manually against current broken state:
```
cluster-ctl.sh doctor
# Expected in Layer 6:
#   ⚠ backend-staging: Progressing / Degraded
#   ⚠ backend-prod: Degraded
#   ⚠ postgres-staging: Progressing
#   ⚠ postgres-prod: Progressing
#   ✗ postgres-0 (staging): CreateContainerConfigError — secret "postgres-secrets" not found
#   ✗ postgres-0 (prod): CreateContainerConfigError — secret "postgres-secrets" not found
#   ✗ backend-* pods: CreateContainerConfigError / ImagePullBackOff

cluster-ctl.sh doctor --app postgres --env staging --verbose
# Only postgres-staging ArgoCD app + postgres-0 pod findings, with full event details
```

- [ ] **Step 7**: Commit.
```
git add cluster-ctl.sh
git commit -m "Add doctor layer 6: runtime pod/service checks"
```

---

### Task 10: Layer 7 — Image reachability (with crane install prompt)

**Files:**
- Modify: `cluster-ctl.sh` (implement `doctor_layer_7_images`)

- [ ] **Step 1**: Cluster-required layer. Gate via `needs_cluster_or_skip`. Also skip if `DOCTOR_SCOPE == "repo"`.

- [ ] **Step 2**: Check for `crane` on PATH. If missing, prompt via `gum confirm "crane enables image reachability checks. Install via 'brew install crane'?"`. Yes → run `brew install crane` (via `run_cmd`). No → emit `doctor_info` "Layer 7 skipped — install crane later to enable image reachability checks" and return.

- [ ] **Step 3**: Collect distinct image+tag pairs from all running/pending pods in targeted namespaces via `kubectl get pods -o jsonpath='{.items[*].spec.containers[*].image}'`.

- [ ] **Step 4**: For each distinct image, run `crane digest <image> 2>/dev/null`. Non-zero exit → `doctor_warn` subject=`<image>` message="Image tag not resolvable" why="crane could not fetch manifest" fix="Check image ref typo; if private, `cluster-ctl.sh add-registry-creds`".

- [ ] **Step 5**: Verify manually:
```
cluster-ctl.sh doctor                          # If crane missing: prompts; if installed: Layer 7 ✓

# Break an image on a scratch branch:
# Edit k8s/apps/frontend/base/deployment.yaml to use frontend:99-does-not-exist
# Let ArgoCD sync, then:
cluster-ctl.sh doctor
# Expected: Layer 7: ⚠ ghcr.io/remerle/frontend:99-does-not-exist not resolvable; exit 1
```

- [ ] **Step 6**: Commit.
```
git add cluster-ctl.sh
git commit -m "Add doctor layer 7: image reachability via crane"
```

---

### Task 11: Layer 8 — Ingress reachability

**Files:**
- Modify: `cluster-ctl.sh` (implement `doctor_layer_8_ingress`)

- [ ] **Step 1**: Cluster-required layer. Gate via `needs_cluster_or_skip`. Skip (clean) if no `k8s/apps/*/overlays/*/ingress.yaml` files exist in repo.

- [ ] **Step 2**: Structural check: for each Ingress in targeted namespaces, for each `rule.http.paths[].backend.service`: verify the referenced Service exists (`kubectl get svc`), verify the port exists on the Service, verify `kubectl get endpoints <svc>` has >0 addresses. Each failure → `doctor_error` with subject=`<ingress>/<host>`.

- [ ] **Step 3**: HTTP probe: for each distinct `host` across all Ingress rules, run `curl -skI -o /dev/null -w "%{http_code}" --max-time 5 "https://<host>/"`. Result in `200|301|302|401|403|404` → reachable (404 is a valid reachability signal — server is responding). Result in `000` (connection failed) or `5xx` → `doctor_error` "Ingress host unreachable" with http code and curl error in why.

- [ ] **Step 4**: TLS SAN check: for each host, run `curl -skv "https://<host>/" 2>&1 | grep -E "subject|subjectAltName"` to extract SANs from the presented cert. If host not in SANs → `doctor_warn` "Cert SANs do not cover `<host>`" fix="Run `cluster-ctl.sh renew-tls`".

- [ ] **Step 5**: Verify manually:
```
cluster-ctl.sh doctor
# Current cluster has frontend ingresses (dev/staging/prod.frontend.localhost)
# Expected: Layer 8 ✓ (assuming they reach through traefik)

# Scale frontend to 0 replicas:
kubectl -n dev scale deploy frontend --replicas=0
cluster-ctl.sh doctor
# Expected: Layer 8: ✗ frontend ingress backend has zero endpoints; exit 2
kubectl -n dev scale deploy frontend --replicas=1

# To test TLS SAN: add a new ingress without running renew-tls
# (cover in test plan but don't force here)
```

- [ ] **Step 6**: Commit.
```
git add cluster-ctl.sh
git commit -m "Add doctor layer 8: ingress reachability"
```

---

### Task 12: Layer 9 — Hygiene / drift

**Files:**
- Modify: `cluster-ctl.sh` (implement `doctor_layer_9_hygiene`)

- [ ] **Step 1**: Cluster-required layer. Gate via `needs_cluster_or_skip`.

- [ ] **Step 2**: Orphan Applications: list Applications in `argocd` namespace, compare against files in `argocd/apps/*.yaml`. Any in cluster with no matching file → `doctor_warn` "Orphan Application in cluster" fix="Remove with `kubectl -n argocd delete app <name>` or restore `argocd/apps/<name>.yaml`".

- [ ] **Step 3**: Orphan namespaces: list namespaces matching env names (from `detect_envs`), check if any Application targets them. Namespace with no targeting Application → `doctor_info` "Namespace `<ns>` not targeted by any Application" (info, not warn — might be intentional).

- [ ] **Step 4**: Sealed-secrets cert drift: if `.sealed-secrets-cert.pem` exists in `$TARGET_DIR` and sealed-secrets-controller is running, run `kubeseal --fetch-cert > /tmp/live-cert.pem` and compare sha256 hashes. Mismatch → `doctor_warn` "Sealed-secrets cert in repo differs from controller's active cert" fix="Run `kubeseal --fetch-cert > .sealed-secrets-cert.pem` then commit".

- [ ] **Step 5**: Verify manually:
```
cluster-ctl.sh doctor                          # Current state: Layer 9 should be mostly clean

# Create an orphan app:
kubectl -n argocd apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: orphan-test
  namespace: argocd
spec:
  project: default
  source: { repoURL: "https://github.com/foo/bar", path: "x" }
  destination: { server: "https://kubernetes.default.svc", namespace: "default" }
EOF
cluster-ctl.sh doctor
# Expected: Layer 9: ⚠ Orphan Application 'orphan-test' in cluster; exit 1
kubectl -n argocd delete app orphan-test
```

- [ ] **Step 6**: Commit.
```
git add cluster-ctl.sh
git commit -m "Add doctor layer 9: hygiene and drift checks"
```

---

### Task 13: Completions + AGENTS.md

**Files:**
- Modify: `completions.zsh`
- Modify: `AGENTS.md`

- [ ] **Step 1**: Add `doctor` to the cluster-ctl command list in `completions.zsh`, with flag completions for `--scope` (values: repo, cluster, all), `--app` (dynamic, using existing `_cluster_complete_apps` or equivalent), `--env` (dynamic), `--verbose`.

- [ ] **Step 2**: Add `doctor` to the cluster-ctl.sh section of `AGENTS.md`'s command inventory paragraph (the bullet list after "cluster-ctl.sh" describing what it does).

- [ ] **Step 3**: Verify completions:
```
# Reload zsh completions
source completions.zsh
cluster-ctl.sh doctor <TAB>                    # Shows --scope, --app, --env, --verbose
cluster-ctl.sh doctor --scope=<TAB>            # Shows: repo cluster all
cluster-ctl.sh doctor --app <TAB>              # Shows apps from repo
cluster-ctl.sh doctor --env <TAB>              # Shows envs from repo
```

- [ ] **Step 4**: Commit.
```
git add completions.zsh AGENTS.md
git commit -m "Add doctor completions and AGENTS.md entry"
```

---

## End-to-end verification

After all tasks complete, run the full manual test plan from the spec against the current `gitops-practice` repo + cluster (which has known broken state):

```bash
# Scope variations
cluster-ctl.sh doctor                            # Full scan
cluster-ctl.sh doctor --scope=repo               # Repo-only (no cluster needed)
cluster-ctl.sh doctor --scope=cluster            # Skip repo static analysis

# Filtering
cluster-ctl.sh doctor --app postgres             # Only postgres apps
cluster-ctl.sh doctor --env staging              # Only staging
cluster-ctl.sh doctor --app postgres --env staging --verbose  # Most narrow + evidence

# Explain mode (existing cluster-ctl flag)
EXPLAIN=1 cluster-ctl.sh doctor --scope=repo     # Shows why each check runs
```

**Expected findings on the current cluster (without fixing anything):**
- Layer 4: `postgres-staging`, `postgres-prod`, `backend-staging`, `backend-prod` all missing required Secrets (ERROR)
- Layer 6: Same workloads' pods in `CreateContainerConfigError`; one backend-prod pod in `ImagePullBackOff` (ERROR)
- Exit code: 2

**Expected exit codes:**
- `--scope=repo` on current repo: 2 (layer 4 errors still apply)
- After fixing all overlay kustomizations: 0 or 1 (warn-level drift only)

**Move the plan file** to `infra-tooling/docs/superpowers/plans/2026-04-05-cluster-doctor.md` and commit (per writing-plans skill convention). The spec at `infra-tooling/docs/superpowers/specs/2026-04-05-cluster-doctor-design.md` is the canonical reference.
