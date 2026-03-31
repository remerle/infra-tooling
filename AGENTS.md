# Infrastructure Tooling -- Agent Context

Design decisions and conventions for AI agents working in this repository.

## Architecture

Two independent bash scripts at the repository root:

- **`infra-ctl.sh`** -- manages the GitOps repository structure (directories, templates, manifests). Git-only; does not interact with any cluster.
- **`cluster-ctl.sh`** -- manages the local k3d cluster lifecycle (creation, ArgoCD installation, teardown). Interacts with Docker and Kubernetes.
- **`secret-ctl.sh`** -- manages per-environment secrets using Bitnami Sealed Secrets. Interacts with the cluster (for controller install and key management) and writes encrypted SealedSecret files to the repo.

Both scripts share common functions via `lib/common.sh`.

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

Sealed secrets live in overlay directories (`k8s/apps/<app>/overlays/<env>/sealed-secret.yaml`). The public cert (`.sealed-secrets-cert.pem`) is committed to the repo root. The private key backup (`.sealed-secrets-key.json`) is gitignored.

## Template substitution

Templates use `{{PLACEHOLDER}}` markers replaced by bash parameter expansion at generation time. No templating engine or runtime dependency beyond bash.

Templates are in `templates/`, organized to mirror the output directory structure (`templates/argocd/` outputs to `argocd/`, `templates/k8s/` outputs to `k8s/`).

### Template placeholders

| Placeholder | Source | Used in |
|-------------|--------|---------|
| `{{REPO_URL}}` | `.infra-ctl.conf` | `app-env.yaml`, `parent-app.yaml`, `projects-app.yaml` |
| `{{REPO_OWNER}}` | `.infra-ctl.conf` | `overlay-kustomization.yaml` |
| `{{APP_NAME}}` | User input (`add-app`) | `app-env.yaml`, `overlay-kustomization.yaml`, `configmap.yaml`, `service.yaml`, `service-headless.yaml` |
| `{{ENV}}` | User input (`add-env`) or detection | `app-env.yaml`, `namespace.yaml`, `overlay-kustomization.yaml` |
| `{{PROJECT}}` | User input or detection (`detect_app_project`) | `app-env.yaml` |
| `{{PROJECT_NAME}}` | User input (`add-project`) | `appproject.yaml` |
| `{{PROJECT_DESCRIPTION}}` | User input (`add-project`) | `appproject.yaml` |
| `{{SOURCE_REPOS}}` | Generated YAML list (`add-project`) | `appproject.yaml` |
| `{{DESTINATIONS}}` | Generated YAML list (`add-project`) | `appproject.yaml` |

## Detection logic

The scripts detect existing state by scanning the filesystem:

- **Environments**: `k8s/namespaces/*.yaml` (strip .yaml extension)
- **Applications**: directories under `k8s/apps/`
- **Projects**: `argocd/projects/*.yaml` (strip .yaml extension)
- **App-to-project mapping**: parsed from existing `argocd/apps/<app>-<env>.yaml` manifests (grep for `project:` key)

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
5. `secret-ctl.sh init` -- install Sealed Secrets controller (requires running cluster)
6. `secret-ctl.sh add <app> <env>` -- encrypt and store per-environment secrets

## When modifying these scripts

- Adding a new command: add a `cmd_<name>` function and a case in the `main()` dispatcher
- Adding a new template: place it in the appropriate `templates/` subdirectory
- Adding a new placeholder: add it to the "Template placeholders" table above

### `lib/common.sh` function inventory

**Dependency checking:**
- `require_cmd(cmd, install_hint)` -- exits with an error if `cmd` is not on PATH
- `require_gum()` -- exits with an error and install instructions if `gum` is not on PATH

**Configuration:**
- `load_conf()` -- sources `.infra-ctl.conf` from `TARGET_DIR`; fails if missing
- `save_conf()` -- writes `REPO_URL` and `REPO_OWNER` to `.infra-ctl.conf`

**Template rendering:**
- `render_template(template, output, KEY=value...)` -- renders a template to an output path, replacing `{{KEY}}` placeholders via bash parameter expansion
- `safe_render_template(template, output, KEY=value...)` -- same as `render_template` but skips if the output file already exists
- `safe_write(output, content)` -- writes content to a file only if it does not already exist

**Detection (filesystem scanning):**
- `detect_envs()` -- lists environments from `k8s/namespaces/*.yaml`
- `detect_apps()` -- lists applications from directories under `k8s/apps/`
- `detect_projects()` -- lists projects from `argocd/projects/*.yaml`
- `detect_app_project(app_name)` -- finds which project an app belongs to by grepping existing manifests

**Repo URL parsing:**
- `extract_repo_owner(url)` -- extracts the GitHub owner from an HTTPS or SSH repo URL

**Styled output (gum wrappers):**
- `print_header(msg)`, `print_success(msg)`, `print_warning(msg)`, `print_error(msg)`, `print_info(msg)` -- colored terminal output
- `print_summary(files...)` -- prints a summary of created files
