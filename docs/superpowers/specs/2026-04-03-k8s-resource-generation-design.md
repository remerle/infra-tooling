# K8s Resource Generation and Config Management

Generate workload manifests (deployments, statefulsets, ingress) during `add-app`, add a standalone `config-ctl.sh` for ongoing config management, and add `verify` commands to detect missing secrets and config.

## Motivation

Currently `add-app` creates the scaffold (kustomization, service, ArgoCD apps) but leaves the actual workload manifest for the user to write by hand. This creates a gap between "run `add-app`" and "have a deployable application." The user must know the exact YAML structure for deployments, statefulsets, and ingress resources. This feature closes that gap while keeping the manifests inspectable and editable.

## Scope

### In scope
- Extend `add-app` to generate deployment.yaml or statefulset.yaml with prompted values
- Postgres statefulset preset with sensible defaults and walkthrough
- New `add-ingress`/`list-ingress`/`remove-ingress` commands in `infra-ctl.sh`
- New `config-ctl.sh` script (add/list/remove/verify)
- New `secret-ctl.sh verify` command
- Three new templates (deployment, statefulset-postgres, ingress)
- README walkthrough updated to reflect new flow

### Out of scope
- Additional statefulset presets (Redis, MySQL, etc.) -- future work
- Custom (non-preset) statefulset generation -- future work
- Config management for resources outside configMapGenerator

## Design

### 1. New templates

All templates live in `templates/k8s/` and use `{{PLACEHOLDER}}` markers.

#### `templates/k8s/deployment.yaml`

```yaml
# Labels and selectors (app: <name>) are injected by Kustomize commonLabels
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{APP_NAME}}
spec:
  template:
    spec:
      containers:
        - name: {{APP_NAME}}
          image: {{IMAGE}}
          ports:
            - containerPort: {{PORT}}
          envFrom:
            - configMapRef:
                name: {{APP_NAME}}
{{SECRET_ENV_VARS}}
{{PROBES}}
```

- `{{SECRET_ENV_VARS}}` -- multi-line YAML block built in bash. Contains `env:` entries with `secretKeyRef` for each secret mapping. Empty string when no secrets.
- `{{PROBES}}` -- multi-line YAML block built in bash. Contains `livenessProbe` and `readinessProbe` with HTTP GET. Empty string when no probes.
- Both placeholders render as blank lines when empty; a post-render step strips trailing blank lines.

#### `templates/k8s/statefulset-postgres.yaml`

```yaml
# Labels and selectors (app: <name>) are injected by Kustomize commonLabels
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{APP_NAME}}
spec:
  serviceName: {{APP_NAME}}
  replicas: 1
  template:
    spec:
      containers:
        - name: {{APP_NAME}}
          image: {{IMAGE}}
          ports:
            - containerPort: {{PORT}}
          envFrom:
            - configMapRef:
                name: {{APP_NAME}}
          env:
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: {{SECRET_NAME}}
                  key: username
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{SECRET_NAME}}
                  key: password
          livenessProbe:
            exec:
              command: ["pg_isready", "-U", "postgres"]
            initialDelaySeconds: 15
            periodSeconds: 10
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "postgres"]
            initialDelaySeconds: 5
            periodSeconds: 5
          volumeMounts:
            - name: data
              mountPath: {{MOUNT_PATH}}
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: {{STORAGE_SIZE}}
```

- `POSTGRES_DB` comes from the configMapRef (added to base configMapGenerator during the prompt flow).
- `POSTGRES_USER` and `POSTGRES_PASSWORD` come from a secret via `secretKeyRef`.
- Probes use `pg_isready` (baked in, not prompted).

#### `templates/k8s/ingress.yaml`

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{APP_NAME}}
spec:
  rules:
    - host: {{HOST}}
      http:
        paths:
          - path: {{PATH}}
            pathType: Prefix
            backend:
              service:
                name: {{APP_NAME}}
                port:
                  number: {{PORT}}
```

### 2. Extended `add-app` prompt flow

#### Deployment flow

After the existing project, workload type, and port prompts:

1. **Image** (required): `gum input --prompt "Container image: "` -- no default, user must provide (e.g. `ghcr.io/remerle/k8s-practice-backend:latest`)
2. **Secret references** (optional): "Add secret references?" If yes:
   - Secret name: `gum input --prompt "Secret name: " --value "<app>-secrets"`
   - Loop: `gum input --prompt "ENV_NAME=secret-key (empty to finish): "` -- e.g. `DATABASE_URL=database-url`
   - Each entry becomes a `secretKeyRef` env var in the deployment template
3. **Config values** (optional): "Add config values?" If yes:
   - Loop: `gum input --prompt "KEY=VALUE (empty to finish): "` -- e.g. `API_URL=http://backend:3000`
   - Each entry goes into the base `configMapGenerator.literals` array
4. **Health probes** (optional): "Add health probes?" If yes:
   - HTTP GET path: `gum input --prompt "Health check path: " --value "/health"`
   - Port defaults to the app's container port
5. **Kargo prompts** (existing) -- image repo default can be derived from the image entered in step 1 (strip tag)

The deployment template is rendered after confirmation, alongside the existing kustomization/service/overlay/ArgoCD generation.

#### StatefulSet flow

After workload type = StatefulSet:

1. **Preset**: `gum choose` with "postgres" and "custom"
   - "custom" follows the same flow as Deployment (image, secrets, config, probes)
2. **Postgres preset walkthrough** -- each value pre-filled, user hits enter to accept or types to change:
   - Image: `postgres:16-alpine`
   - Port: `5432`
   - Database name: `app` (goes into base configMapGenerator as `POSTGRES_DB=app`)
   - Secret name: `<app>-secrets`
   - Storage size: `1Gi`
   - Mount path: `/var/lib/postgresql/data`
3. The postgres template is rendered with the collected values.
4. Kargo prompts still appear but may be skipped (postgres typically uses a public upstream image).

### 3. `add-ingress` command (infra-ctl.sh)

Three new commands following the add/list/remove convention:

#### `add-ingress [app]`
- Chooser from `detect_apps` if app omitted
- Prompts:
  1. Hostname: `gum input --prompt "Hostname: " --placeholder "app.localhost"`
  2. Path: `gum input --value "/" --prompt "Path: "`
- Auto-detects port from the app's existing `service.yaml` (parses `port:` value)
- Renders `templates/k8s/ingress.yaml` to `k8s/apps/<app>/base/ingress.yaml`
- Adds `ingress.yaml` to the base `kustomization.yaml` resources list via `yq`
- Preview and confirm before writing

#### `list-ingress`
- Scans for `ingress.yaml` files under `k8s/apps/*/base/`
- Shows app name and hostname for each

#### `remove-ingress [app]`
- Chooser from apps that have an ingress if app omitted
- Deletes `k8s/apps/<app>/base/ingress.yaml`
- Removes `ingress.yaml` from the base kustomization resources list via `yq`

### 4. `config-ctl.sh` -- new script

Standalone script for managing configMapGenerator literals in kustomization.yaml files. Follows the same patterns as other scripts (sources `lib/common.sh`, requires gum, supports `--target-dir` and global options).

#### `add [app] [env]`
- Chooser for app (from `detect_apps`) if omitted
- Chooser for env with "base" option + detected envs (from `detect_envs`) if omitted. "base" or no env targets the base kustomization.
- Loop: `gum input --prompt "KEY=VALUE (empty to finish): "`
- Appends each entry to `configMapGenerator[].literals` in the target kustomization.yaml via `yq`

#### `list [app] [env]`
- Chooser for app if omitted
- Chooser for env with "base" + detected envs if omitted
- No env or "base": shows base configMapGenerator literals
- With env: shows merged view (base values with overlay overrides marked)

#### `remove [app] [env]`
- Chooser for app if omitted
- Chooser for env with "base" + detected envs if omitted
- Lists current keys via `gum choose --no-limit`
- Removes selected keys from `configMapGenerator[].literals` via `yq`

#### `verify [env]`
- Chooser for env if omitted
- Scans all workload manifests (`k8s/apps/*/base/deployment.yaml`, `statefulset.yaml`) for `configMapRef` references
- Cross-references with `configMapGenerator.literals` in both base and overlay kustomization.yaml
- Flags any configmap referenced in a workload but missing from the configMapGenerator
- Offers to walk through adding missing values via the `add` flow

### 5. `secret-ctl.sh verify` -- new command

Added to the existing `secret-ctl.sh` script.

#### `verify [env]`
- Chooser for env (from `detect_envs`) if omitted
- Scans all workload manifests (`k8s/apps/*/base/*.yaml`) for `secretKeyRef` entries
- Extracts secret name + key pairs
- For each pair, checks if a sealed secret file exists at `k8s/apps/<app>/overlays/<env>/sealed-secret.yaml`
- If the file exists, parses it to verify the expected key is present in `encryptedData`
- Lists all missing secrets/keys grouped by app
- Offers to walk through creating each missing one via the existing `secret-ctl.sh add` flow

### 6. New template placeholders

| Placeholder | Source | Used in |
|-------------|--------|---------|
| `{{IMAGE}}` | User input (`add-app`) | `deployment.yaml`, `statefulset-postgres.yaml` |
| `{{SECRET_ENV_VARS}}` | Built in bash (`add-app`) | `deployment.yaml` |
| `{{PROBES}}` | Built in bash (`add-app`) | `deployment.yaml` |
| `{{SECRET_NAME}}` | User input or preset default | `statefulset-postgres.yaml` |
| `{{MOUNT_PATH}}` | Preset default or user input | `statefulset-postgres.yaml` |
| `{{STORAGE_SIZE}}` | Preset default or user input | `statefulset-postgres.yaml` |
| `{{HOST}}` | User input (`add-ingress`) | `ingress.yaml` |
| `{{PATH}}` | User input (`add-ingress`, default `/`) | `ingress.yaml` |

### 7. README walkthrough update

The current step 4 ("Write the actual Kubernetes manifests") is replaced by the prompts in `add-app`. The new walkthrough:

1. `cluster-ctl.sh init-cluster` -- create cluster, install ArgoCD + Kargo
2. `infra-ctl.sh init` -- bootstrap repo skeleton
3. `cluster-ctl.sh add-repo-creds` -- (if private repo)
4. `infra-ctl.sh add-env dev` / `add-env staging` / `add-env prod`
5. `infra-ctl.sh add-app backend` -- Deployment, image `ghcr.io/remerle/k8s-practice-backend:latest`, port 3000, secret `backend-secrets` with `DATABASE_URL=database-url`, probe `/api/health`
6. `infra-ctl.sh add-app frontend` -- Deployment, image `ghcr.io/remerle/k8s-practice-frontend:latest`, port 3000, config `API_URL=http://backend:3000`, no secrets
7. `infra-ctl.sh add-app postgres` -- StatefulSet, postgres preset, defaults accepted
8. `infra-ctl.sh add-ingress frontend` -- hostname `app.localhost`
9. `secret-ctl.sh init` -- install Sealed Secrets controller
10. `secret-ctl.sh verify dev` -- find missing secrets, walk through creating them
11. `cluster-ctl.sh add-kargo-creds backend` / `frontend` -- (if private repo/registry)
12. Commit, push, verify

## File inventory

### New files
- `templates/k8s/deployment.yaml` -- deployment template
- `templates/k8s/statefulset-postgres.yaml` -- postgres statefulset template
- `templates/k8s/ingress.yaml` -- ingress template
- `config-ctl.sh` -- new script for config management
- `docs/superpowers/specs/2026-04-03-k8s-resource-generation-design.md` -- this spec

### Modified files
- `infra-ctl.sh` -- extend `cmd_add_app`, add ingress commands, update usage/dispatcher
- `secret-ctl.sh` -- add `cmd_verify`, update usage/dispatcher
- `completions.zsh` -- add ingress completions to infra-ctl, verify to secret-ctl, full config-ctl completions
- `README.md` -- updated walkthrough
- `.claude/agents.md` -- updated agent context with config-ctl documentation and new placeholders

### Unchanged files
- `cluster-ctl.sh` -- no modifications
- `user-ctl.sh` -- no modifications
- `lib/common.sh` -- no modifications (existing `render_template` handles multi-line values)
- All existing templates -- unchanged
