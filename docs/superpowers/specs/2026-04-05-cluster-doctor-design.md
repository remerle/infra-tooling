# `cluster-ctl.sh doctor` — Design

## Purpose

Read-only diagnostic command for `cluster-ctl.sh` that runs cross-layer checks
the existing `status`, `argo-status`, and `preflight-check` commands don't
cover: repo↔cluster alignment, missing secrets/configmaps, image reachability,
credential presence, orphan resources.

Primary use cases (all three supported via flags):

1. **Triage** — "something's broken, tell me what."
2. **Periodic health check** — "is my cluster healthy right now."
3. **Pre-push static check** — "are repo-side manifests consistent" (no cluster
   required).

Existing `status`/`argo-status`/`preflight-check` stay as fast single-purpose
views. `doctor` earns its place by doing what they can't: cross-layer checks
(e.g., base manifest references a Secret → is it deployed to the namespace the
overlay targets → is a sealed-secret file wired into the overlay's
kustomization).

## Scope

**In scope:**

- Static analysis of the GitOps repo (`$TARGET_DIR`) — manifest parsing,
  kustomization inspection, cross-references between `argocd/`, `k8s/`,
  `kargo/`.
- Live cluster inspection — ArgoCD Applications, pods, PVCs, services, secrets,
  deployments.
- Credential presence checks (ArgoCD repo creds, imagePullSecrets, Kargo
  creds).
- Image reachability (optional, via `crane`).
- Orphan/drift detection between repo and cluster.

**Out of scope:**

- Any write/fix action. Doctor is strictly read-only. All findings print the
  exact command to run manually.
- Deep cluster diagnostics (node capacity, kubelet health, CNI issues) — those
  belong in `status`.
- Kargo promotion history analysis.
- Multi-cluster support (single-cluster only, matching the rest of the
  tooling).

## Usage

```
cluster-ctl.sh doctor [--scope=repo|cluster|all] [--app <name>] [--env <env>] [--verbose]
```

**Flags:**

| Flag | Default | Behavior |
|------|---------|----------|
| `--scope=repo\|cluster\|all` | `all` | `repo` skips layers needing a cluster (pre-push mode). `cluster` skips repo-only static analysis. `all` runs every layer. |
| `--app <name>` | (empty) | Narrow all layers' checks to this app. Chooser-free: errors if the app doesn't exist. |
| `--env <env>` | (empty) | Narrow all layers' checks to this env. |
| `--verbose` | off | Include an `evidence:` block on each finding (file paths, line refs, pod events, raw data). |

**Exit codes:**

- `0` — all checks passed.
- `1` — warnings only, no errors.
- `2` — one or more errors.

## Check layers

Nine layers, executed in order. If an early layer has a prerequisite failure
(e.g., cluster unreachable), later cluster-dependent layers are marked
"skipped" with a reason, not silently bypassed.

| # | Layer | Needs cluster? | What it checks |
|---|-------|----------------|----------------|
| 1 | Prerequisites | no | `kubectl`/`jq`/`helm`/`k3d`/`docker`/`curl` on PATH (`crane` prompted only in layer 7); docker daemon running; cluster reachable via `kubectl cluster-info` |
| 2 | Controllers | yes | `argocd`, `sealed-secrets`, `cert-manager` (if Kargo enabled), `kargo` deployments have `readyReplicas > 0` |
| 3 | Repo structure | no | ArgoCD Application `path` fields point to existing overlay dirs; referenced projects exist in `argocd/projects/`; `kargo/promotion-order.txt` envs all have `k8s/namespaces/*.yaml` files; `.infra-ctl.conf` `REPO_URL` matches Application `repoURL` fields |
| 4 | Repo alignment (static) | no | Base manifest `secretKeyRef`/`envFrom.secretRef` targets are satisfied by a resource in the matching overlay's `kustomization.yaml` `resources:` list; `sealed-secret.yaml` files present in overlay dirs are listed in that overlay's `kustomization.yaml` `resources:` field; overlay directories exist for each Application `path`. Pure repo analysis — runtime verification of whether the Secret actually exists in the namespace is layer 6's job |
| 5 | Credentials | yes | Private repo (per `gh repo view`) + no ArgoCD repo secret → ERROR; image on a non-`docker.io` registry + no `imagePullSecret` on the namespace's default ServiceAccount → WARN (heuristic: `docker.io` is the only registry assumed public by default; anything else may require auth); Kargo enabled + private repo + no Kargo git creds → WARN |
| 6 | Runtime | yes | Summary of ArgoCD app sync/health (one-liner per non-Healthy app); pods in `CreateContainerConfigError`/`ImagePullBackOff`/`CrashLoopBackOff`; PVCs in `Pending`; services with zero endpoints |
| 7 | Image reachability | yes (needs crane) | Each distinct image+tag used by running/pending pods resolvable via `crane digest`. Images are sourced from live pods (not manifests), so this layer is skipped when `--scope=repo`. If `crane` not on PATH, prompt to install via `brew install crane`; on decline, skip the layer with an info message |
| 8 | Ingress reachability | yes (needs curl) | Structural: each Ingress `backend.service.name` references an existing Service in the same namespace with a matching port, and that Service has endpoints (>0 pods). HTTP probe: `curl -skI https://<host>/` returns a non-error response (2xx/3xx/401/403 = reachable; connection refused / timeout / 5xx = error). TLS SAN: presented cert's SANs cover the hostname (catches "added ingress but didn't run `renew-tls`"). Skipped if no ingress manifests in repo |
| 9 | Hygiene / drift | yes | ArgoCD Applications in cluster with no matching `argocd/apps/*.yaml` file (orphan); namespaces not targeted by any Application; `.sealed-secrets-cert.pem` hash matches the controller's active cert via `kubeseal --fetch-cert` |

**Severity rules:**

- **ERROR** — definitively broken or will break: missing Secret ref, missing
  creds for private repo, pod stuck, cert/key mismatch, Application path
  doesn't exist.
- **WARN** — likely problem or drift: orphans, missing registry creds on
  private-looking image, unreachable image (crane), sealed-cert hash
  mismatch.
- **INFO** — skipped layers, suggestions, non-actionable notes.

**Crane handling:** hard dependency on existence only at layer 7. First run
without `crane`, doctor prompts `"crane enables image reachability checks.
Install via 'brew install crane'? [y/N]"` using `gum confirm`. Yes → run `brew
install crane`, then continue. No → skip layer 7 with "install crane later to
enable" info. No persisted "don't ask" flag; re-prompts on subsequent runs.

## Output format

Grouped by layer (reinforces the "fast layers gate slow ones" mental model).
When `--app`/`--env` is set, the header shows the filter and checks for
out-of-scope resources are silently skipped.

**Clean layer** (one line):

```
  ▸ Layer 5: Credentials ✓
```

**Layer with findings** (gum-bordered box):

```
╭─ ▸ Layer 4: Repo↔cluster alignment ──────────────────────╮
│                                                           │
│  ✗ postgres-staging                                       │
│     Secret 'postgres-secrets' referenced but missing      │
│     why:  base statefulset.yaml uses secretKeyRef for     │
│           POSTGRES_USER/POSTGRES_PASSWORD, but            │
│           overlays/staging/kustomization.yaml does not    │
│           include a sealed-secret.yaml resource           │
│     fix:  secret-ctl.sh add postgres staging \            │
│             --keys POSTGRES_USER,POSTGRES_PASSWORD        │
│                                                           │
│  ⚠ backend-prod                                           │
│     configMapRef has no key 'DATABASE_URL' in overlay     │
│     …                                                     │
│                                                           │
╰───────────────────────────────────────────────────────────╯
```

**With `--verbose`**, each finding gains:

```
     evidence:
       - k8s/apps/postgres/base/statefulset.yaml:22
         (secretKeyRef.name: postgres-secrets)
       - k8s/apps/postgres/overlays/staging/kustomization.yaml
         (no sealed-secret.yaml in resources:)
       - kubectl -n staging get secret postgres-secrets → NotFound
```

**Summary footer:**

```
╭─ ▸ Summary ──────────────────────────────╮
│  9 layers checked, 1 skipped             │
│  ✗ 3 errors  ⚠ 2 warnings  ℹ 0 info      │
│  Exit: 2                                 │
╰──────────────────────────────────────────╯
```

**Icons & colors** (via gum, matching existing commands):

- `✓` green, `✗` red, `⚠` yellow, `ℹ` dim, `○` dim (skipped), `▸` bold.
- Layer headers bold; `why:`/`fix:`/`evidence:` labels dim; finding subject
  bold.
- Box borders via `gum style --border rounded --padding "0 1"`.

## Implementation structure

New functions in `cluster-ctl.sh`:

```
cmd_doctor()                       # entry point
  ├─ doctor_layer_1_prereqs()
  ├─ doctor_layer_2_controllers()
  ├─ doctor_layer_3_repo_structure()
  ├─ doctor_layer_4_alignment()
  ├─ doctor_layer_5_credentials()
  ├─ doctor_layer_6_runtime()
  ├─ doctor_layer_7_images()
  ├─ doctor_layer_8_ingress()
  └─ doctor_layer_9_hygiene()

doctor_error   <subject> <message> <why> <fix> [evidence...]
doctor_warn    <subject> <message> <why> <fix> [evidence...]
doctor_info    <subject> <message>
doctor_clean   <layer_name>
```

Emitters append structured findings to per-layer arrays; rendering happens at
layer boundaries, keeping layer logic free of formatting.

**Shared state** (bash globals scoped to doctor):

```
DOCTOR_ERRORS=0
DOCTOR_WARNINGS=0
DOCTOR_SKIPPED_LAYERS=()
DOCTOR_VERBOSE=0
DOCTOR_SCOPE="all"
DOCTOR_APP=""
DOCTOR_ENV=""
DOCTOR_CLUSTER_REACHABLE=0   # set by layer 1
```

**Layer gating:**

```bash
needs_cluster_or_skip "<layer name>" || return 0
```

checks `DOCTOR_SCOPE != "repo"` and `DOCTOR_CLUSTER_REACHABLE == 1`. If either
fails, the layer prints a skipped one-liner and returns.

**Layer 4 sub-helpers (new):**

```
scan_workload_secret_refs <app> <env>       # parse base/*.yaml for
                                             # secretKeyRef + envFrom.secretRef
scan_workload_configmap_refs <app> <env>
overlay_has_resource <app> <env> <filename> # yq check of kustomization
                                             # resources:
namespace_has_secret <env> <secret-name>    # kubectl; only if scope != repo
```

**Reused from `lib/common.sh`:**

- `detect_envs`, `detect_apps`, `detect_projects`, `detect_app_project`
- `is_kargo_enabled`, `read_promotion_order`
- `load_conf`, `print_*` styled output
- `require_cmd`, `require_gum`

**New in `lib/common.sh`:**

- `parse_yaml_field <file> <yq-expr>` — thin yq wrapper with error handling
- `kustomization_resources <kustomization.yaml>` — returns resource list

## Files touched

**`cluster-ctl.sh`:**

- Add `cmd_doctor()` + 9 layer functions + 4 finding emitters (~350–450 LOC).
- Add `doctor` case in `main()` dispatcher.
- Add `doctor` line in `usage()`.
- Each kubectl/yq call uses the existing `run_cmd` pattern so `--explain`
  works for learning.

**`lib/common.sh`:**

- Add `parse_yaml_field()` and `kustomization_resources()`.

**`completions.zsh`:**

- Add `doctor` to the command list.
- Add flag completions for `--scope`, `--app`, `--env`, `--verbose`.
- Dynamic completions: `--app` uses `detect_apps`, `--env` uses `detect_envs`
  (reuse existing dynamic completion pattern).

**`AGENTS.md`:**

- Add `cmd_doctor` to the command inventory under the cluster-ctl.sh bullet.

**No new files.** No new templates, no new placeholders.

## Test plan

Manual test plan, executed against the live `gitops-practice` repo + a k3d
cluster. One scenario per layer, each deliberately breaks something, runs
`doctor`, and verifies the correct finding appears with the correct fix hint
and the correct exit code.

| # | Break | Expected |
|---|-------|----------|
| 1 | Stop docker daemon | Layer 1: ✗ docker daemon not running; exit 2 |
| 2 | `kubectl delete ns argocd` | Layer 2: ✗ argocd deployments not Ready; exit 2 |
| 3 | Edit `argocd/apps/backend-dev.yaml` to point `path` at `k8s/apps/backend/overlays/nonexistent` | Layer 3: ✗ Application references missing overlay path; exit 2 |
| 4 | Reproduces today's bug as-is: run against `gitops-practice` | Layer 4: ✗ postgres-staging Secret 'postgres-secrets' referenced but missing; exit 2 |
| 5 | Set repo private in GitHub, delete ArgoCD repo credential secret | Layer 5: ✗ Private repo without ArgoCD repo creds; exit 2 |
| 6 | `kubectl delete secret postgres-secrets -n staging` (if present) | Layer 6: ✗ postgres-0 in CreateContainerConfigError; exit 2 |
| 7 | Edit a manifest to reference `postgres:99-fake` tag | Layer 7: ⚠ Image not resolvable via crane; exit 1 (warn-only) |
| 8a | Add an ingress host and do not run `renew-tls` | Layer 8: ⚠ TLS cert SANs do not cover `<host>`; exit 1 |
| 8b | Scale a deployment behind an ingress to 0 replicas | Layer 8: ✗ Ingress backend Service has no endpoints; exit 2 |
| 9 | `rm argocd/apps/frontend-prod.yaml` from repo, leave Application in cluster | Layer 9: ⚠ Orphan Application in cluster; exit 1 |

Scenarios 4 and 6 are already live against the current cluster — a doctor run
today should catch them and exit 2. Other scenarios should be run on a scratch
branch/cluster and reverted after.

**Non-goals for testing:**

- No automated test harness (bats/shellspec). Matches current project culture.
- No CI integration for `doctor` itself (though users may add it to their own
  pre-push hooks; exit codes are designed for that).
