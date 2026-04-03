# K8s Resource Generation and Config Management

Generate workload manifests (deployments, statefulsets, ingress) during `add-app`, add a standalone `config-ctl.sh` for ongoing config management, and add `verify` commands to detect missing secrets and config.

## Motivation

Currently `add-app` creates the scaffold (kustomization, service, ArgoCD apps) but leaves the actual workload manifest for the user to write by hand. This creates a gap between "run `add-app`" and "have a deployable application." The user must know the exact YAML structure for deployments, statefulsets, and ingress resources. This feature closes that gap while keeping the manifests inspectable and editable.

## Scope

### In scope
- Extend `add-app` to generate deployment.yaml or statefulset.yaml with prompted values
- Preset system with frontmatter-driven defaults for both deployments and statefulsets
- Web deployment preset and postgres statefulset preset
- New `add-ingress`/`list-ingress`/`remove-ingress` commands in `infra-ctl.sh`
- New `config-ctl.sh` script (add/list/remove/verify)
- New `secret-ctl.sh verify` command
- New templates (deployment-web, statefulset-postgres, ingress)
- README walkthrough updated to reflect new flow

### Out of scope
- Additional statefulset presets (Redis, MySQL, etc.) -- future work
- Additional deployment presets -- future work
- Config management for resources outside configMapGenerator

## Design

### 1. Preset frontmatter system

Workload templates use YAML frontmatter (delimited by `---`) to declare their preset name, defaults, and config values. The script:

1. Scans `templates/k8s/deployment-*.yaml` and `templates/k8s/statefulset-*.yaml` to auto-discover presets
2. Reads frontmatter with `yq` to get `preset` name and `description` for the chooser
3. Walks through each `defaults` entry with `gum input --value <default>` (user hits enter to accept or types to change)
4. Adds each `config` entry to the base configMapGenerator (also walkable/tweakable)
5. Strips the frontmatter, renders the template body with `render_template`

`{{APP_NAME}}` references in frontmatter defaults (e.g. `SECRET_NAME: "{{APP_NAME}}-secrets"`) are resolved before prompting.

Adding a new preset is just adding a new template file with frontmatter -- no bash changes required.

### 2. New templates

All templates live in `templates/k8s/`.

#### `templates/k8s/deployment-web.yaml`

```yaml
---
preset: web
description: Web application
defaults:
  IMAGE: ""
  PORT: "3000"
  SECRET_NAME: "{{APP_NAME}}-secrets"
  PROBE_PATH: "/api/health"
optional:
  - SECRET_NAME
  - PROBE_PATH
config: {}
---
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

- `IMAGE` has no default (empty string = required, must be provided).
- `SECRET_NAME` and `PROBE_PATH` are listed in `optional` -- the user is asked "Add secret references?" / "Add health probes?" before being prompted for these values. If declined, the corresponding template blocks (`{{SECRET_ENV_VARS}}`, `{{PROBES}}`) render empty.
- `config` is empty -- the user is still asked "Add config values?" and can enter key=value pairs interactively.

When secrets are accepted, the script prompts for env var mappings (`ENV_NAME=secret-key`) in a loop, building the `{{SECRET_ENV_VARS}}` YAML block.

When probes are accepted, the script builds the `{{PROBES}}` block using `PROBE_PATH` and `PORT`.

#### `templates/k8s/statefulset-postgres.yaml`

```yaml
---
preset: postgres
description: PostgreSQL database
defaults:
  IMAGE: "postgres:16-alpine"
  PORT: "5432"
  SECRET_NAME: "{{APP_NAME}}-secrets"
  STORAGE_SIZE: "1Gi"
  MOUNT_PATH: "/var/lib/postgresql/data"
config:
  POSTGRES_DB: "app"
---
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

- All `defaults` are pre-filled and walked through with gum input.
- `config.POSTGRES_DB` is added to the base configMapGenerator (also tweakable during walkthrough).
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

No frontmatter -- ingress is not a preset-driven template.

### 3. Extended `add-app` prompt flow

#### Common flow (both workload types)

1. Project selection (existing)
2. Workload type: Deployment or StatefulSet (existing)
3. **Preset selection**: `gum choose` from auto-discovered presets + "custom"
   - Deployment presets discovered from `templates/k8s/deployment-*.yaml`
   - StatefulSet presets discovered from `templates/k8s/statefulset-*.yaml`
   - "custom" follows a freeform flow (image, port, optional secrets/config/probes)

#### Preset flow

4. Walk through each `defaults` entry with gum input (value pre-filled from frontmatter)
   - Entries with empty default (e.g. `IMAGE: ""`) are required
   - Entries listed in `optional` are gated by a yes/no question first
5. Walk through each `config` entry with gum input (value pre-filled from frontmatter)
6. "Add more config values?" -- additional key=value loop
7. For deployment presets with secrets accepted: prompt for env var mappings in a loop
8. Preview and confirm
9. Render template body + kustomization + service + overlays + ArgoCD apps
10. Kargo prompts (existing) -- image repo default derived from IMAGE (strip tag)

#### Custom flow

Same as current deployment flow but with explicit prompts:
- Image (required)
- Port (default 8080)
- Secret references (optional, loop)
- Config values (optional, loop)
- Health probes (optional, HTTP GET path)

### 4. `add-ingress` command (infra-ctl.sh)

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

### 5. `config-ctl.sh` -- new script

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

### 6. `secret-ctl.sh verify` -- new command

Added to the existing `secret-ctl.sh` script.

#### `verify [env]`
- Chooser for env (from `detect_envs`) if omitted
- Scans all workload manifests (`k8s/apps/*/base/*.yaml`) for `secretKeyRef` entries
- Extracts secret name + key pairs
- For each pair, checks if a sealed secret file exists at `k8s/apps/<app>/overlays/<env>/sealed-secret.yaml`
- If the file exists, parses it to verify the expected key is present in `encryptedData`
- Lists all missing secrets/keys grouped by app
- Offers to walk through creating each missing one via the existing `secret-ctl.sh add` flow

### 7. New template placeholders

| Placeholder | Source | Used in |
|-------------|--------|---------|
| `{{IMAGE}}` | Frontmatter default or user input | `deployment-web.yaml`, `statefulset-postgres.yaml` |
| `{{SECRET_ENV_VARS}}` | Built in bash (`add-app`) | `deployment-web.yaml` |
| `{{PROBES}}` | Built in bash (`add-app`) | `deployment-web.yaml` |
| `{{SECRET_NAME}}` | Frontmatter default or user input | `statefulset-postgres.yaml`, `deployment-web.yaml` (when secrets accepted) |
| `{{MOUNT_PATH}}` | Frontmatter default or user input | `statefulset-postgres.yaml` |
| `{{STORAGE_SIZE}}` | Frontmatter default or user input | `statefulset-postgres.yaml` |
| `{{PROBE_PATH}}` | Frontmatter default or user input | Used to build `{{PROBES}}` block |
| `{{HOST}}` | User input (`add-ingress`) | `ingress.yaml` |
| `{{PATH}}` | User input (`add-ingress`, default `/`) | `ingress.yaml` |

### 8. README walkthrough update

The current step 4 ("Write the actual Kubernetes manifests") is replaced by the prompts in `add-app`. The new walkthrough:

1. `cluster-ctl.sh init-cluster` -- create cluster, install ArgoCD + Kargo
2. `infra-ctl.sh init` -- bootstrap repo skeleton
3. `cluster-ctl.sh add-repo-creds` -- (if private repo)
4. `infra-ctl.sh add-env dev` / `add-env staging` / `add-env prod`
5. `infra-ctl.sh add-app backend` -- Deployment, web preset, image `ghcr.io/remerle/k8s-practice-backend:latest`, port 3000, secret `backend-secrets` with `DATABASE_URL=database-url`, probe `/api/health`
6. `infra-ctl.sh add-app frontend` -- Deployment, web preset, image `ghcr.io/remerle/k8s-practice-frontend:latest`, port 3000, config `API_URL=http://backend:3000`, no secrets, no probes
7. `infra-ctl.sh add-app postgres` -- StatefulSet, postgres preset, defaults accepted
8. `infra-ctl.sh add-ingress frontend` -- hostname `app.localhost`
9. `secret-ctl.sh init` -- install Sealed Secrets controller
10. `secret-ctl.sh verify dev` -- find missing secrets, walk through creating them
11. `cluster-ctl.sh add-kargo-creds backend` / `frontend` -- (if private repo/registry)
12. Commit, push, verify

## File inventory

### New files
- `templates/k8s/deployment-web.yaml` -- web deployment preset template
- `templates/k8s/statefulset-postgres.yaml` -- postgres statefulset preset template
- `templates/k8s/ingress.yaml` -- ingress template
- `config-ctl.sh` -- new script for config management
- `docs/superpowers/specs/2026-04-03-k8s-resource-generation-design.md` -- this spec

### Modified files
- `infra-ctl.sh` -- extend `cmd_add_app` with preset system, add ingress commands, update usage/dispatcher
- `secret-ctl.sh` -- add `cmd_verify`, update usage/dispatcher
- `completions.zsh` -- add ingress completions to infra-ctl, verify to secret-ctl, full config-ctl completions
- `README.md` -- updated walkthrough
- `.claude/agents.md` -- updated agent context with preset system, config-ctl documentation, and new placeholders

### Unchanged files
- `cluster-ctl.sh` -- no modifications
- `user-ctl.sh` -- no modifications
- `lib/common.sh` -- no modifications (existing `render_template` handles multi-line values)
- All existing templates -- unchanged

### Removed templates
- `templates/k8s/deployment.yaml` -- replaced by `deployment-web.yaml` (preset naming convention)
