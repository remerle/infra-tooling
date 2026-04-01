# Kargo Progressive Delivery Integration

Optional Kargo integration for automated container image promotion through a linear environment pipeline.

## Problem

Currently, promoting a new container image through environments (dev -> staging -> production) is manual: edit the `newTag` field in each overlay's `kustomization.yaml`, commit, and wait for ArgoCD to sync. This is error-prone and easy to forget, especially across multiple apps.

## Solution

Integrate Kargo resource generation into the existing `infra-ctl.sh` and `cluster-ctl.sh` scripts. When enabled, Kargo watches a container registry for new image tags and automatically promotes them through a linear environment pipeline by updating overlay kustomization files via git commits.

The integration is fully optional. Repos without Kargo enabled behave exactly as before.

## Decisions

### Why integrate into existing scripts instead of a new `kargo-ctl.sh`

Kargo resources are tightly coupled to the app/env matrix that `infra-ctl.sh` already manages. Every `add-app` needs a Warehouse and Stages; every `add-env` needs new Stages. A separate script would require the user to remember two commands for every operation, violating the pit-of-success principle. Integrating behind a feature flag keeps the common workflow to a single command.

### Why a promotion-order file instead of interactive pipeline management

A `kargo/promotion-order.txt` file (one env per line) is simpler than tracking pipeline topology in code. It serves as both configuration and documentation. The common case (appending a new env at the end) is automatic; the uncommon case (inserting mid-chain) is a text file edit. This avoids fragile YAML-rewriting logic when inserting stages mid-pipeline.

### Why one Kargo Project per app

Kargo Projects are the isolation boundary for Warehouses and Stages. One per app keeps promotion pipelines independent, matching the existing one-directory-per-app pattern under `k8s/apps/`.

## Configuration

### `.infra-ctl.conf`

New key:

```
KARGO_ENABLED=true
```

Set during `cluster-ctl.sh init-cluster` when user confirms Kargo installation. Defaults to absent (treated as false). Read by `infra-ctl.sh` to gate Kargo resource generation.

### `kargo/promotion-order.txt`

```
dev
staging
production
```

Created during `infra-ctl.sh init` when `KARGO_ENABLED=true`. One environment name per line. First line is the entry point (receives new images directly from the Warehouse). Each subsequent line promotes from the one above it.

Users can manually edit this file to reorder environments. The tooling reads it at generation time; it is not applied to the cluster.

## Directory structure

```
kargo/
  promotion-order.txt              # linear pipeline definition
  <app>/
    project.yaml                   # Kargo Project resource
    warehouse.yaml                 # watches container registry for new tags
    <env>-stage.yaml               # one per environment in the pipeline
```

One directory per app, mirroring `k8s/apps/<app>/`. Stage files named `<env>-stage.yaml` to match the `<app>-<env>.yaml` convention used in `argocd/apps/`.

## Kargo resources

### Project

One per app. Creates the Kargo namespace/project that contains the app's Warehouse and Stages.

### Warehouse

One per app. Watches a container registry for new image tags. Defaults to `ghcr.io/<REPO_OWNER>/<APP_NAME>`, overridable at `add-app` time via interactive prompt.

Subscribes to semver-tagged images. When a new tag appears, the Warehouse creates a new Freight resource.

### Stage (direct)

The first environment in `promotion-order.txt`. Sources freight directly from the Warehouse (`direct: true`). Promotes by:

1. Clearing the git working tree
2. Running `kustomize-set-image` against the app's overlay directory
3. Committing and pushing
4. Triggering an ArgoCD sync

### Stage (promoted)

All subsequent environments. Sources freight from the previous stage (`stages: [<upstream>]`), meaning an image must be verified in the upstream environment before it can be promoted. Same promotion steps as the direct stage, targeting the appropriate overlay directory.

## Script changes

### `cluster-ctl.sh`

**`init-cluster`**: After the ArgoCD install block, add:

```bash
if gum confirm "Install Kargo?"; then
    helm install kargo oci://ghcr.io/akuity/kargo-charts/kargo \
        --namespace kargo --create-namespace \
        --wait --timeout 120s
    # Update KARGO_ENABLED in .infra-ctl.conf if it exists
fi
```

**New command `upgrade-kargo`**: Mirrors `upgrade-argocd`. Re-applies Kargo Helm installation.

**`status`**: Show Kargo pod status when the kargo namespace exists.

### `infra-ctl.sh`

**`init`**: When `KARGO_ENABLED=true`, create `kargo/promotion-order.txt` with default content (`dev`, `staging`, `production`). Remove `.gitkeep` from `kargo/`.

**`add-app <name>`**: When `KARGO_ENABLED=true`, after generating ArgoCD + Kustomize files:

1. Prompt for image path: `gum input --value "ghcr.io/${REPO_OWNER}/${APP_NAME}" --header "Container image:"`
2. Read `promotion-order.txt` to get the env chain
3. Generate `kargo/<app>/project.yaml`
4. Generate `kargo/<app>/warehouse.yaml`
5. For each env in the chain: generate `kargo/<app>/<env>-stage.yaml` (direct for first, promoted for rest)
6. Include generated files in the summary output

If no environments exist yet, generate only the Project and Warehouse. Print: "No environments found. Stages will be created when you run `add-env`."

**`add-env <name>`**: When `KARGO_ENABLED=true`, after generating existing files:

1. Print the current promotion order from `promotion-order.txt`
2. Print: "Environment '<name>' will be appended to the promotion chain. To insert elsewhere, edit kargo/promotion-order.txt first, then re-run."
3. Append the env name to `promotion-order.txt`
4. For each existing app, generate `kargo/<app>/<env>-stage.yaml` with the upstream reference set to the previous env in the chain

**New command `enable-kargo`**: For existing repos that want to add Kargo retroactively:

1. Set `KARGO_ENABLED=true` in `.infra-ctl.conf`
2. Create `kargo/promotion-order.txt`. If environments already exist (detected from `k8s/namespaces/*.yaml`), list them and ask the user to confirm the order via `gum` (reorderable list). If no environments exist, use the defaults (`dev`, `staging`, `production`).
3. For each existing app: generate Project, Warehouse, and Stages for all existing environments
4. Print summary of generated files

### `lib/common.sh`

New functions:

- `is_kargo_enabled()` -- checks `KARGO_ENABLED=true` in `.infra-ctl.conf`; returns 1 if absent or false
- `read_promotion_order()` -- reads `kargo/promotion-order.txt` into an array; fails if file missing and Kargo is enabled

## Templates

New files under `templates/kargo/`:

| Template | Output | Placeholders |
|----------|--------|-------------|
| `project.yaml` | `kargo/<app>/project.yaml` | `{{APP_NAME}}` |
| `warehouse.yaml` | `kargo/<app>/warehouse.yaml` | `{{APP_NAME}}`, `{{IMAGE_REPO}}` |
| `stage-direct.yaml` | `kargo/<app>/<env>-stage.yaml` | `{{APP_NAME}}`, `{{ENV}}`, `{{REPO_URL}}` |
| `stage-promoted.yaml` | `kargo/<app>/<env>-stage.yaml` | `{{APP_NAME}}`, `{{ENV}}`, `{{UPSTREAM_STAGE}}`, `{{REPO_URL}}` |

All templates use the existing `{{PLACEHOLDER}}` convention and `render_template`/`safe_render_template` functions.

### New placeholders

| Placeholder | Source | Used in |
|-------------|--------|---------|
| `{{IMAGE_REPO}}` | User input or default (`ghcr.io/REPO_OWNER/APP_NAME`) | `warehouse.yaml` |
| `{{UPSTREAM_STAGE}}` | Derived from promotion order (previous env's stage name: `<app>-<prev-env>`) | `stage-promoted.yaml` |

## Backward compatibility

- `KARGO_ENABLED` defaults to absent/false. All Kargo codepaths are gated behind `is_kargo_enabled()`.
- Existing repos that ran `init` before this feature get no Kargo resources and no new prompts.
- No existing file formats, templates, or command signatures change.
- The `enable-kargo` command provides a migration path for existing repos.

## Edge cases

| Scenario | Behavior |
|----------|----------|
| `add-env` but `promotion-order.txt` missing | Fail fast: "Run `infra-ctl.sh init` or create `kargo/promotion-order.txt` first" |
| `add-app` with no envs yet | Generate Project + Warehouse only, no Stages. Print info message. |
| `add-env` with no apps yet | Append to `promotion-order.txt` only. No Stages to generate. |
| Env name in `promotion-order.txt` doesn't match `k8s/namespaces/` | Stage still generated; ArgoCD Application reference uses the env name. Kargo will report an error at runtime if the Application doesn't exist, which is the correct fail-fast behavior. |
| `enable-kargo` with existing apps but no `promotion-order.txt` | Show detected environments, ask user to confirm the promotion order via gum, then generate. |

## Testing

No cluster required for the core logic (file generation). Verification approach:

1. `init` with `KARGO_ENABLED=true`: verify `promotion-order.txt` created with `dev`, `staging`, `production`
2. `add-app myapp`: verify Project + Warehouse + 3 Stage files generated; verify chain wiring (dev=direct, staging sources from dev, production sources from staging)
3. `add-env canary`: verify appended to `promotion-order.txt`; verify Stage files generated for existing apps with correct upstream reference
4. `enable-kargo` on existing repo: verify retroactive generation for all apps/envs
5. `KARGO_ENABLED=false`: verify `add-app` and `add-env` produce zero Kargo output
6. All generated YAML parseable by `yq`

## Workflow sequence (updated)

1. `cluster-ctl.sh init-cluster` -- create cluster, install ArgoCD (optional), install Kargo (optional)
2. `infra-ctl.sh init` -- bootstrap repo skeleton (including `promotion-order.txt` if Kargo enabled)
3. `infra-ctl.sh add-project <name>` -- (optional) create access control boundaries
4. `infra-ctl.sh add-env <name>` / `infra-ctl.sh add-app <name>` -- generates ArgoCD + Kustomize + Kargo resources
5. Remaining steps (secrets, RBAC, users) unchanged

For existing repos: `infra-ctl.sh enable-kargo` bootstraps Kargo resources retroactively.
