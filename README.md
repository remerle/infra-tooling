# Infrastructure Tooling

CLI tools for managing an ArgoCD GitOps infrastructure repository and local Kubernetes clusters.

## Structure Overview

![Infrastructure Tooling Structure](docs/infra-tooling-structure.png)

## Prerequisites

Install the following tools before using these scripts:

| Tool | Purpose | Install |
|------|---------|---------|
| [gum](https://github.com/charmbracelet/gum) | Interactive terminal prompts | `brew install gum` |
| [k3d](https://k3d.io) | Local Kubernetes clusters (Docker-based) | `brew install k3d` |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | Kubernetes CLI | `brew install kubectl` |
| [Docker](https://www.docker.com/) | Required by k3d | `brew install --cask docker` |

`gum` is required by both scripts. `k3d`, `kubectl`, and Docker are only needed for `cluster-ctl.sh`.

## Getting Started

The typical workflow is:

1. **Set up a cluster** (optional, if you want a local environment):
   ```bash
   ./cluster-ctl.sh init-cluster
   ```

2. **Initialize the repo structure**:
   ```bash
   ./infra-ctl.sh init
   ```

3. **Add a project** (optional, can be done anytime):
   ```bash
   ./infra-ctl.sh add-project my-team
   ```

4. **Add environments and apps** (any order):
   ```bash
   ./infra-ctl.sh add-env dev
   ./infra-ctl.sh add-env staging
   ./infra-ctl.sh add-app postgres
   ./infra-ctl.sh add-app redis
   ```

Steps 3 and 4 can happen in any order. If you add apps before creating a project, they use ArgoCD's built-in `default` project (which allows everything). You can create a project later and reassign apps to it.

## infra-ctl.sh

Manages the GitOps repository structure: directory scaffolding, Kustomize configurations, ArgoCD Application manifests, and namespace definitions.

### Commands

#### `init`

Bootstraps the repository skeleton. Prompts for the Git repository URL (used in ArgoCD Application manifests to tell ArgoCD where to pull configurations from) and creates:

- `k8s/namespaces/` -- where Kubernetes Namespace definitions live (one per environment)
- `k8s/apps/` -- where application configurations live (Kustomize base + overlays per environment)
- `argocd/parent-app.yaml` -- the "app of apps" that tells ArgoCD to watch `argocd/apps/` for Application manifests
- `argocd/apps/projects.yaml` -- tells ArgoCD to watch `argocd/projects/` for AppProject resources
- `argocd/projects/` -- where AppProject resources live (for access control, added later)
- `kargo/` -- placeholder for future Kargo progressive delivery configuration
- `.infra-ctl.conf` -- stores configuration for use by other commands (see below)

```bash
./infra-ctl.sh init
# Or specify a target directory:
./infra-ctl.sh init --target-dir /path/to/repo
```

#### Configuration file (`.infra-ctl.conf`)

The `init` command creates `.infra-ctl.conf` in the target directory. This file is `source`d by bash, so it uses `KEY=value` format:

```
REPO_URL=https://github.com/your-org/your-repo.git
REPO_OWNER=your-org
```

| Key | Description |
|-----|-------------|
| `REPO_URL` | Git repository URL used in ArgoCD Application manifests |
| `REPO_OWNER` | Repository owner, used for project defaults |

Other commands call `load_conf` to read this file. If it is missing, they exit with an error directing you to run `init` first.

#### `add-app <name>`

Scaffolds a new application across all existing environments. Creates:

- A **base** Kustomize configuration (`k8s/apps/<name>/base/kustomization.yaml`) that references the app's Deployment and Service manifests. You add those manifests yourself; this is the starting point.
- An **overlay** per environment (`k8s/apps/<name>/overlays/<env>/kustomization.yaml`) that inherits from the base and lets you customize per-environment settings: which container image tag to deploy, how many replicas to run, and environment-specific variables.
- An **ArgoCD Application** per environment (`argocd/apps/<name>-<env>.yaml`) that tells ArgoCD "deploy this app's overlay for this environment to the correct namespace."

If ArgoCD projects exist, you'll be prompted to choose which project this app belongs to.

```bash
./infra-ctl.sh add-app postgres
```

#### `add-env <name>`

Scaffolds a new environment across all existing applications. Creates:

- A **Namespace** resource (`k8s/namespaces/<name>.yaml`) -- Kubernetes uses namespaces to isolate environments within a cluster.
- An **overlay** per existing app for this environment.
- An **ArgoCD Application** per existing app, pointed at the new overlay.

The script detects which project each app belongs to by reading its existing ArgoCD Application manifests, so project assignments carry over to the new environment automatically.

```bash
./infra-ctl.sh add-env dev
```

#### `add-project <name>`

Creates an ArgoCD AppProject resource. Projects let you control which Git repos can deploy to which namespaces. By default, projects are permissive (allow everything); restrictions are optional and prompted interactively.

This is for organizational and access-control purposes. You don't need a project to get started -- the built-in `default` project works fine until you want to restrict access.

```bash
./infra-ctl.sh add-project backend-team
```

#### `edit-project <name>`

Modifies an existing AppProject. Re-prompts for all fields with current values pre-filled.

```bash
./infra-ctl.sh edit-project backend-team
```

### Global options

All `infra-ctl.sh` commands accept:

- `--target-dir <path>` -- operate on a specific directory instead of the current working directory

### Important behaviors

**Sync policies:** All generated ArgoCD Applications use `prune: true` and `selfHeal: true`. This means:

- **prune** -- If you delete a manifest from Git, ArgoCD deletes the corresponding resource from the cluster. Be deliberate about what you remove.
- **selfHeal** -- If someone manually edits a resource via `kubectl`, ArgoCD reverts it to match Git. Git is the single source of truth; manual changes don't stick.

These are the correct GitOps behaviors, but they can surprise you if you're experimenting with `kubectl` directly.

**Target revision:** All generated ArgoCD Applications use `targetRevision: HEAD`, meaning ArgoCD always tracks the latest commit on the default branch. If you need branch-based or tag-based deployments, edit the generated Application manifests or modify `templates/argocd/app-env.yaml`.

**Cluster resource access:** All generated AppProjects allow `clusterResourceWhitelist: group '*', kind '*'`, granting access to all cluster-scoped resources by default. This is intentionally permissive to avoid blocking initial setup. Restrict this per-project when you're ready to lock down access (see [Adding RBAC restrictions later](#adding-rbac-restrictions-later)).

**No overwrites:** Creation commands (`init`, `add-app`, `add-env`, `add-project`) never overwrite existing files. If a file already exists, they print a warning and skip it. The `edit-project` command overwrites the project file by design.

## cluster-ctl.sh

Manages the local k3d Kubernetes cluster lifecycle. Independent from `infra-ctl.sh` -- you can use one without the other.

### Commands

#### `init-cluster`

Creates a local Kubernetes cluster using k3d (which runs Kubernetes inside Docker containers). Prompts for cluster name, number of agent nodes, and whether to expose ports for ingress. Optionally installs ArgoCD into the cluster.

```bash
./cluster-ctl.sh init-cluster
```

#### `delete-cluster`

Tears down a k3d cluster. Lists existing clusters and prompts for which one to delete.

```bash
./cluster-ctl.sh delete-cluster
```

#### `status`

Shows current cluster status: k3d clusters, kubectl context, and ArgoCD pod health.

```bash
./cluster-ctl.sh status
```

## Templates

Templates live in `templates/` and use `{{PLACEHOLDER}}` markers that get replaced when generating files. They're organized by where their output ends up:

- `templates/argocd/` -- ArgoCD Application and AppProject manifests
- `templates/k8s/` -- Kubernetes resources (namespaces, Kustomize configurations)

| Template file | Generates |
|---------------|-----------|
| `templates/argocd/parent-app.yaml` | The "app of apps" Application (`argocd/parent-app.yaml`) |
| `templates/argocd/projects-app.yaml` | The Application that watches for AppProjects (`argocd/apps/projects.yaml`) |
| `templates/argocd/app-env.yaml` | Per-app, per-environment Application manifests (`argocd/apps/<name>-<env>.yaml`) |
| `templates/argocd/appproject.yaml` | AppProject resources (`argocd/projects/<name>.yaml`) |
| `templates/k8s/base-kustomization.yaml` | Base Kustomize config for an app (`k8s/apps/<name>/base/kustomization.yaml`) |
| `templates/k8s/overlay-kustomization.yaml` | Per-environment overlay (`k8s/apps/<name>/overlays/<env>/kustomization.yaml`) |
| `templates/k8s/namespace.yaml` | Namespace resource (`k8s/namespaces/<name>.yaml`) |

You don't need to edit templates for normal usage. They define the structure; the scripts fill in the values.

## Adding RBAC restrictions later

ArgoCD projects support restricting what can be deployed where. When you're ready:

1. Run `infra-ctl.sh edit-project <name>` to add restrictions interactively
2. Or edit `argocd/projects/<name>.yaml` directly

Common restrictions:
- **Source repos**: limit which Git repos can deploy through this project
- **Destination namespaces**: limit which namespaces this project's apps can deploy to
- **Resource types**: limit what Kubernetes resource types can be created

Kubernetes-level RBAC (restricting what humans can do with `kubectl`) is a separate concern not yet covered by these tools.

## Example: What You Get

After running these commands:

```bash
./infra-ctl.sh init
./infra-ctl.sh add-project platform-team
./infra-ctl.sh add-env dev
./infra-ctl.sh add-env staging
./infra-ctl.sh add-app frontend
./infra-ctl.sh add-app backend
./infra-ctl.sh add-app database
```

Your cluster ends up looking like this:

![Cluster View](docs/cluster-view.png)

Every resource in the cluster traces back to a file in the repo. ArgoCD watches Git and keeps the cluster in sync automatically: push a change, and the cluster converges to match.
