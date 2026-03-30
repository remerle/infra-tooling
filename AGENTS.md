# Infrastructure Tooling -- Agent Context

Design decisions and conventions for AI agents working in this repository.

## Architecture

Two independent bash scripts in `tooling/`:

- **`infra-ctl.sh`** -- manages the GitOps repository structure (directories, templates, manifests). Git-only; does not interact with any cluster.
- **`cluster-ctl.sh`** -- manages the local k3d cluster lifecycle (creation, ArgoCD installation, teardown). Interacts with Docker and Kubernetes.

Both scripts share common functions via `tooling/lib/common.sh`.

## Directory structure rationale

```
k8s/                    # Kubernetes resources (what gets deployed)
  namespaces/           # One YAML per environment (dev.yaml, staging.yaml)
  apps/                 # One directory per application
    <app>/
      base/             # Kustomize base (shared across environments)
      overlays/<env>/   # Kustomize overlay (environment-specific customizations)
argocd/                 # ArgoCD configuration (how things get deployed)
  parent-app.yaml       # App-of-apps root, watches argocd/apps/
  apps/                 # One Application manifest per app-env combination
  projects/             # AppProject resources (access control)
kargo/                  # Placeholder for Kargo progressive delivery (future)
```

`k8s/` contains what gets deployed. `argocd/` contains how it gets deployed. They are separate concerns.

## Template substitution

Templates use `{{PLACEHOLDER}}` markers replaced by `sed` at generation time. No templating engine or runtime dependency beyond bash and sed.

Templates are in `tooling/templates/`, organized to mirror the output directory structure (`templates/argocd/` outputs to `argocd/`, `templates/k8s/` outputs to `k8s/`).

## Detection logic

The scripts detect existing state by scanning the filesystem:

- **Environments**: `k8s/namespaces/*.yaml` (strip .yaml extension)
- **Applications**: directories under `k8s/apps/`
- **Projects**: `argocd/projects/*.yaml` (strip .yaml extension)
- **App-to-project mapping**: parsed from existing `argocd/apps/<app>-<env>.yaml` manifests (grep for `spec.project`)

No external state store. The filesystem is the source of truth.

## Key decisions

### Why gum is required

All interactive prompts, confirmations, and styled output use [gum](https://github.com/charmbracelet/gum). This is a hard dependency, not optional. Both scripts check for it at startup and fail with install instructions if missing.

### Why projects are separate from the parent app

The parent app (`argocd/parent-app.yaml`) watches `argocd/apps/`. A separate Application (`argocd/apps/projects.yaml`) watches `argocd/projects/`. This is because Application and AppProject are different resource types with different lifecycles and permission concerns. Mixing them in one directory would conflate deployment config with access control.

### Why RBAC is deferred

`init` does not create an AppProject because:
1. At init time, there are no apps or environments to reference
2. The built-in `default` project is permissive and sufficient for getting started
3. `add-project` can be run anytime and offers a better UX because it can populate choices from existing envs/apps

### Convention: app manifests named `<app>-<env>.yaml`

ArgoCD Application manifests in `argocd/apps/` follow the pattern `<app-name>-<env-name>.yaml`. This makes it easy to find all environments for an app or all apps in an environment via glob patterns.

### No assumption about script location

The scripts resolve templates relative to their own location (`$(dirname "$0")/templates/`). The target directory defaults to `$PWD` but can be overridden with `--target-dir`. This makes the tooling portable.

### Configuration in .infra-ctl.conf

Repo URL and owner are stored in `.infra-ctl.conf` at the target directory root. This file is tracked in git so cloners don't need to re-run `init`. It uses simple `KEY=value` format and is sourced by bash.

## Workflow sequence

1. `cluster-ctl.sh init-cluster` -- create a local cluster (optional, independent)
2. `infra-ctl.sh init` -- bootstrap the repo skeleton
3. `infra-ctl.sh add-project <name>` -- (optional) create access control boundaries
4. `infra-ctl.sh add-env <name>` / `infra-ctl.sh add-app <name>` -- in any order

## When modifying these scripts

- All template rendering goes through `render_template()` or `safe_render_template()` in `lib/common.sh`
- Detection functions (`detect_envs`, `detect_apps`, `detect_projects`) are in `lib/common.sh`
- Adding a new command: add a `cmd_<name>` function and a case in the `main()` dispatcher
- Adding a new template: place it in the appropriate `templates/` subdirectory
- Adding a new placeholder: document it in the design spec
