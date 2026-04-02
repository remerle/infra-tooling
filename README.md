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
- `kargo/` -- Kargo progressive delivery configuration (optional, see `enable-kargo`)
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

## Example: Deploying an Application

This walkthrough deploys a two-service e-commerce app (SvelteKit frontend + Fastify backend) with PostgreSQL, from zero to a running local cluster.

The application lives at [github.com/remerle/k8s-practice-app](https://github.com/remerle/k8s-practice-app). CI workflows build and push images to `ghcr.io/remerle/k8s-practice-frontend` and `ghcr.io/remerle/k8s-practice-backend`, tagged as `YY.M.<buildNum>`.

### 1. Create the cluster and initialize the repo

```bash
# Create a local k3d cluster with ArgoCD
./cluster-ctl.sh init-cluster
# Answer: expose ports 80/443? yes, install ArgoCD? yes

# Initialize the GitOps repo structure
./infra-ctl.sh init
# Enter your repo URL when prompted
```

### 2. Add environments

```bash
./infra-ctl.sh add-env dev
./infra-ctl.sh add-env staging
```

This creates namespace manifests and sets up the overlay directories that will hold per-environment configuration.

### 3. Add the applications

```bash
# Backend API (Deployment, port 3000)
./infra-ctl.sh add-app backend
# Choose: Deployment, port 3000

# Frontend (Deployment, port 3000)
./infra-ctl.sh add-app frontend
# Choose: Deployment, port 3000

# PostgreSQL (StatefulSet, port 5432)
./infra-ctl.sh add-app postgres
# Choose: StatefulSet, port 5432
```

Each command generates a Kustomize base, per-env overlays, and ArgoCD Application manifests.

### 4. Write the actual Kubernetes manifests

The tooling creates the scaffold; you provide the workload definitions. For each app, create a Deployment or StatefulSet in the base directory.

**`k8s/apps/backend/base/deployment.yaml`:**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  labels:
    app: backend
spec:
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
    spec:
      containers:
        - name: backend
          image: ghcr.io/remerle/k8s-practice-backend:26.4.9
          ports:
            - containerPort: 3000
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: backend-secrets
                  key: database-url
          livenessProbe:
            httpGet:
              path: /api/health
              port: 3000
          readinessProbe:
            httpGet:
              path: /api/health
              port: 3000
```

`DATABASE_URL` contains credentials, so it goes in a Secret (see step 5). The image tag should match a version from the CI workflow (format: `YY.M.<buildNum>`). For admin features, you'd also add `FIREBASE_PROJECT_ID` and `CORS_ORIGIN` via a ConfigMap, but they're not needed to get the storefront running. Product image uploads require a PersistentVolumeClaim mounted at `/data/images`; without it, uploaded images are lost on pod restart.

**`k8s/apps/frontend/base/deployment.yaml`:**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  labels:
    app: frontend
spec:
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
        - name: frontend
          image: ghcr.io/remerle/k8s-practice-frontend:26.4.8
          ports:
            - containerPort: 3000
          env:
            - name: API_URL
              value: "http://backend:3000"
```

`API_URL` tells the frontend's server-side proxy where to forward API requests. The `backend` hostname resolves via the Kubernetes Service created by `add-app`. Firebase config is only needed for admin auth. The image tag in the base manifest is a starting point; per-environment overlays control which version actually runs (via the `images` field in `kustomization.yaml`).

**`k8s/apps/postgres/base/statefulset.yaml`:**

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  labels:
    app: postgres
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_DB
              value: app
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: postgres-secrets
                  key: username
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-secrets
                  key: password
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 1Gi
```

### 5. Create secrets

The backend and postgres manifests reference Secrets for credentials. Use Sealed Secrets to create encrypted secrets that are safe to commit:

```bash
# Install the Sealed Secrets controller
./secret-ctl.sh init

# PostgreSQL credentials
./secret-ctl.sh add postgres dev
# Enter: username=appuser, password=devpassword

# Backend database connection string (must match the postgres credentials above)
./secret-ctl.sh add backend dev
# Enter: database-url=postgresql://appuser:devpassword@postgres:5432/app
```

For a quick local dev setup without Sealed Secrets, you can create plain Secrets directly:

```bash
kubectl create secret generic postgres-secrets -n dev \
  --from-literal=username=appuser --from-literal=password=devpassword
kubectl create secret generic backend-secrets -n dev \
  --from-literal=database-url=postgresql://appuser:devpassword@postgres:5432/app
```

### 7. Commit and push

```bash
git add -A
git commit -m "Deploy e-commerce app to dev and staging"
git push
```

ArgoCD detects the changes and deploys everything. The parent app watches `argocd/apps/`, sees the Application manifests, and each Application syncs its overlay to the cluster.

### 8. Verify

```bash
# Check ArgoCD sync status
kubectl get applications -n argocd

# Check running pods
kubectl get pods -n dev

# Port-forward to access the frontend
kubectl port-forward svc/frontend -n dev 3000:3000
# Open http://localhost:3000
```

### What you end up with

![Cluster View](docs/cluster-view.png)

Every resource in the cluster traces back to a file in the repo. ArgoCD watches Git and keeps the cluster in sync automatically: push a change, and the cluster converges to match.
