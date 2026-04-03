# K8s Resource Generation and Config Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate workload manifests (deployments, statefulsets, ingress) during `add-app` using a frontmatter-driven preset system, add `config-ctl.sh` for managing configMapGenerator literals, and add `verify` commands to detect missing secrets and config.

**Architecture:** Workload templates use YAML frontmatter to declare preset defaults and config values. The script auto-discovers presets by scanning template filenames, reads frontmatter with `yq`, walks through defaults with `gum input`, strips frontmatter, and renders the template body with existing `render_template`. A new `config-ctl.sh` script manipulates `configMapGenerator.literals` arrays in kustomization.yaml files via `yq`. New `verify` commands in both `config-ctl.sh` and `secret-ctl.sh` scan workload manifests for unresolved references.

**Tech Stack:** Bash, gum (interactive prompts), yq (YAML manipulation), existing template rendering infrastructure

**Spec:** `docs/superpowers/specs/2026-04-03-k8s-resource-generation-design.md`

---

### Task 1: Create workload templates

**Files:**
- Create: `templates/k8s/deployment-web.yaml`
- Create: `templates/k8s/statefulset-postgres.yaml`
- Create: `templates/k8s/ingress.yaml`

- [ ] **Step 1: Create the deployment-web template**

Create `templates/k8s/deployment-web.yaml`:

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

- [ ] **Step 2: Create the statefulset-postgres template**

Create `templates/k8s/statefulset-postgres.yaml`:

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

- [ ] **Step 3: Create the ingress template**

Create `templates/k8s/ingress.yaml`:

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

- [ ] **Step 4: Validate and commit**

Run: `make validate`
Expected: PASS (templates are not .sh files, won't be linted, but ensure no regressions)

```bash
git add templates/k8s/deployment-web.yaml templates/k8s/statefulset-postgres.yaml templates/k8s/ingress.yaml
git commit -m "Add workload and ingress templates

- deployment-web.yaml: web preset with frontmatter defaults (port 3000, /api/health probe)
- statefulset-postgres.yaml: postgres preset with pg_isready probes and PVC
- ingress.yaml: simple ingress template (no frontmatter)"
```

---

### Task 2: Add preset frontmatter helpers to `lib/common.sh`

These functions parse the YAML frontmatter from preset templates, enabling auto-discovery and default walkthroughs.

**Files:**
- Modify: `lib/common.sh` (add functions after the existing template rendering section, around line 565)

- [ ] **Step 1: Add `discover_presets` function**

Add after `safe_render_template` in `lib/common.sh`. This function scans template filenames to find available presets for a workload type.

```bash
# Discovers available presets for a workload type by scanning template filenames.
# Usage: discover_presets "deployment" -> outputs "web" (one per line)
#        discover_presets "statefulset" -> outputs "postgres" (one per line)
discover_presets() {
    local workload_type="$1"
    local pattern="${TEMPLATE_DIR}/k8s/${workload_type}-*.yaml"
    local file
    for file in $pattern; do
        [[ -f "$file" ]] || continue
        local basename
        basename="$(basename "$file" .yaml)"
        # Strip the workload type prefix: "deployment-web" -> "web"
        echo "${basename#"${workload_type}-"}"
    done
}
```

- [ ] **Step 2: Add `read_preset_frontmatter` function**

This function extracts the YAML frontmatter (everything between the two `---` delimiters) from a template file and outputs it as a standalone YAML document.

```bash
# Extracts YAML frontmatter from a preset template file.
# Frontmatter is delimited by --- at the start and end.
# Usage: read_preset_frontmatter "templates/k8s/deployment-web.yaml"
# Output: the frontmatter YAML (without delimiters)
read_preset_frontmatter() {
    local template="$1"
    sed -n '1{/^---$/d}; /^---$/q; p' "$template"
}
```

- [ ] **Step 3: Add `read_preset_body` function**

This function extracts the template body (everything after the second `---` delimiter).

```bash
# Extracts the template body (after frontmatter) from a preset template file.
# Usage: read_preset_body "templates/k8s/deployment-web.yaml"
# Output: the template body (YAML content after second ---)
read_preset_body() {
    local template="$1"
    sed '1,/^---$/d' "$template" | sed '1,/^---$/d'
}
```

Wait -- that double-sed won't work correctly because the first `---` is line 1. The frontmatter format is:

```
---        <- line 1 (opening delimiter)
key: val   <- frontmatter content
---        <- closing delimiter
body...    <- template body
```

So `sed '1,/^---$/d'` skips from line 1 to the first `---` match. But line 1 *is* `---`, so this deletes only line 1 and stops. We need to delete from line 1 through the *second* `---`.

Correct approach: use awk to find the line number of the second `---` and print everything after it.

```bash
# Extracts the template body (after frontmatter) from a preset template file.
# Usage: read_preset_body "templates/k8s/deployment-web.yaml"
# Output: the template body (YAML content after second ---)
read_preset_body() {
    local template="$1"
    awk 'BEGIN{n=0} /^---$/{n++; next} n>=2' "$template"
}
```

- [ ] **Step 4: Add `get_preset_field` function**

Convenience wrapper to extract a single field from frontmatter using `yq`.

```bash
# Gets a field value from preset frontmatter.
# Usage: get_preset_field "templates/k8s/deployment-web.yaml" ".description"
get_preset_field() {
    local template="$1"
    local field="$2"
    read_preset_frontmatter "$template" | yq eval "$field" -
}
```

- [ ] **Step 5: Add `get_preset_defaults` function**

Outputs defaults as `KEY=value` lines, suitable for iterating in bash.

```bash
# Gets default values from preset frontmatter as KEY=value lines.
# Usage: get_preset_defaults "templates/k8s/deployment-web.yaml"
# Output: IMAGE=
#          PORT=3000
#          SECRET_NAME={{APP_NAME}}-secrets
get_preset_defaults() {
    local template="$1"
    read_preset_frontmatter "$template" | yq eval '.defaults // {} | to_entries | .[] | .key + "=" + .value' -
}
```

- [ ] **Step 6: Add `get_preset_config` function**

Outputs config entries as `KEY=value` lines for configMapGenerator.

```bash
# Gets config entries from preset frontmatter as KEY=value lines.
# Usage: get_preset_config "templates/k8s/statefulset-postgres.yaml"
# Output: POSTGRES_DB=app
get_preset_config() {
    local template="$1"
    read_preset_frontmatter "$template" | yq eval '.config // {} | to_entries | .[] | .key + "=" + .value' -
}
```

- [ ] **Step 7: Add `is_preset_optional` function**

Checks if a given default key is listed in the `optional` array.

```bash
# Checks if a default key is optional in the preset.
# Usage: is_preset_optional "templates/k8s/deployment-web.yaml" "SECRET_NAME"
# Returns: 0 if optional, 1 if required
is_preset_optional() {
    local template="$1"
    local key="$2"
    local optionals
    optionals="$(read_preset_frontmatter "$template" | yq eval '.optional // [] | .[]' -)"
    echo "$optionals" | grep -qx "$key"
}
```

- [ ] **Step 8: Add `render_preset_template` function**

Combines frontmatter stripping with the existing `render_template` logic. Writes the body to a temp file, then calls `render_template`.

```bash
# Renders a preset template (strips frontmatter, then renders body).
# Usage: render_preset_template "templates/k8s/deployment-web.yaml" "output.yaml" "KEY1=val1" "KEY2=val2"
render_preset_template() {
    local template="$1"
    local output="$2"
    shift 2

    # Extract body to a temp file
    local tmp_body
    tmp_body="$(mktemp)"
    read_preset_body "$template" > "$tmp_body"

    # Render using existing render_template
    render_template "$tmp_body" "$output" "$@"
    rm -f "$tmp_body"
}
```

- [ ] **Step 9: Add `safe_render_preset_template` function**

Same as `render_preset_template` but guards against overwriting existing files.

```bash
# Renders a preset template only if the output file does not exist.
# Returns 0 if written, 1 if skipped.
safe_render_preset_template() {
    local template="$1"
    local output="$2"
    shift 2

    if [[ -f "$output" ]]; then
        print_warning "Skipping existing file: ${output}"
        return 1
    fi

    render_preset_template "$template" "$output" "$@"
}
```

- [ ] **Step 10: Add `build_secret_env_vars` helper**

Builds the `{{SECRET_ENV_VARS}}` YAML block from an associative array of env-name=secret-key mappings.

```bash
# Builds the SECRET_ENV_VARS YAML block for deployment templates.
# Usage: build_secret_env_vars "secret-name" "ENV1=key1" "ENV2=key2"
# Output: properly indented YAML env block with secretKeyRef entries
build_secret_env_vars() {
    local secret_name="$1"
    shift
    local mappings=("$@")

    if [[ ${#mappings[@]} -eq 0 ]]; then
        echo ""
        return
    fi

    local result="          env:"
    local mapping
    for mapping in "${mappings[@]}"; do
        local env_name="${mapping%%=*}"
        local secret_key="${mapping#*=}"
        result+=$'\n'"            - name: ${env_name}"
        result+=$'\n'"              valueFrom:"
        result+=$'\n'"                secretKeyRef:"
        result+=$'\n'"                  name: ${secret_name}"
        result+=$'\n'"                  key: ${secret_key}"
    done
    echo "$result"
}
```

- [ ] **Step 11: Add `build_http_probes` helper**

Builds the `{{PROBES}}` YAML block for HTTP GET probes.

```bash
# Builds the PROBES YAML block for deployment templates.
# Usage: build_http_probes "/api/health" "3000"
# Output: properly indented YAML livenessProbe and readinessProbe blocks
build_http_probes() {
    local path="$1"
    local port="$2"

    if [[ -z "$path" ]]; then
        echo ""
        return
    fi

    cat <<PROBES
          livenessProbe:
            httpGet:
              path: ${path}
              port: ${port}
            initialDelaySeconds: 15
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: ${path}
              port: ${port}
            initialDelaySeconds: 5
            periodSeconds: 5
PROBES
}
```

- [ ] **Step 12: Add `strip_blank_placeholder_lines` helper**

Post-render cleanup that removes lines that are entirely blank (from empty placeholder substitution).

```bash
# Strips consecutive blank lines from a file, leaving at most one.
# Used after rendering to clean up empty placeholder substitutions.
strip_blank_placeholder_lines() {
    local file="$1"
    local tmp
    tmp="$(mktemp)"
    awk 'NF || !blank++ { print } NF { blank=0 }' "$file" > "$tmp"
    # Also strip trailing blank lines
    sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$tmp" > "$file"
    rm -f "$tmp"
}
```

- [ ] **Step 13: Add `detect_service_port` helper**

Parses the port from an app's existing `service.yaml`.

```bash
# Detects the port from an app's service.yaml file.
# Usage: detect_service_port "myapp"
# Output: the port number (e.g., "3000")
detect_service_port() {
    local app_name="$1"
    local service_file="${TARGET_DIR}/k8s/apps/${app_name}/base/service.yaml"
    if [[ ! -f "$service_file" ]]; then
        echo ""
        return
    fi
    yq eval '.spec.ports[0].port' "$service_file"
}
```

- [ ] **Step 14: Validate and commit**

Run: `make validate`
Expected: PASS -- shellcheck and shfmt should accept all new functions

```bash
git add lib/common.sh
git commit -m "Add preset frontmatter helpers to common.sh

- discover_presets: scan template filenames to find available presets
- read_preset_frontmatter/body: parse frontmatter-delimited templates
- get_preset_field/defaults/config: extract frontmatter values with yq
- is_preset_optional: check if a default key is optional
- render_preset_template/safe_render_preset_template: strip frontmatter and render
- build_secret_env_vars/build_http_probes: construct YAML blocks for templates
- strip_blank_placeholder_lines: post-render cleanup
- detect_service_port: parse port from existing service.yaml"
```

---

### Task 3: Extend `cmd_add_app` with preset system

This is the core change. The existing `cmd_add_app` function is extended to:
1. Auto-discover presets after workload type selection
2. Walk through frontmatter defaults
3. Collect config values for configMapGenerator
4. Build SECRET_ENV_VARS and PROBES blocks
5. Render the workload template alongside existing scaffold

**Files:**
- Modify: `infra-ctl.sh` (rewrite `cmd_add_app`, lines ~120-310)

- [ ] **Step 1: Replace port prompt and add preset selection**

In `cmd_add_app`, after the workload type selection (line ~161), replace the port prompt with preset discovery and selection:

```bash
    # Discover presets for the selected workload type
    local workload_prefix
    if [[ "$workload_type" == "StatefulSet" ]]; then
        workload_prefix="statefulset"
    else
        workload_prefix="deployment"
    fi

    local presets=()
    while IFS= read -r preset; do
        presets+=("$preset")
    done < <(discover_presets "$workload_prefix")

    local preset_choice="custom"
    if [[ ${#presets[@]} -gt 0 ]]; then
        # Build chooser with descriptions
        local preset_labels=()
        local preset
        for preset in "${presets[@]}"; do
            local template_file="${TEMPLATE_DIR}/k8s/${workload_prefix}-${preset}.yaml"
            local desc
            desc="$(get_preset_field "$template_file" '.description')"
            preset_labels+=("${preset} -- ${desc}")
        done
        # Only add custom option for Deployments (custom StatefulSet is not yet supported)
        if [[ "$workload_prefix" == "deployment" ]]; then
            preset_labels+=("custom -- Configure manually")
        fi

        print_header "Select preset for '${app_name}'"
        local chosen_label
        chosen_label="$(printf "%s\n" "${preset_labels[@]}" | gum choose)"
        preset_choice="${chosen_label%% -- *}"
    elif [[ "$workload_prefix" == "statefulset" ]]; then
        print_error "No StatefulSet presets found in templates/k8s/. Add a statefulset-*.yaml template."
        exit 1
    fi
```

- [ ] **Step 2: Add preset walkthrough logic**

After preset selection, walk through defaults and config values. Add this block:

```bash
    local preset_template=""
    local port=""
    local image=""
    local secret_name=""
    local probe_path=""
    local secret_mappings=()
    local config_entries=()
    local storage_size=""
    local mount_path=""

    if [[ "$preset_choice" != "custom" ]]; then
        preset_template="${TEMPLATE_DIR}/k8s/${workload_prefix}-${preset_choice}.yaml"

        # Walk through defaults
        print_header "Configure ${preset_choice} preset"
        local line
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local key="${line%%=*}"
            local default_val="${line#*=}"
            # Resolve {{APP_NAME}} in defaults
            default_val="${default_val//\{\{APP_NAME\}\}/${app_name}}"

            # Check if this key is optional
            if is_preset_optional "$preset_template" "$key"; then
                local accept
                case "$key" in
                    SECRET_NAME)
                        accept="$(gum confirm "Add secret references?" && echo "yes" || echo "no")"
                        ;;
                    PROBE_PATH)
                        accept="$(gum confirm "Add health probes?" && echo "yes" || echo "no")"
                        ;;
                    *)
                        accept="$(gum confirm "Configure ${key}?" && echo "yes" || echo "no")"
                        ;;
                esac
                if [[ "$accept" == "no" ]]; then
                    continue
                fi
            fi

            local value
            value="$(gum input --value "$default_val" --prompt "${key}: ")"

            # Store values by key name
            case "$key" in
                PORT) port="$value" ;;
                IMAGE) image="$value" ;;
                SECRET_NAME) secret_name="$value" ;;
                PROBE_PATH) probe_path="$value" ;;
                STORAGE_SIZE) storage_size="$value" ;;
                MOUNT_PATH) mount_path="$value" ;;
            esac
        done < <(get_preset_defaults "$preset_template")

        # Validate required fields
        if [[ -z "$image" ]]; then
            print_error "Container image is required."
            exit 1
        fi
        if [[ -z "$port" ]]; then
            print_error "Container port is required."
            exit 1
        fi
        validate_port "$port"

        # Walk through preset config entries
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local key="${line%%=*}"
            local default_val="${line#*=}"
            local value
            value="$(gum input --value "$default_val" --prompt "${key}: ")"
            config_entries+=("${key}=${value}")
        done < <(get_preset_config "$preset_template")

        # Prompt for secret env var mappings if secret_name was accepted
        if [[ -n "$secret_name" && "$workload_prefix" == "deployment" ]]; then
            print_info "Map environment variables to secret keys from '${secret_name}'."
            print_info "Format: ENV_NAME=secret-key (empty to finish)"
            while true; do
                local mapping
                mapping="$(gum input --prompt "ENV_NAME=secret-key: ")"
                [[ -z "$mapping" ]] && break
                secret_mappings+=("$mapping")
            done
        fi

    else
        # Custom flow (Deployment only -- StatefulSet requires a preset)
        image="$(gum input --prompt "Container image: ")"
        if [[ -z "$image" ]]; then
            print_error "Container image is required."
            exit 1
        fi

        port="$(gum input --value "8080" --prompt "Container port: ")"
        validate_port "$port"

        if gum confirm "Add secret references?"; then
            secret_name="$(gum input --value "${app_name}-secrets" --prompt "Secret name: ")"
            print_info "Map environment variables to secret keys from '${secret_name}'."
            print_info "Format: ENV_NAME=secret-key (empty to finish)"
            while true; do
                local mapping
                mapping="$(gum input --prompt "ENV_NAME=secret-key: ")"
                [[ -z "$mapping" ]] && break
                secret_mappings+=("$mapping")
            done
        fi

        if gum confirm "Add health probes?"; then
            probe_path="$(gum input --value "/api/health" --prompt "Health check path: ")"
        fi
    fi

    # Prompt for additional config values (both preset and custom)
    if gum confirm "Add config values?"; then
        print_info "Format: KEY=VALUE (empty to finish)"
        while true; do
            local entry
            entry="$(gum input --prompt "KEY=VALUE: ")"
            [[ -z "$entry" ]] && break
            config_entries+=("$entry")
        done
    fi
```

- [ ] **Step 3: Update preview section**

Replace the existing preview section to include the new workload manifest and config info:

```bash
    # Preview what will be created
    print_header "Add Application: ${app_name}"
    print_info "Project: ${project}"
    print_info "Workload: ${workload_type}"
    if [[ "$preset_choice" != "custom" ]]; then
        print_info "Preset: ${preset_choice}"
    fi
    print_info "Image: ${image}"
    print_info "Port: ${port}"
    if [[ -n "$secret_name" ]]; then
        print_info "Secret: ${secret_name}"
    fi
    if [[ -n "$probe_path" ]]; then
        print_info "Probes: ${probe_path}"
    fi
    if [[ ${#config_entries[@]} -gt 0 ]]; then
        print_info "Config: ${config_entries[*]}"
    fi
    local workload_file
    if [[ "$workload_type" == "StatefulSet" ]]; then
        workload_file="statefulset.yaml"
    else
        workload_file="deployment.yaml"
    fi
    print_info "Base: k8s/apps/${app_name}/base/${workload_file}"
    print_info "Base: k8s/apps/${app_name}/base/kustomization.yaml"
    print_info "Base: k8s/apps/${app_name}/base/service.yaml"
    if [[ ${#envs[@]} -gt 0 ]]; then
        local env
        for env in "${envs[@]}"; do
            print_info "Overlay: k8s/apps/${app_name}/overlays/${env}/kustomization.yaml"
            print_info "ArgoCD:  argocd/apps/${app_name}-${env}.yaml"
        done
    else
        print_warning "No environments found. Only base/ will be created."
        print_info "Run 'infra-ctl.sh add-env <env>' to create overlays later."
    fi
    # Kargo preview (existing code, unchanged)
```

- [ ] **Step 4: Add workload manifest rendering**

After the existing kustomization and service rendering, add the workload manifest generation:

```bash
    # Create workload manifest (deployment or statefulset)
    local workload_output="${app_dir}/base/${workload_file}"

    if [[ "$preset_choice" != "custom" ]]; then
        # Build dynamic blocks for deployment presets
        local secret_env_vars_block=""
        local probes_block=""

        if [[ "$workload_prefix" == "deployment" ]]; then
            if [[ ${#secret_mappings[@]} -gt 0 ]]; then
                secret_env_vars_block="$(build_secret_env_vars "$secret_name" "${secret_mappings[@]}")"
            fi
            if [[ -n "$probe_path" ]]; then
                probes_block="$(build_http_probes "$probe_path" "$port")"
            fi
        fi

        if safe_render_preset_template "$preset_template" "$workload_output" \
            "APP_NAME=${app_name}" \
            "IMAGE=${image}" \
            "PORT=${port}" \
            "SECRET_NAME=${secret_name}" \
            "STORAGE_SIZE=${storage_size}" \
            "MOUNT_PATH=${mount_path}" \
            "SECRET_ENV_VARS=${secret_env_vars_block}" \
            "PROBES=${probes_block}"; then
            strip_blank_placeholder_lines "$workload_output"
            created_files+=("$workload_output")
        fi
    else
        # Custom deployment: reuse the web template body as the base structure
        local custom_template="${TEMPLATE_DIR}/k8s/deployment-web.yaml"
        local secret_env_vars_block=""
        local probes_block=""

        if [[ ${#secret_mappings[@]} -gt 0 ]]; then
            secret_env_vars_block="$(build_secret_env_vars "$secret_name" "${secret_mappings[@]}")"
        fi
        if [[ -n "$probe_path" ]]; then
            probes_block="$(build_http_probes "$probe_path" "$port")"
        fi

        if safe_render_preset_template "$custom_template" "$workload_output" \
            "APP_NAME=${app_name}" \
            "IMAGE=${image}" \
            "PORT=${port}" \
            "SECRET_ENV_VARS=${secret_env_vars_block}" \
            "PROBES=${probes_block}"; then
            strip_blank_placeholder_lines "$workload_output"
            created_files+=("$workload_output")
        fi
    fi
```

- [ ] **Step 5: Add config entries to base configMapGenerator**

After rendering the kustomization, update the base configMapGenerator with collected config entries:

```bash
    # Add config entries to base configMapGenerator
    if [[ ${#config_entries[@]} -gt 0 ]]; then
        local base_kustomization="${app_dir}/base/kustomization.yaml"
        local entry
        for entry in "${config_entries[@]}"; do
            yq eval -i \
                ".configMapGenerator[0].literals += [\"${entry}\"]" \
                "$base_kustomization"
        done
        # Remove the empty [] if we just added to it
        yq eval -i \
            '.configMapGenerator[0].literals |= map(select(. != null and . != ""))' \
            "$base_kustomization"
    fi
```

- [ ] **Step 6: Update Kargo image repo default**

In the existing Kargo section, derive the image repo default from the image entered earlier:

```bash
        # Derive default image repo from the image (strip tag)
        local default_image_repo="${image%%:*}"
        image_repo="$(gum input --value "${default_image_repo}" --header "Container image repository for Kargo (no tag):")"
```

Replace the existing `gum input --value "ghcr.io/${REPO_OWNER}/${app_name}"` line.

- [ ] **Step 7: Validate and commit**

Run: `make validate`
Expected: PASS

```bash
git add infra-ctl.sh
git commit -m "Extend add-app with preset-driven workload generation

- Auto-discover presets from template filenames
- Walk through frontmatter defaults with gum input
- Build SECRET_ENV_VARS and PROBES blocks for deployment templates
- Add config entries to base configMapGenerator
- Support custom flow for freeform configuration
- Derive Kargo image repo from entered image"
```

---

### Task 4: Add ingress commands to `infra-ctl.sh`

**Files:**
- Modify: `infra-ctl.sh` (add `cmd_add_ingress`, `cmd_list_ingress`, `cmd_remove_ingress` functions, update usage and dispatcher)

- [ ] **Step 1: Add `cmd_add_ingress` function**

Add after `cmd_add_app` in `infra-ctl.sh`:

```bash
cmd_add_ingress() {
    require_gum
    require_yq
    load_conf

    local app_name="${1:-}"
    if [[ -z "$app_name" ]]; then
        app_name="$(detect_apps | choose_from "Select application:" "No applications found. Run 'add-app' first.")" || exit 0
    fi
    validate_k8s_name "$app_name" "App name"

    # Guard: app must exist
    local app_dir="${TARGET_DIR}/k8s/apps/${app_name}"
    if [[ ! -d "$app_dir" ]]; then
        print_error "Application '${app_name}' not found at ${app_dir}"
        exit 1
    fi

    # Guard: ingress must not already exist
    local ingress_file="${app_dir}/base/ingress.yaml"
    if [[ -f "$ingress_file" ]]; then
        print_error "Ingress already exists at ${ingress_file}"
        exit 1
    fi

    # Auto-detect port from service.yaml
    local port
    port="$(detect_service_port "$app_name")"
    if [[ -z "$port" ]]; then
        print_error "Could not detect port from ${app_dir}/base/service.yaml"
        exit 1
    fi

    # Prompts
    local host
    host="$(gum input --placeholder "app.localhost" --prompt "Hostname: ")"
    if [[ -z "$host" ]]; then
        print_error "Hostname is required."
        exit 1
    fi

    local path
    path="$(gum input --value "/" --prompt "Path: ")"

    # Preview
    print_header "Add Ingress: ${app_name}"
    print_info "Hostname: ${host}"
    print_info "Path: ${path}"
    print_info "Service: ${app_name}:${port}"
    print_info "File: k8s/apps/${app_name}/base/ingress.yaml"

    confirm_or_abort "Create ingress?"

    local created_files=()

    # Render ingress template
    if safe_render_template "${TEMPLATE_DIR}/k8s/ingress.yaml" "$ingress_file" \
        "APP_NAME=${app_name}" \
        "HOST=${host}" \
        "PATH=${path}" \
        "PORT=${port}"; then
        created_files+=("$ingress_file")
    fi

    # Add ingress.yaml to base kustomization resources
    local base_kustomization="${app_dir}/base/kustomization.yaml"
    yq eval -i '.resources += ["ingress.yaml"]' "$base_kustomization"

    print_summary "${created_files[@]}"
}
```

- [ ] **Step 2: Add `cmd_list_ingress` function**

```bash
cmd_list_ingress() {
    load_conf

    local found=0
    local app_dir
    for app_dir in "${TARGET_DIR}/k8s/apps"/*/; do
        [[ -d "$app_dir" ]] || continue
        local ingress_file="${app_dir}base/ingress.yaml"
        [[ -f "$ingress_file" ]] || continue

        local app_name
        app_name="$(basename "$app_dir")"
        local host
        host="$(yq eval '.spec.rules[0].host' "$ingress_file")"
        local path
        path="$(yq eval '.spec.rules[0].http.paths[0].path' "$ingress_file")"

        print_info "${app_name}  (host: ${host}, path: ${path})"
        found=1
    done

    if [[ "$found" -eq 0 ]]; then
        print_warning "No ingress resources found."
        print_info "Run 'infra-ctl.sh add-ingress <app>' to create one."
    fi
}
```

- [ ] **Step 3: Add `cmd_remove_ingress` function**

```bash
cmd_remove_ingress() {
    require_gum
    require_yq
    load_conf

    local app_name="${1:-}"
    if [[ -z "$app_name" ]]; then
        # Build list of apps that have ingress
        local apps_with_ingress=()
        local app_dir
        for app_dir in "${TARGET_DIR}/k8s/apps"/*/; do
            [[ -d "$app_dir" ]] || continue
            [[ -f "${app_dir}base/ingress.yaml" ]] || continue
            apps_with_ingress+=("$(basename "$app_dir")")
        done
        if [[ ${#apps_with_ingress[@]} -eq 0 ]]; then
            print_warning "No ingress resources found."
            return
        fi
        app_name="$(printf "%s\n" "${apps_with_ingress[@]}" | gum choose --header "Select application:")"
    fi
    validate_k8s_name "$app_name" "App name"

    local app_dir="${TARGET_DIR}/k8s/apps/${app_name}"
    local ingress_file="${app_dir}/base/ingress.yaml"
    if [[ ! -f "$ingress_file" ]]; then
        print_error "No ingress found for '${app_name}'"
        exit 1
    fi

    # Preview
    local host
    host="$(yq eval '.spec.rules[0].host' "$ingress_file")"
    print_header "Remove Ingress: ${app_name}"
    print_info "Host: ${host}"
    print_info "File: ${ingress_file}"

    confirm_destructive_or_abort "Remove ingress for '${app_name}'?"

    # Remove file
    rm -f "$ingress_file"

    # Remove from kustomization resources
    local base_kustomization="${app_dir}/base/kustomization.yaml"
    yq eval -i '.resources -= ["ingress.yaml"]' "$base_kustomization"

    print_removed "$ingress_file"
}
```

- [ ] **Step 4: Add ingress commands to usage() and dispatcher**

In the `usage()` function, add after the existing app commands:

```bash
    echo "  add-ingress [app]       Add an Ingress resource to an application"
    echo "  list-ingress            List all Ingress resources"
    echo "  remove-ingress [app]    Remove an Ingress resource from an application"
```

In the `main()` case statement, add:

```bash
        add-ingress) shift; cmd_add_ingress "$@" ;;
        list-ingress) cmd_list_ingress ;;
        remove-ingress) shift; cmd_remove_ingress "$@" ;;
```

- [ ] **Step 5: Validate and commit**

Run: `make validate`
Expected: PASS

```bash
git add infra-ctl.sh
git commit -m "Add ingress commands to infra-ctl.sh

- add-ingress: render ingress template, auto-detect port from service.yaml
- list-ingress: scan for ingress.yaml files, show host and path
- remove-ingress: delete ingress file and remove from kustomization resources"
```

---

### Task 5: Create `config-ctl.sh`

**Files:**
- Create: `config-ctl.sh`

- [ ] **Step 1: Create the script skeleton with usage and dispatcher**

Create `config-ctl.sh` following the exact patterns from other scripts:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# --- Commands ---

cmd_add() {
    require_gum
    require_yq
    load_conf

    local app_name="${1:-}"
    local env_name="${2:-}"

    if [[ -z "$app_name" ]]; then
        app_name="$(detect_apps | choose_from "Select application:" "No applications found. Run 'infra-ctl.sh add-app' first.")" || exit 0
    fi
    validate_k8s_name "$app_name" "App name"

    # Choose target: base or specific env
    if [[ -z "$env_name" ]]; then
        local choices=("base")
        while IFS= read -r env; do
            choices+=("$env")
        done < <(detect_envs)
        env_name="$(printf "%s\n" "${choices[@]}" | gum choose --header "Select target (base or environment):")"
    fi

    # Resolve kustomization file path
    local kustomization_file
    if [[ "$env_name" == "base" ]]; then
        kustomization_file="${TARGET_DIR}/k8s/apps/${app_name}/base/kustomization.yaml"
    else
        kustomization_file="${TARGET_DIR}/k8s/apps/${app_name}/overlays/${env_name}/kustomization.yaml"
    fi

    if [[ ! -f "$kustomization_file" ]]; then
        print_error "Kustomization file not found: ${kustomization_file}"
        exit 1
    fi

    # Collect key=value entries
    print_header "Add config values to ${app_name} (${env_name})"
    print_info "Format: KEY=VALUE (empty to finish)"
    local entries=()
    while true; do
        local entry
        entry="$(gum input --prompt "KEY=VALUE: ")"
        [[ -z "$entry" ]] && break
        entries+=("$entry")
    done

    if [[ ${#entries[@]} -eq 0 ]]; then
        print_warning "No config values entered."
        return
    fi

    # Append to configMapGenerator literals
    local entry
    for entry in "${entries[@]}"; do
        yq eval -i \
            ".configMapGenerator[0].literals += [\"${entry}\"]" \
            "$kustomization_file"
    done
    # Clean up empty/null entries left from initial [] placeholder
    yq eval -i \
        '.configMapGenerator[0].literals |= map(select(. != null and . != ""))' \
        "$kustomization_file"

    print_success "Added ${#entries[@]} config value(s) to ${app_name} (${env_name})"
}

cmd_list() {
    require_yq
    load_conf

    local app_name="${1:-}"
    local env_name="${2:-}"

    if [[ -z "$app_name" ]]; then
        app_name="$(detect_apps | choose_from "Select application:" "No applications found.")" || exit 0
    fi
    validate_k8s_name "$app_name" "App name"

    if [[ -z "$env_name" ]]; then
        local choices=("base")
        while IFS= read -r env; do
            choices+=("$env")
        done < <(detect_envs)
        env_name="$(printf "%s\n" "${choices[@]}" | gum choose --header "Select target (base or environment):")"
    fi

    local base_file="${TARGET_DIR}/k8s/apps/${app_name}/base/kustomization.yaml"

    if [[ "$env_name" == "base" ]]; then
        if [[ ! -f "$base_file" ]]; then
            print_error "Base kustomization not found: ${base_file}"
            exit 1
        fi
        print_header "Config values for ${app_name} (base)"
        local literals
        literals="$(yq eval '.configMapGenerator[0].literals[]' "$base_file" 2>/dev/null)" || true
        if [[ -z "$literals" ]]; then
            print_warning "No config values set."
        else
            echo "$literals" | while IFS= read -r line; do
                print_info "  ${line}"
            done
        fi
    else
        local overlay_file="${TARGET_DIR}/k8s/apps/${app_name}/overlays/${env_name}/kustomization.yaml"
        if [[ ! -f "$overlay_file" ]]; then
            print_error "Overlay kustomization not found: ${overlay_file}"
            exit 1
        fi

        # Show merged view: base values, then overlay overrides
        print_header "Config values for ${app_name} (${env_name})"

        # Collect base keys
        local -A base_values=()
        local line
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local key="${line%%=*}"
            base_values["$key"]="$line"
        done < <(yq eval '.configMapGenerator[0].literals[]' "$base_file" 2>/dev/null || true)

        # Collect overlay keys
        local -A overlay_values=()
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local key="${line%%=*}"
            overlay_values["$key"]="$line"
        done < <(yq eval '.configMapGenerator[0].literals[]' "$overlay_file" 2>/dev/null || true)

        # Print merged: overlay overrides base
        local key
        for key in "${!base_values[@]}"; do
            if [[ -v "overlay_values[$key]" ]]; then
                print_info "  ${overlay_values[$key]}  (override)"
            else
                print_info "  ${base_values[$key]}  (base)"
            fi
        done
        # Print overlay-only keys
        for key in "${!overlay_values[@]}"; do
            if [[ ! -v "base_values[$key]" ]]; then
                print_info "  ${overlay_values[$key]}  (${env_name} only)"
            fi
        done

        if [[ ${#base_values[@]} -eq 0 && ${#overlay_values[@]} -eq 0 ]]; then
            print_warning "No config values set."
        fi
    fi
}

cmd_remove() {
    require_gum
    require_yq
    load_conf

    local app_name="${1:-}"
    local env_name="${2:-}"

    if [[ -z "$app_name" ]]; then
        app_name="$(detect_apps | choose_from "Select application:" "No applications found.")" || exit 0
    fi
    validate_k8s_name "$app_name" "App name"

    if [[ -z "$env_name" ]]; then
        local choices=("base")
        while IFS= read -r env; do
            choices+=("$env")
        done < <(detect_envs)
        env_name="$(printf "%s\n" "${choices[@]}" | gum choose --header "Select target (base or environment):")"
    fi

    local kustomization_file
    if [[ "$env_name" == "base" ]]; then
        kustomization_file="${TARGET_DIR}/k8s/apps/${app_name}/base/kustomization.yaml"
    else
        kustomization_file="${TARGET_DIR}/k8s/apps/${app_name}/overlays/${env_name}/kustomization.yaml"
    fi

    if [[ ! -f "$kustomization_file" ]]; then
        print_error "Kustomization file not found: ${kustomization_file}"
        exit 1
    fi

    # Get current literals
    local literals=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        literals+=("$line")
    done < <(yq eval '.configMapGenerator[0].literals[]' "$kustomization_file" 2>/dev/null || true)

    if [[ ${#literals[@]} -eq 0 ]]; then
        print_warning "No config values to remove."
        return
    fi

    # Let user select which to remove
    print_header "Remove config values from ${app_name} (${env_name})"
    local to_remove
    to_remove="$(printf "%s\n" "${literals[@]}" | gum choose --no-limit --header "Select values to remove:")"

    if [[ -z "$to_remove" ]]; then
        print_warning "No values selected."
        return
    fi

    # Remove selected entries
    while IFS= read -r entry; do
        yq eval -i \
            ".configMapGenerator[0].literals -= [\"${entry}\"]" \
            "$kustomization_file"
    done <<< "$to_remove"

    local count
    count="$(echo "$to_remove" | wc -l | tr -d ' ')"
    print_success "Removed ${count} config value(s) from ${app_name} (${env_name})"
}

cmd_verify() {
    require_yq
    load_conf

    local env_name="${1:-}"
    if [[ -z "$env_name" ]]; then
        env_name="$(detect_envs | choose_from "Select environment:" "No environments found.")" || exit 0
    fi

    print_header "Verifying config for environment: ${env_name}"

    local missing_count=0
    local app_dir
    for app_dir in "${TARGET_DIR}/k8s/apps"/*/; do
        [[ -d "$app_dir" ]] || continue
        local app_name
        app_name="$(basename "$app_dir")"

        # Check for configMapRef in workload manifests
        local workload_file=""
        if [[ -f "${app_dir}base/deployment.yaml" ]]; then
            workload_file="${app_dir}base/deployment.yaml"
        elif [[ -f "${app_dir}base/statefulset.yaml" ]]; then
            workload_file="${app_dir}base/statefulset.yaml"
        fi
        [[ -z "$workload_file" ]] && continue

        # Check if workload references a configMapRef
        if ! grep -q "configMapRef" "$workload_file" 2>/dev/null; then
            continue
        fi

        # Check that configMapGenerator exists in overlay
        local overlay_file="${TARGET_DIR}/k8s/apps/${app_name}/overlays/${env_name}/kustomization.yaml"
        if [[ ! -f "$overlay_file" ]]; then
            print_warning "${app_name}: overlay for '${env_name}' not found"
            ((missing_count++))
            continue
        fi

        # Check base has configMapGenerator with at least one literal
        local base_file="${app_dir}base/kustomization.yaml"
        local base_literals
        base_literals="$(yq eval '.configMapGenerator[0].literals | length' "$base_file" 2>/dev/null)" || base_literals="0"

        local overlay_literals
        overlay_literals="$(yq eval '.configMapGenerator[0].literals | length' "$overlay_file" 2>/dev/null)" || overlay_literals="0"

        if [[ "$base_literals" == "0" && "$overlay_literals" == "0" ]]; then
            print_warning "${app_name}: configMapRef found in workload but no literals in configMapGenerator"
            ((missing_count++))
        else
            print_success "${app_name}: configMapGenerator configured (base: ${base_literals}, ${env_name}: ${overlay_literals})"
        fi
    done

    if [[ "$missing_count" -eq 0 ]]; then
        print_success "All config references verified for '${env_name}'."
    else
        print_warning "${missing_count} issue(s) found. Run 'config-ctl.sh add' to fix."
        if gum confirm "Walk through adding missing config values now?"; then
            cmd_add
        fi
    fi
}

# --- Main ---

usage() {
    echo "Usage: config-ctl.sh <command> [options]"
    echo ""
    echo "Manage configMapGenerator literals in Kustomize configurations."
    echo ""
    echo "Commands:"
    echo "  add [app] [env]         Add config values (KEY=VALUE) to an application"
    echo "  list [app] [env]        List config values for an application"
    echo "  remove [app] [env]      Remove config values from an application"
    echo "  verify [env]            Check for missing config references"
    echo ""
    echo "Arguments:"
    echo "  app                     Application name (interactive chooser if omitted)"
    echo "  env                     Target: 'base' or environment name (chooser if omitted)"
    echo ""
    echo "$(print_global_options)"
}

main() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi

    parse_global_args "$@"
    set -- ${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}

    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi

    local command="$1"

    case "$command" in
        add) shift; cmd_add "$@" ;;
        list) shift; cmd_list "$@" ;;
        remove) shift; cmd_remove "$@" ;;
        verify) shift; cmd_verify "$@" ;;
        -h | --help) usage ;;
        *)
            print_error "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

main "$@"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x config-ctl.sh
```

- [ ] **Step 3: Validate and commit**

Run: `make validate`
Expected: PASS

```bash
git add config-ctl.sh
git commit -m "Add config-ctl.sh for managing configMapGenerator literals

- add: append KEY=VALUE entries to base or overlay kustomization
- list: show config values with merged view for overlays
- remove: interactive selection of values to remove
- verify: scan workloads for configMapRef, check configMapGenerator exists"
```

---

### Task 6: Add `verify` command to `secret-ctl.sh`

**Files:**
- Modify: `secret-ctl.sh` (add `cmd_verify` function, update usage and dispatcher)

- [ ] **Step 1: Add `cmd_verify` function**

Add after `cmd_remove` in `secret-ctl.sh`:

```bash
cmd_verify() {
    require_yq
    load_conf

    local env_name="${1:-}"
    if [[ -z "$env_name" ]]; then
        env_name="$(detect_envs | choose_from "Select environment:" "No environments found.")" || exit 0
    fi

    print_header "Verifying secrets for environment: ${env_name}"

    local missing_count=0
    local app_dir
    for app_dir in "${TARGET_DIR}/k8s/apps"/*/; do
        [[ -d "$app_dir" ]] || continue
        local app_name
        app_name="$(basename "$app_dir")"

        # Find all secretKeyRef entries in workload manifests
        local secrets_found=0
        local workload_file
        for workload_file in "${app_dir}base/deployment.yaml" "${app_dir}base/statefulset.yaml"; do
            [[ -f "$workload_file" ]] || continue

            # Extract secret name + key pairs using yq
            local refs
            refs="$(yq eval '
                .. | select(has("secretKeyRef")) | .secretKeyRef |
                .name + "=" + .key
            ' "$workload_file" 2>/dev/null)" || continue

            [[ -z "$refs" ]] && continue
            secrets_found=1

            # Check each reference
            while IFS= read -r ref; do
                local secret_name="${ref%%=*}"
                local secret_key="${ref#*=}"

                # Check for sealed secret file in overlay
                local sealed_file="${TARGET_DIR}/k8s/apps/${app_name}/overlays/${env_name}/sealed-secret.yaml"
                if [[ ! -f "$sealed_file" ]]; then
                    print_warning "${app_name}: secret '${secret_name}' not found (no sealed-secret.yaml in ${env_name})"
                    ((missing_count++))
                    continue
                fi

                # Check if the specific key exists in encryptedData
                local has_key
                has_key="$(yq eval ".spec.encryptedData | has(\"${secret_key}\")" "$sealed_file" 2>/dev/null)" || has_key="false"
                if [[ "$has_key" != "true" ]]; then
                    print_warning "${app_name}: key '${secret_key}' missing from secret '${secret_name}' in ${env_name}"
                    ((missing_count++))
                else
                    print_success "${app_name}: secret '${secret_name}' key '${secret_key}' found in ${env_name}"
                fi
            done <<< "$refs"
        done
    done

    if [[ "$missing_count" -eq 0 ]]; then
        print_success "All secret references verified for '${env_name}'."
    else
        print_warning "${missing_count} missing secret(s) found."
        if gum confirm "Walk through creating missing secrets now?"; then
            cmd_add "" "$env_name"
        fi
    fi
}
```

- [ ] **Step 2: Update usage() and dispatcher**

In `usage()`, add:

```bash
    echo "  verify [env]            Check for missing secret references"
```

In the `main()` case statement, add:

```bash
        verify) shift; cmd_verify "$@" ;;
```

- [ ] **Step 3: Validate and commit**

Run: `make validate`
Expected: PASS

```bash
git add secret-ctl.sh
git commit -m "Add verify command to secret-ctl.sh

- Scans workload manifests for secretKeyRef entries
- Checks sealed-secret.yaml exists in each overlay
- Verifies individual keys exist in encryptedData
- Offers to walk through creating missing secrets"
```

---

### Task 7: Update `completions.zsh`

**Files:**
- Modify: `completions.zsh`

- [ ] **Step 1: Add ingress commands to `_infra_ctl` completions**

In the `_infra_ctl` function's `commands` array, add:

```bash
        'add-ingress:Add an Ingress resource to an application'
        'list-ingress:List all Ingress resources'
        'remove-ingress:Remove an Ingress resource from an application'
```

In the `case "$state"` / `case "${words[1]}"` block, add:

```bash
                add-ingress|remove-ingress) _infra_complete_apps ;;
```

- [ ] **Step 2: Add `verify` to `_secret_ctl` completions**

In the `_secret_ctl` function's `commands` array, add:

```bash
        'verify:Check for missing secret references'
```

In the completion dispatch, add `verify` to the cases that complete with envs:

```bash
                verify)
                    case "$CURRENT" in
                        2) _infra_complete_envs ;;
                    esac ;;
```

- [ ] **Step 3: Add `_config_ctl` completion function**

Add a new completion function and `compdef` registration:

```bash
_config_ctl() {
    local -a commands=(
        'add:Add config values to an application'
        'list:List config values for an application'
        'remove:Remove config values from an application'
        'verify:Check for missing config references'
    )

    _arguments -s \
        '--target-dir[Operate on a specific directory]:directory:_directories' \
        '--show-me[Print commands instead of running them]' \
        '--explain[Print commands with explanations]' \
        '--debug[Show full command output]' \
        '1:command:(( ${commands} ))' \
        '*:: :->args'

    case "$state" in
        args)
            case "${words[1]}" in
                add|list|remove)
                    case "$CURRENT" in
                        2) _infra_complete_apps ;;
                        3) _infra_complete_envs ;;
                    esac ;;
                verify)
                    case "$CURRENT" in
                        2) _infra_complete_envs ;;
                    esac ;;
            esac ;;
    esac
}

compdef _config_ctl config-ctl.sh
```

- [ ] **Step 4: Validate and commit**

Run: `make validate` (completions.zsh isn't linted by shellcheck, but check for syntax errors)

```bash
git add completions.zsh
git commit -m "Add completions for ingress commands, config-ctl, and secret verify

- infra-ctl: add-ingress, list-ingress, remove-ingress with app completion
- secret-ctl: verify with env completion
- config-ctl: full completion function with app and env for all commands"
```

---

### Task 8: Update README walkthrough

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the example walkthrough**

The current step 4 ("Write the actual Kubernetes manifests") needs to be replaced. The new flow integrates workload generation into `add-app`.

Key changes to the README walkthrough (section "Example: Deploying an Application"):

1. Update step 3 (`add-app` commands) to show the new preset prompts and what values the user enters
2. Remove step 4 ("Write the actual Kubernetes manifests") -- this is now handled by `add-app`
3. Add `add-ingress frontend` as a new step
4. Replace step 5 (manual `secret-ctl.sh add` commands) with `secret-ctl.sh verify dev` flow
5. Update the structure diagram to show `deployment.yaml` / `statefulset.yaml` / `ingress.yaml` as generated files
6. Add `config-ctl.sh` to the "Structure Overview" section

The README is long and the exact edits depend on the current structure. Read the full README, identify the sections that need updating, and make targeted edits. Preserve all existing documentation that is not directly affected by this change.

Key sections to update:
- Structure Overview diagram: change `deployment.yaml or statefulset.yaml  # You write these` to `deployment.yaml or statefulset.yaml  # Generated by add-app`
- "Example: Deploying an Application" steps 3-5
- Add `config-ctl.sh` section after `secret-ctl.sh` documentation

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "Update README walkthrough for workload generation

- add-app now generates deployment/statefulset manifests via presets
- Add add-ingress step to walkthrough
- Replace manual manifest writing with preset prompt descriptions
- Add config-ctl.sh documentation section
- Add secret-ctl.sh verify to the walkthrough"
```

---

### Task 9: Update agent context

**Files:**
- Modify: `.claude/agents.md`

- [ ] **Step 1: Update agent context**

Add to the agent context file:

1. Add `config-ctl.sh` to the Architecture section:
   ```
   - **`config-ctl.sh`** -- manages configMapGenerator literals in Kustomize configurations. Manipulates kustomization.yaml files via yq. Does not interact with the cluster.
   ```

2. Add to the Template placeholders table:
   - `{{IMAGE}}`, `{{SECRET_ENV_VARS}}`, `{{PROBES}}`, `{{SECRET_NAME}}`, `{{MOUNT_PATH}}`, `{{STORAGE_SIZE}}`, `{{PROBE_PATH}}`, `{{HOST}}`, `{{PATH}}` (sources and usage from spec section 7)

3. Add preset frontmatter system documentation:
   - Explain the frontmatter format and auto-discovery mechanism
   - Document how to add new presets

4. Add `config-ctl.sh` to the Workflow sequence (between step 4 and step 5)

5. Add `config-ctl.sh` function inventory:
   - `cmd_add(app, env)`, `cmd_list(app, env)`, `cmd_remove(app, env)`, `cmd_verify(env)`

6. Add to the Checklist for adding a new command:
   - If adding a new preset, place it in `templates/k8s/` with frontmatter

- [ ] **Step 2: Commit**

```bash
git add .claude/agents.md
git commit -m "Update agent context with preset system and config-ctl docs

- Add config-ctl.sh to architecture and workflow sections
- Document preset frontmatter system and auto-discovery
- Add new template placeholders table entries
- Add config-ctl function inventory"
```

---

### Task 10: Manual end-to-end verification

This task verifies the full flow works correctly by running the commands in a temporary directory.

- [ ] **Step 1: Set up test environment**

```bash
cd "$(mktemp -d)"
git init
git remote add origin https://github.com/remerle/test-repo.git
```

- [ ] **Step 2: Run init and add-env**

```bash
infra-ctl.sh init
infra-ctl.sh add-env dev
```

Expected: Standard scaffold created with dev namespace.

- [ ] **Step 3: Test add-app with web preset**

```bash
infra-ctl.sh add-app backend
```

Walk through:
- Workload: Deployment
- Preset: web
- IMAGE: `ghcr.io/remerle/k8s-practice-backend:latest`
- PORT: 3000 (accept default)
- Add secret references? yes -> Secret name: `backend-secrets` -> `DATABASE_URL=database-url` -> empty to finish
- Add health probes? yes -> `/api/health` (accept default)
- Add config values? no
- Confirm

Expected: Creates `k8s/apps/backend/base/deployment.yaml` with the entered values, service, kustomization, overlay, ArgoCD app.

Verify: `cat k8s/apps/backend/base/deployment.yaml` shows correct image, port, secretKeyRef, probes.

- [ ] **Step 4: Test add-app with postgres preset**

```bash
infra-ctl.sh add-app postgres
```

Walk through:
- Workload: StatefulSet
- Preset: postgres
- Accept all defaults
- Confirm

Expected: Creates `k8s/apps/postgres/base/statefulset.yaml` with postgres defaults, headless service, configMapGenerator with `POSTGRES_DB=app`.

Verify: `cat k8s/apps/postgres/base/statefulset.yaml` shows pg_isready probes, volumeClaimTemplates.
Verify: `cat k8s/apps/postgres/base/kustomization.yaml` shows `POSTGRES_DB` in configMapGenerator literals.

- [ ] **Step 5: Test add-ingress**

```bash
infra-ctl.sh add-ingress backend
```

Enter: hostname `app.localhost`, path `/`

Expected: Creates `k8s/apps/backend/base/ingress.yaml`, adds to kustomization resources.

Verify: `cat k8s/apps/backend/base/ingress.yaml` shows correct host and port.
Verify: `yq '.resources' k8s/apps/backend/base/kustomization.yaml` includes `ingress.yaml`.

- [ ] **Step 6: Test config-ctl commands**

```bash
config-ctl.sh add backend base
# Enter: API_URL=http://backend:3000, then empty

config-ctl.sh list backend base
# Expected: shows API_URL=http://backend:3000

config-ctl.sh remove backend base
# Select API_URL=http://backend:3000
```

- [ ] **Step 7: Test list-ingress and remove-ingress**

```bash
infra-ctl.sh list-ingress
# Expected: shows backend (host: app.localhost, path: /)

infra-ctl.sh remove-ingress backend
# Confirm removal
# Expected: ingress.yaml deleted, removed from kustomization
```

- [ ] **Step 8: Test completions load**

```bash
source completions.zsh
# Expected: no errors
```

- [ ] **Step 9: Clean up and commit verification results**

No commit needed for this task -- it's manual verification only.
