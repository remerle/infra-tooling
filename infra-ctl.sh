#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib/common.sh"

# --- Commands ---

cmd_init() {
    require_gum
    require_gh

    # --- Parse flags ---
    local repo_url_flag=""
    local yes="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo-url)
                [[ -z "${2:-}" ]] && { print_error "--repo-url requires a value"; exit 1; }
                repo_url_flag="$2"; shift 2 ;;
            --yes|-y)
                yes="true"; shift ;;
            -h|--help)
                echo "Usage: infra-ctl.sh init [--repo-url <url>] [--yes]"
                echo "  --repo-url <url>  GitHub repository URL (default: detected from git remote)"
                echo "  --yes, -y         Skip confirmation prompt"
                exit 0 ;;
            -*)
                print_error "Unknown flag: $1"; exit 1 ;;
            *)
                print_error "Unexpected positional argument: $1"; exit 1 ;;
        esac
    done

    # Idempotency guard
    if [[ -d "${TARGET_DIR}/argocd" || -d "${TARGET_DIR}/k8s" ]]; then
        print_error "Repository already initialized (argocd/ or k8s/ exists in ${TARGET_DIR})."
        echo "  If you want to re-initialize, remove these directories first." >&2
        exit 1
    fi

    print_header "Initialize GitOps Repository"

    # Detect repo URL from git remote, prompt with it as default.
    # Convert SSH URLs to HTTPS since ArgoCD uses HTTPS for repo access.
    local default_url=""
    if git -C "$TARGET_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
        default_url="$(git -C "$TARGET_DIR" remote get-url origin 2>/dev/null || true)"
        if [[ "$default_url" =~ ^git@github\.com:(.+)$ ]]; then
            default_url="https://github.com/${BASH_REMATCH[1]}"
        fi
    fi

    # --- Resolve repo_url: flag wins, else prompt, else die ---
    local repo_url
    if [[ -n "$repo_url_flag" ]]; then
        repo_url="$repo_url_flag"
    else
        repo_url=$(prompt_or_die "Repository URL" "--repo-url" "$default_url")
    fi

    if [[ -z "$repo_url" ]]; then
        print_error "Repository URL is required."
        exit 1
    fi

    validate_github_repo "$repo_url"

    # Extract and confirm owner
    local repo_owner
    repo_owner="$(extract_repo_owner "$repo_url")"
    print_info "Detected repo owner: ${repo_owner}"

    if [[ "$yes" != "true" ]]; then
        if [[ -t 0 ]]; then
            confirm_or_abort "Proceed with repo URL '${repo_url}' and owner '${repo_owner}'?"
        fi
        # Non-interactive without --yes: proceed (init is non-destructive)
    fi

    local created_files=()

    # Determine whether Kargo is active: check an existing conf file (if present)
    # and the cluster. This covers the case where cluster-ctl installed Kargo
    # before init ran (conf didn't exist yet) and the case where init is being
    # re-run on an existing repo.
    local kargo_enabled=false
    if [[ -f "${TARGET_DIR}/.infra-ctl.conf" ]] && grep -q '^KARGO_ENABLED=true' "${TARGET_DIR}/.infra-ctl.conf"; then
        kargo_enabled=true
    fi
    if kubectl get namespace kargo &>/dev/null 2>&1; then
        kargo_enabled=true
    fi

    # Create directory skeleton
    local dirs=(
        "${TARGET_DIR}/k8s/namespaces"
        "${TARGET_DIR}/k8s/apps"
        "${TARGET_DIR}/argocd/apps"
        "${TARGET_DIR}/argocd/projects"
        "${TARGET_DIR}/kargo"
    )
    local dir
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
    done

    # Place .gitkeep in empty directories
    local gitkeep_dirs=(
        "${TARGET_DIR}/k8s/namespaces"
        "${TARGET_DIR}/k8s/apps"
        "${TARGET_DIR}/argocd/projects"
        "${TARGET_DIR}/kargo"
    )
    local gk_dir
    for gk_dir in "${gitkeep_dirs[@]}"; do
        touch "${gk_dir}/.gitkeep"
        created_files+=("${gk_dir}/.gitkeep")
    done

    # Create Kargo promotion order file if enabled (empty initially;
    # add-env populates it as environments are created, sorted by convention)
    if [[ "$kargo_enabled" == true ]]; then
        local promo_file="${TARGET_DIR}/kargo/promotion-order.txt"
        touch "$promo_file"
        rm -f "${TARGET_DIR}/kargo/.gitkeep"
        created_files+=("$promo_file")
    fi

    # Render parent-app.yaml
    local parent_app="${TARGET_DIR}/argocd/parent-app.yaml"
    render_template \
        "${TEMPLATE_DIR}/argocd/parent-app.yaml" \
        "$parent_app" \
        "REPO_URL=${repo_url}"
    created_files+=("$parent_app")

    # Render projects.yaml (Application pointing at argocd/projects/)
    local projects_app="${TARGET_DIR}/argocd/apps/projects.yaml"
    render_template \
        "${TEMPLATE_DIR}/argocd/projects-app.yaml" \
        "$projects_app" \
        "REPO_URL=${repo_url}"
    created_files+=("$projects_app")

    # Render kargo.yaml (umbrella Application pointing at kargo/) if Kargo is enabled.
    # This is what applies the Kargo Project/Warehouse/Stage resources to the
    # cluster. Without it, resources under kargo/ are never deployed.
    if [[ "$kargo_enabled" == true ]]; then
        local kargo_apps="${TARGET_DIR}/argocd/apps/kargo.yaml"
        render_template \
            "${TEMPLATE_DIR}/argocd/kargo-apps.yaml" \
            "$kargo_apps" \
            "REPO_URL=${repo_url}"
        created_files+=("$kargo_apps")
    fi

    # Create .gitignore if one doesn't exist
    local gitignore="${TARGET_DIR}/.gitignore"
    if safe_write "$gitignore" "$(cat "${TEMPLATE_DIR}/gitignore")"; then
        created_files+=("$gitignore")
    fi

    # Save configuration
    save_conf "$repo_url" "$repo_owner"
    created_files+=("${TARGET_DIR}/.infra-ctl.conf")

    # Persist KARGO_ENABLED=true in conf if we detected Kargo
    if [[ "$kargo_enabled" == true ]]; then
        local conf_file="${TARGET_DIR}/.infra-ctl.conf"
        if ! grep -q '^KARGO_ENABLED=true' "$conf_file"; then
            echo "KARGO_ENABLED=true" >>"$conf_file"
        fi
    fi

    print_summary "${created_files[@]}"
    print_info "Repository initialized. Next steps:"
    print_info "  1. Add environments and apps:    infra-ctl.sh add-env / add-app"
    print_info "  2. (Optional) Add a project:     infra-ctl.sh add-project <name>"
    print_info "  3. If your repo is private:      cluster-ctl.sh add-argo-creds"
}

cmd_add_app() {
    require_gum
    require_yq

    # --- Parse flags ---
    local app_name_flag=""
    local project_flag=""
    local workload_type_flag=""
    local preset_flag=""
    declare -A set_values=()
    local secret_keys_flag=()
    local config_flag_entries=()
    local kargo_flag=""       # "", "true", "false"
    local image_repo_flag=""
    local custom_flag=false
    local image_flag=""
    local port_flag=""
    local secret_name_flag=""
    local probe_path_flag=""
    local yes="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)         [[ -z "${2:-}" ]] && { print_error "--name requires a value"; exit 1; }
                            app_name_flag="$2"; shift 2 ;;
            --project)      [[ -z "${2:-}" ]] && { print_error "--project requires a value"; exit 1; }
                            project_flag="$2"; shift 2 ;;
            --workload-type)
                            [[ -z "${2:-}" ]] && { print_error "--workload-type requires a value"; exit 1; }
                            workload_type_flag="$(tr '[:upper:]' '[:lower:]' <<<"$2")"; shift 2 ;;
            --preset)       [[ -z "${2:-}" ]] && { print_error "--preset requires a value"; exit 1; }
                            preset_flag="$2"; shift 2 ;;
            --set)          [[ -z "${2:-}" ]] && { print_error "--set requires KEY=VAL"; exit 1; }
                            parse_set_kv "$2" set_values; shift 2 ;;
            --secret-key)   [[ -z "${2:-}" ]] && { print_error "--secret-key requires a value"; exit 1; }
                            secret_keys_flag+=("$2"); shift 2 ;;
            --config)       [[ -z "${2:-}" ]] && { print_error "--config requires KEY=VAL"; exit 1; }
                            config_flag_entries+=("$2"); shift 2 ;;
            --kargo)        kargo_flag="true"; shift ;;
            --no-kargo)     kargo_flag="false"; shift ;;
            --image-repo)   [[ -z "${2:-}" ]] && { print_error "--image-repo requires a value"; exit 1; }
                            image_repo_flag="$2"; shift 2 ;;
            --custom)       custom_flag=true; shift ;;
            --image)        [[ -z "${2:-}" ]] && { print_error "--image requires a value"; exit 1; }
                            image_flag="$2"; shift 2 ;;
            --port)         [[ -z "${2:-}" ]] && { print_error "--port requires a value"; exit 1; }
                            port_flag="$2"; shift 2 ;;
            --secret-name)  [[ -z "${2:-}" ]] && { print_error "--secret-name requires a value"; exit 1; }
                            secret_name_flag="$2"; shift 2 ;;
            --probe-path)   [[ -z "${2:-}" ]] && { print_error "--probe-path requires a value"; exit 1; }
                            probe_path_flag="$2"; shift 2 ;;
            --yes|-y)       yes="true"; shift ;;
            -h|--help)
                cat <<EOF
Usage: infra-ctl.sh add-app <name> [flags]

Flags:
  --name <string>               Application name (positional shorthand allowed)
  --project <name>              ArgoCD project (default: "default")
  --workload-type <type>        deployment | statefulset (default: deployment)
  --preset <name>               Preset from templates (default: first preset)
  --set KEY=VAL                 Preset placeholder values (repeatable)
  --secret-key NAME             Declare a secret key (repeatable, no value)
  --config KEY=VAL              configMap entries (repeatable)
  --kargo / --no-kargo          Enable/disable Kargo management
  --image-repo <url>            Kargo image repo (no tag; required if --kargo)
  --custom                      Use custom flow (Deployment only)
  --image <ref>                 Container image (custom flow)
  --port <n>                    Container port (custom flow; default: 8080)
  --secret-name <name>          Secret name (custom flow)
  --probe-path <path>           HTTP probe path (custom flow)
  --yes, -y                     Skip confirmation prompt
EOF
                exit 0 ;;
            -*)             print_error "Unknown flag: $1"; exit 1 ;;
            *)              if [[ -z "$app_name_flag" ]]; then
                                app_name_flag="$1"
                            else
                                print_error "Unexpected argument: $1"; exit 1
                            fi
                            shift ;;
        esac
    done

    # --- Resolve app_name ---
    local app_name
    if [[ -n "$app_name_flag" ]]; then
        app_name="$app_name_flag"
    else
        app_name=$(prompt_or_die "App name" "--name")
    fi
    validate_k8s_name "$app_name" "App name"
    load_conf

    # Guard: app already exists
    local app_dir="${TARGET_DIR}/k8s/apps/${app_name}"
    if [[ -d "$app_dir" ]]; then
        print_error "Application '${app_name}' already exists at ${app_dir}"
        exit 1
    fi

    # Detect envs and projects
    local envs=()
    while IFS= read -r env; do
        envs+=("$env")
    done < <(detect_envs)

    local projects=()
    while IFS= read -r proj; do
        projects+=("$proj")
    done < <(detect_projects)

    # Project selection: flag wins, else choose, else default
    local project="default"
    if [[ -n "$project_flag" ]]; then
        if [[ "$project_flag" != "default" ]]; then
            local found=0 p
            for p in "${projects[@]}"; do
                [[ "$p" == "$project_flag" ]] && { found=1; break; }
            done
            if [[ "$found" -eq 0 ]]; then
                print_error "Project '${project_flag}' does not exist. Known: default ${projects[*]}"
                exit 1
            fi
        fi
        project="$project_flag"
    elif [[ ${#projects[@]} -gt 0 ]]; then
        project=$(prompt_choose_or_die "Select project for '${app_name}'" "--project" "default" "${projects[@]}")
    fi

    # Workload type: flag wins, else prompt, else default
    local workload_type
    if [[ -n "$workload_type_flag" ]]; then
        case "$workload_type_flag" in
            deployment)  workload_type="Deployment" ;;
            statefulset) workload_type="StatefulSet" ;;
            *) print_error "--workload-type must be 'deployment' or 'statefulset', got: ${workload_type_flag}"; exit 1 ;;
        esac
    elif [[ -t 0 ]]; then
        workload_type=$(prompt_choose_or_die "Workload type" "--workload-type" "Deployment" "StatefulSet")
    else
        workload_type="Deployment"
    fi

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
        # Resolve preset: --custom wins, --preset next, else prompt, else first preset
        if [[ "$custom_flag" == "true" ]]; then
            if [[ "$workload_prefix" == "statefulset" ]]; then
                print_error "--custom is not supported for StatefulSet workloads"
                exit 1
            fi
            preset_choice="custom"
        elif [[ -n "$preset_flag" ]]; then
            local found=0 p
            for p in "${presets[@]}"; do
                [[ "$p" == "$preset_flag" ]] && { found=1; break; }
            done
            if [[ "$found" -eq 0 ]]; then
                print_error "Unknown preset: ${preset_flag}. Known: ${presets[*]}"
                exit 1
            fi
            preset_choice="$preset_flag"
        elif [[ -t 0 ]]; then
            # Interactive chooser with descriptions
            local preset_labels=()
            local preset
            for preset in "${presets[@]}"; do
                local template_file="${TEMPLATE_DIR}/k8s/${workload_prefix}-${preset}.yaml"
                local desc
                desc="$(get_preset_field "$template_file" '.description')"
                preset_labels+=("${preset} -- ${desc}")
            done
            if [[ "$workload_prefix" == "deployment" ]]; then
                preset_labels+=("custom -- Configure manually")
            fi

            print_header "Select preset for '${app_name}'"
            local chosen_label
            chosen_label="$(printf "%s\n" "${preset_labels[@]}" | gum choose)"
            preset_choice="${chosen_label%% -- *}"
        else
            # Non-interactive fallback: use first preset
            preset_choice="${presets[0]}"
        fi
    elif [[ "$workload_prefix" == "statefulset" ]]; then
        print_error "No StatefulSet presets found in templates/k8s/. Add a statefulset-*.yaml template."
        exit 1
    fi

    # Collect configuration values based on preset or custom flow
    local preset_template=""
    local port=""
    local image=""
    local secret_name=""
    local probe_path=""
    local secret_keys=()
    local config_entries=()
    local storage_size=""
    local mount_path=""

    if [[ "$preset_choice" != "custom" ]]; then
        # --- Preset flow ---
        preset_template="${TEMPLATE_DIR}/k8s/${workload_prefix}-${preset_choice}.yaml"

        # Validate --set keys against this preset's schema
        if [[ ${#set_values[@]} -gt 0 ]]; then
            validate_preset_set_keys "$preset_template" "${!set_values[@]}"
        fi

        # Collect defaults into array first (gum input inside a while-read loop
        # steals stdin from the process substitution)
        local defaults_lines=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && defaults_lines+=("$line")
        done < <(get_preset_defaults "$preset_template")

        # Walk through each default: --set wins, else prompt if TTY, else die/default
        local key default_val
        for line in "${defaults_lines[@]}"; do
            key="${line%%=*}"
            default_val="${line#*=}"
            # Resolve {{APP_NAME}} in defaults
            default_val="${default_val//\{\{APP_NAME\}\}/${app_name}}"

            local prompted_val=""
            if [[ -v "set_values[$key]" ]]; then
                prompted_val="${set_values[$key]}"
            elif [[ -t 0 ]]; then
                # Interactive: prompt with hint and optional marker
                local optional_flag=""
                if is_preset_optional "$preset_template" "$key"; then
                    optional_flag=" (optional, leave empty to skip)"
                fi
                local hint
                hint="$(get_preset_hint "$preset_template" "$key")"
                local header_arg=()
                if [[ -n "$hint" ]]; then
                    header_arg=(--header "$hint")
                fi
                prompted_val="$(gum input --value "$default_val" "${header_arg[@]}" --prompt "${key}${optional_flag}: ")"
            else
                # Non-interactive: use default for optional keys; die for required
                if is_preset_optional "$preset_template" "$key"; then
                    prompted_val="$default_val"
                else
                    print_error "--set ${key}=<value> is required when not running interactively"
                    exit 1
                fi
            fi

            # Store into the appropriate variable
            case "$key" in
                IMAGE) image="$prompted_val" ;;
                PORT) port="$prompted_val" ;;
                SECRET_NAME) secret_name="$prompted_val" ;;
                PROBE_PATH) probe_path="$prompted_val" ;;
                STORAGE_SIZE) storage_size="$prompted_val" ;;
                MOUNT_PATH) mount_path="$prompted_val" ;;
            esac
        done

        # Validate required fields
        if [[ -z "$image" ]]; then
            print_error "IMAGE is required."
            exit 1
        fi
        if [[ -z "$port" ]]; then
            print_error "PORT is required."
            exit 1
        fi
        validate_port "$port"

        # Collect config entries from preset (same stdin issue as above)
        local config_lines=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && config_lines+=("$line")
        done < <(get_preset_config "$preset_template")

        # Build --config flag overrides by key
        declare -A config_flag_map=()
        local cfe
        for cfe in "${config_flag_entries[@]}"; do
            [[ "$cfe" != *"="* ]] && { print_error "--config expects KEY=VAL, got: ${cfe}"; exit 1; }
            config_flag_map["${cfe%%=*}"]="${cfe#*=}"
        done

        for line in "${config_lines[@]}"; do
            key="${line%%=*}"
            default_val="${line#*=}"
            local cfg_val=""
            if [[ -v "config_flag_map[$key]" ]]; then
                cfg_val="${config_flag_map[$key]}"
                unset config_flag_map["$key"]
            elif [[ -t 0 ]]; then
                cfg_val="$(gum input --value "$default_val" --prompt "Config ${key}: ")"
            else
                cfg_val="$default_val"
            fi
            [[ -n "$cfg_val" ]] && config_entries+=("${key}=${cfg_val}")
        done

        # Any --config entries not in the preset are extra user additions
        local extra_key
        for extra_key in "${!config_flag_map[@]}"; do
            config_entries+=("${extra_key}=${config_flag_map[$extra_key]}")
        done

        # Collect secret key names from preset frontmatter, --secret-key, or prompt
        if [[ -n "$secret_name" ]]; then
            local preset_secrets_lines=()
            while IFS= read -r line; do
                [[ -n "$line" ]] && preset_secrets_lines+=("$line")
            done < <(get_preset_secrets "$preset_template")

            if [[ ${#preset_secrets_lines[@]} -gt 0 ]]; then
                secret_keys=("${preset_secrets_lines[@]}")
            elif [[ ${#secret_keys_flag[@]} -gt 0 ]]; then
                secret_keys=("${secret_keys_flag[@]}")
            elif [[ -t 0 ]]; then
                print_info "Enter the names of secret keys for '${secret_name}' (values are added later via secret-ctl.sh)."
                print_info "Leave empty to finish."
                while true; do
                    local key
                    key="$(gum input --placeholder "DATABASE_URL" --prompt "Secret key name (empty to finish): ")"
                    [[ -z "$key" ]] && break
                    secret_keys+=("$key")
                done
            fi
            # Non-interactive with no --secret-key is allowed (empty secret_keys)
        fi
    else
        # --- Custom flow (deployment only) ---
        if [[ -n "$image_flag" ]]; then
            image="$image_flag"
        else
            image=$(prompt_or_die "Container image" "--image")
        fi
        if [[ -z "$image" ]]; then
            print_error "Container image is required."
            exit 1
        fi

        if [[ -n "$port_flag" ]]; then
            port="$port_flag"
        elif [[ -t 0 ]]; then
            while true; do
                port="$(gum input --value "8080" --prompt "Container port: ")"
                validate_port "$port" && break
            done
        else
            port="8080"
        fi
        validate_port "$port"

        # Optional: secret name
        if [[ -n "$secret_name_flag" ]]; then
            secret_name="$secret_name_flag"
        elif [[ -t 0 ]]; then
            secret_name="$(gum input --placeholder "${app_name}-secrets" --prompt "Secret name (optional, empty to skip): ")"
        fi

        if [[ -n "$secret_name" ]]; then
            if [[ ${#secret_keys_flag[@]} -gt 0 ]]; then
                secret_keys=("${secret_keys_flag[@]}")
            elif [[ -t 0 ]]; then
                print_info "Enter the names of secret keys for '${secret_name}' (values are added later via secret-ctl.sh)."
                print_info "Leave empty to finish."
                while true; do
                    local key
                    key="$(gum input --placeholder "DATABASE_URL" --prompt "Secret key name (empty to finish): ")"
                    [[ -z "$key" ]] && break
                    secret_keys+=("$key")
                done
            fi
        fi

        # Optional: probe path
        if [[ -n "$probe_path_flag" ]]; then
            probe_path="$probe_path_flag"
        elif [[ -t 0 ]]; then
            probe_path="$(gum input --placeholder "/api/health" --prompt "Probe path (optional, empty to skip): ")"
        fi

        # Use the web template as the base for custom deployments
        preset_template="${TEMPLATE_DIR}/k8s/deployment-web.yaml"
    fi

    # Add --config flag entries (applies to both preset and custom flows).
    # In preset flow, entries matching preset config keys were already
    # consumed above; only NEW entries remain here in the custom flow.
    if [[ "$preset_choice" == "custom" ]]; then
        local cfe
        for cfe in "${config_flag_entries[@]}"; do
            [[ "$cfe" != *"="* ]] && { print_error "--config expects KEY=VAL, got: ${cfe}"; exit 1; }
            config_entries+=("$cfe")
        done
    fi

    # Interactive-only: prompt for additional config values (legacy custom flow)
    if [[ "$preset_choice" == "custom" ]] && [[ ${#config_flag_entries[@]} -eq 0 ]] && [[ -t 0 ]]; then
        print_info "Add config values for configMapGenerator (leave empty to finish)."
        while true; do
            local cfg_entry
            cfg_entry="$(gum input --placeholder "KEY=value" --prompt "Config entry (empty to finish): ")"
            [[ -z "$cfg_entry" ]] && break
            config_entries+=("$cfg_entry")
        done
    fi

    # Preview what will be created
    local workload_file
    if [[ "$workload_type" == "StatefulSet" ]]; then
        workload_file="statefulset.yaml"
    else
        workload_file="deployment.yaml"
    fi

    # Kargo management: flag wins, else prompt if TTY, else default by workload
    local kargo_managed=false
    if is_kargo_enabled; then
        if [[ "$kargo_flag" == "true" ]]; then
            kargo_managed=true
        elif [[ "$kargo_flag" == "false" ]]; then
            kargo_managed=false
        elif [[ -t 0 ]]; then
            local kargo_default
            if [[ "$workload_type" == "Deployment" ]]; then
                kargo_default="--default=Yes"
            else
                kargo_default="--default=No"
            fi
            if gum confirm "Manage image promotion with Kargo?" $kargo_default; then
                kargo_managed=true
            fi
        else
            # Non-interactive default: yes for Deployment, no for StatefulSet
            [[ "$workload_type" == "Deployment" ]] && kargo_managed=true
        fi
    fi

    print_header "Add Application: ${app_name}"
    print_info "Project:  ${project}"
    print_info "Workload: ${workload_type}"
    print_info "Preset:   ${preset_choice}"
    print_info "Image:    ${image}"
    print_info "Port:     ${port}"
    if [[ -n "$secret_name" ]]; then
        print_info "Secret:   ${secret_name}"
    fi
    if [[ -n "$probe_path" ]]; then
        print_info "Probes:   ${probe_path}"
    fi
    if [[ ${#config_entries[@]} -gt 0 ]]; then
        local entry
        for entry in "${config_entries[@]}"; do
            print_info "Config:   ${entry}"
        done
    fi
    print_info "Base: k8s/apps/${app_name}/base/kustomization.yaml"
    print_info "Base: k8s/apps/${app_name}/base/${workload_file}"
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
    if [[ "$kargo_managed" == true ]]; then
        print_info "Kargo:   kargo/${app_name}/project.yaml"
        print_info "Kargo:   kargo/${app_name}/warehouse.yaml"
        if [[ ${#envs[@]} -gt 0 ]]; then
            local env
            for env in "${envs[@]}"; do
                print_info "Kargo:   kargo/${app_name}/${env}-stage.yaml"
            done
        fi
    fi

    if [[ "$yes" != "true" ]] && [[ -t 0 ]]; then
        confirm_or_abort "Create these files?"
    fi

    local created_files=()

    # Create base kustomization (workload-type-specific)
    local base_kustomization="${app_dir}/base/kustomization.yaml"
    local kustomization_template
    if [[ "$workload_type" == "StatefulSet" ]]; then
        kustomization_template="${TEMPLATE_DIR}/k8s/base-kustomization-statefulset.yaml"
    else
        kustomization_template="${TEMPLATE_DIR}/k8s/base-kustomization-deployment.yaml"
    fi
    if safe_render_template "$kustomization_template" "$base_kustomization" \
        "APP_NAME=${app_name}"; then
        created_files+=("$base_kustomization")
    fi

    # Create base service (headless for StatefulSet)
    local base_service="${app_dir}/base/service.yaml"
    local service_template
    if [[ "$workload_type" == "StatefulSet" ]]; then
        service_template="${TEMPLATE_DIR}/k8s/service-headless.yaml"
    else
        service_template="${TEMPLATE_DIR}/k8s/service.yaml"
    fi
    if safe_render_template "$service_template" "$base_service" \
        "APP_NAME=${app_name}" \
        "PORT=${port}"; then
        created_files+=("$base_service")
    fi

    # Render workload manifest
    local workload_output="${app_dir}/base/${workload_file}"
    local secret_env_block=""
    local probes_block=""

    # Build SECRET_ENV_VARS block for deployment templates
    if [[ "$workload_prefix" == "deployment" ]]; then
        secret_env_block="$(build_secret_env_vars "$secret_name" "${secret_keys[@]}")"
        probes_block="$(build_http_probes "$probe_path" "$port")"
    fi

    local render_args=(
        "APP_NAME=${app_name}"
        "IMAGE=${image}"
        "PORT=${port}"
    )
    if [[ -n "$secret_name" ]]; then
        render_args+=("SECRET_NAME=${secret_name}")
    fi
    if [[ -n "$storage_size" ]]; then
        render_args+=("STORAGE_SIZE=${storage_size}")
    fi
    if [[ -n "$mount_path" ]]; then
        render_args+=("MOUNT_PATH=${mount_path}")
    fi
    if [[ "$workload_prefix" == "deployment" ]]; then
        render_args+=("SECRET_ENV_VARS=${secret_env_block}")
        render_args+=("PROBES=${probes_block}")
    fi

    if safe_render_preset_template "$preset_template" "$workload_output" \
        "${render_args[@]}"; then
        strip_blank_placeholder_lines "$workload_output"
        created_files+=("$workload_output")
    fi

    # Append config entries to base configMapGenerator via yq
    if [[ ${#config_entries[@]} -gt 0 ]]; then
        local entry
        for entry in "${config_entries[@]}"; do
            yq eval -i \
                ".configMapGenerator[0].literals += [\"${entry}\"]" \
                "$base_kustomization"
        done
    fi

    # Create overlays and ArgoCD apps per env
    if [[ ${#envs[@]} -gt 0 ]]; then
        local env
        for env in "${envs[@]}"; do
            # Overlay kustomization
            local overlay="${app_dir}/overlays/${env}/kustomization.yaml"
            if safe_render_template \
                "${TEMPLATE_DIR}/k8s/overlay-kustomization.yaml" \
                "$overlay" \
                "APP_NAME=${app_name}" \
                "ENV=${env}"; then
                created_files+=("$overlay")
            fi

            # ArgoCD Application manifest
            local argo_app="${TARGET_DIR}/argocd/apps/${app_name}-${env}.yaml"
            if safe_render_template \
                "${TEMPLATE_DIR}/argocd/app-env.yaml" \
                "$argo_app" \
                "APP_NAME=${app_name}" \
                "ENV=${env}" \
                "PROJECT=${project}" \
                "REPO_URL=${REPO_URL}"; then
                created_files+=("$argo_app")
            fi
        done
    fi

    # Generate Kargo resources if user opted in
    if [[ "$kargo_managed" == true ]]; then
        require_gh
        require_gh_scope "read:packages"
        # Derive default image repo from the entered image (strip tag)
        local default_image_repo="${image%%:*}"
        local image_repo
        if [[ -n "$image_repo_flag" ]]; then
            image_repo="$image_repo_flag"
        elif [[ -t 0 ]]; then
            while true; do
                image_repo="$(gum input --value "${default_image_repo}" --prompt "Image repo for Kargo (no tag): ")"
                validate_image_repo "$image_repo" && break
            done
        else
            image_repo="$default_image_repo"
        fi
        validate_image_repo "$image_repo"

        local kargo_app_dir="${TARGET_DIR}/kargo/${app_name}"
        mkdir -p "$kargo_app_dir"

        # Generate Kargo Project
        if safe_render_template \
            "${TEMPLATE_DIR}/kargo/project.yaml" \
            "${kargo_app_dir}/project.yaml" \
            "APP_NAME=${app_name}"; then
            created_files+=("${kargo_app_dir}/project.yaml")
        fi

        # Generate Warehouse
        if safe_render_template \
            "${TEMPLATE_DIR}/kargo/warehouse.yaml" \
            "${kargo_app_dir}/warehouse.yaml" \
            "APP_NAME=${app_name}" \
            "IMAGE_REPO=${image_repo}"; then
            created_files+=("${kargo_app_dir}/warehouse.yaml")
        fi

        # Generate Stages if environments exist
        if [[ ${#envs[@]} -gt 0 ]]; then
            read_promotion_order
            local envs_csv
            envs_csv="$(
                IFS=','
                echo "${envs[*]}"
            )"
            while IFS= read -r stage_file; do
                created_files+=("$stage_file")
            done < <(generate_kargo_stages "$app_name" "$image_repo" "$kargo_app_dir" "$envs_csv")
        else
            print_info "No environments found. Kargo Stages will be created when you run 'add-env'."
        fi
    fi

    print_summary "${created_files[@]}"

    if [[ -n "$secret_name" && ${#secret_keys[@]} -gt 0 ]]; then
        echo ""
        print_info "This app requires secret '${secret_name}' with keys: ${secret_keys[*]}"
        print_info "Create it for each environment with:"
        local env
        for env in "${envs[@]}"; do
            local keys_placeholder
            keys_placeholder="$(printf ' %s=<value>' "${secret_keys[@]}")"
            print_info "  secret-ctl.sh add ${app_name} ${env}${keys_placeholder}"
        done
    fi

    if [[ "$kargo_managed" == true && -d "${TARGET_DIR}/kargo/${app_name}" ]]; then
        print_info "If your repo or registry is private, configure credentials:"
        print_info "  cluster-ctl.sh add-kargo-creds"
    fi
}

cmd_add_ingress() {
    require_gum
    require_yq
    load_conf

    local app_name_flag=""
    local env_flags=()
    local yes="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app)  [[ -z "${2:-}" ]] && { print_error "--app requires a value"; exit 1; }
                    app_name_flag="$2"; shift 2 ;;
            --env)  [[ -z "${2:-}" ]] && { print_error "--env requires a value"; exit 1; }
                    env_flags+=("$2"); shift 2 ;;
            --yes|-y) yes="true"; shift ;;
            -h|--help)
                echo "Usage: infra-ctl.sh add-ingress <app> [--env <name>]... [--yes]"
                exit 0 ;;
            -*) print_error "Unknown flag: $1"; exit 1 ;;
            *)  if [[ -z "$app_name_flag" ]]; then app_name_flag="$1"
                else print_error "Unexpected argument: $1"; exit 1
                fi
                shift ;;
        esac
    done

    local app_name="$app_name_flag"
    if [[ -z "$app_name" ]]; then
        if [[ -t 0 ]]; then
            app_name="$(detect_apps | choose_from "Select application:" "No applications found. Run 'add-app' first.")" || exit 0
        else
            print_error "--app is required when not running interactively"
            exit 1
        fi
    fi
    validate_k8s_name "$app_name" "App name"

    # Guard: app must exist
    local app_dir="${TARGET_DIR}/k8s/apps/${app_name}"
    if [[ ! -d "$app_dir" ]]; then
        print_error "Application '${app_name}' not found at ${app_dir}"
        exit 1
    fi

    # Auto-detect port from service.yaml
    local port
    port="$(detect_service_port "$app_name")"
    if [[ -z "$port" ]]; then
        print_error "Could not detect port from ${app_dir}/base/service.yaml"
        exit 1
    fi

    # Collect overlays for this app (one per env)
    local overlays_dir="${app_dir}/overlays"
    if [[ ! -d "$overlays_dir" ]]; then
        print_error "No overlays found for '${app_name}'. Add an environment first with 'infra-ctl.sh add-env'."
        exit 1
    fi

    local available_envs=()
    local d
    for d in "$overlays_dir"/*/; do
        [[ -d "$d" ]] || continue
        local env_name
        env_name="$(basename "$d")"
        # Skip envs that already have an ingress
        if [[ -f "${d}ingress.yaml" ]]; then
            continue
        fi
        available_envs+=("$env_name")
    done

    if [[ ${#available_envs[@]} -eq 0 ]]; then
        print_warning "All environments already have an ingress for '${app_name}'."
        return
    fi

    # Multi-select envs: flags win, else prompt if TTY, else default to all
    local selected=()
    if [[ ${#env_flags[@]} -gt 0 ]]; then
        # Validate each --env against available
        local ef e found
        for ef in "${env_flags[@]}"; do
            found=0
            for e in "${available_envs[@]}"; do
                [[ "$ef" == "$e" ]] && { found=1; break; }
            done
            [[ "$found" -eq 0 ]] && { print_error "Env '${ef}' has no overlay for '${app_name}' without an existing ingress"; exit 1; }
        done
        selected=("${env_flags[@]}")
    elif [[ ${#available_envs[@]} -eq 1 ]]; then
        selected=("${available_envs[0]}")
    elif [[ -t 0 ]]; then
        local selected_csv
        selected_csv="$(printf '%s,' "${available_envs[@]}" | sed 's/,$//')"
        readarray -t selected < <(printf '%s\n' "${available_envs[@]}" \
            | gum choose --no-limit --selected="$selected_csv" \
                --header "Add ingress to which environments?")
    else
        # Non-interactive default: all available
        selected=("${available_envs[@]}")
    fi

    if [[ ${#selected[@]} -eq 0 ]]; then
        print_warning "No environments selected."
        return
    fi

    # Preview
    print_header "Add Ingress: ${app_name}"
    print_info "Service: ${app_name}:${port}"
    print_info "Environments:"
    local env
    for env in "${selected[@]}"; do
        print_info "  ${env}.${app_name}.localhost -> overlays/${env}/ingress.yaml"
    done

    if [[ "$yes" != "true" ]] && [[ -t 0 ]]; then
        confirm_or_abort "Create ingress?"
    fi

    local created_files=()

    for env in "${selected[@]}"; do
        local ingress_file="${overlays_dir}/${env}/ingress.yaml"
        if safe_render_template "${TEMPLATE_DIR}/k8s/ingress.yaml" "$ingress_file" \
            "APP_NAME=${app_name}" \
            "ENV=${env}" \
            "PORT=${port}"; then
            created_files+=("$ingress_file")
        fi

        # Add ingress.yaml to overlay kustomization resources
        local overlay_kustomization="${overlays_dir}/${env}/kustomization.yaml"
        yq eval -i '.resources += ["ingress.yaml"] | .resources |= unique' "$overlay_kustomization"
    done

    print_summary "${created_files[@]}"
    print_info "Hostnames are now trusted only if the cluster TLS cert includes them."
    print_info "Run 'cluster-ctl.sh renew-tls' to regenerate the cert."
}

cmd_list_ingress() {
    load_conf

    local found=0
    local app_dir
    for app_dir in "${TARGET_DIR}/k8s/apps"/*/; do
        [[ -d "$app_dir" ]] || continue
        local app_name
        app_name="$(basename "$app_dir")"

        local overlay
        for overlay in "${app_dir}overlays"/*/; do
            [[ -d "$overlay" ]] || continue
            local ingress_file="${overlay}ingress.yaml"
            [[ -f "$ingress_file" ]] || continue

            local env
            env="$(basename "$overlay")"
            local host
            host="$(yq eval '.spec.rules[0].host' "$ingress_file")"

            print_info "${app_name} [${env}]  https://${host}"
            found=1
        done
    done

    if [[ "$found" -eq 0 ]]; then
        print_warning "No ingress resources found."
        print_info "Run 'infra-ctl.sh add-ingress <app>' to create one."
    fi
}

cmd_remove_ingress() {
    require_gum
    require_yq
    load_conf

    local app_name_flag=""
    local env_flags=()
    local yes="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app) app_name_flag="$2"; shift 2 ;;
            --env) env_flags+=("$2"); shift 2 ;;
            --yes|-y) yes="true"; shift ;;
            -h|--help) echo "Usage: infra-ctl.sh remove-ingress <app> [--env <name>]... [--yes]"; exit 0 ;;
            -*) print_error "Unknown flag: $1"; exit 1 ;;
            *) if [[ -z "$app_name_flag" ]]; then app_name_flag="$1"; else print_error "Unexpected: $1"; exit 1; fi; shift ;;
        esac
    done

    local app_name="$app_name_flag"
    if [[ -z "$app_name" ]]; then
        # Build list of apps that have at least one overlay ingress
        local apps_with_ingress=()
        local app_dir
        for app_dir in "${TARGET_DIR}/k8s/apps"/*/; do
            [[ -d "$app_dir" ]] || continue
            local has_ingress=0
            local overlay
            for overlay in "${app_dir}overlays"/*/; do
                [[ -f "${overlay}ingress.yaml" ]] && has_ingress=1 && break
            done
            [[ "$has_ingress" -eq 1 ]] && apps_with_ingress+=("$(basename "$app_dir")")
        done
        if [[ ${#apps_with_ingress[@]} -eq 0 ]]; then
            print_warning "No ingress resources found."
            return
        fi
        if [[ -t 0 ]]; then
            app_name="$(printf "%s\n" "${apps_with_ingress[@]}" | gum choose --header "Select application:")"
        else
            print_error "--app is required when not running interactively"
            exit 1
        fi
    fi
    validate_k8s_name "$app_name" "App name"

    local app_dir="${TARGET_DIR}/k8s/apps/${app_name}"
    local overlays_dir="${app_dir}/overlays"
    if [[ ! -d "$overlays_dir" ]]; then
        print_error "No overlays directory for '${app_name}'"
        exit 1
    fi

    # Find envs that have ingress
    local envs_with_ingress=()
    local overlay
    for overlay in "$overlays_dir"/*/; do
        [[ -f "${overlay}ingress.yaml" ]] || continue
        envs_with_ingress+=("$(basename "$overlay")")
    done

    if [[ ${#envs_with_ingress[@]} -eq 0 ]]; then
        print_error "No ingress found for '${app_name}'"
        exit 1
    fi

    # Multi-select envs to remove from
    local selected=()
    if [[ ${#env_flags[@]} -gt 0 ]]; then
        local ef e found
        for ef in "${env_flags[@]}"; do
            found=0
            for e in "${envs_with_ingress[@]}"; do
                [[ "$ef" == "$e" ]] && { found=1; break; }
            done
            [[ "$found" -eq 0 ]] && { print_error "Env '${ef}' has no ingress for '${app_name}'"; exit 1; }
        done
        selected=("${env_flags[@]}")
    elif [[ ${#envs_with_ingress[@]} -eq 1 ]]; then
        selected=("${envs_with_ingress[0]}")
    elif [[ -t 0 ]]; then
        local selected_csv
        selected_csv="$(printf '%s,' "${envs_with_ingress[@]}" | sed 's/,$//')"
        readarray -t selected < <(printf '%s\n' "${envs_with_ingress[@]}" \
            | gum choose --no-limit --selected="$selected_csv" \
                --header "Remove ingress from which environments?")
    else
        selected=("${envs_with_ingress[@]}")
    fi

    if [[ ${#selected[@]} -eq 0 ]]; then
        print_warning "No environments selected."
        return
    fi

    # Preview
    print_header "Remove Ingress: ${app_name}"
    local env
    for env in "${selected[@]}"; do
        print_info "  ${env}.${app_name}.localhost"
    done

    require_yes "$yes" "remove ingress for '${app_name}' from ${selected[*]}"

    local removed=()
    for env in "${selected[@]}"; do
        local ingress_file="${overlays_dir}/${env}/ingress.yaml"
        rm -f "$ingress_file"
        removed+=("$ingress_file")

        local overlay_kustomization="${overlays_dir}/${env}/kustomization.yaml"
        yq eval -i '.resources -= ["ingress.yaml"]' "$overlay_kustomization"
    done

    print_removed "${removed[@]}"
    print_info "Run 'cluster-ctl.sh renew-tls' to regenerate the cert without these hostnames."
}

cmd_add_env() {
    require_gum

    local env_name_flag=""
    local yes="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name) env_name_flag="$2"; shift 2 ;;
            --yes|-y) yes="true"; shift ;;
            -h|--help) echo "Usage: infra-ctl.sh add-env <name> [--yes]"; exit 0 ;;
            -*) print_error "Unknown flag: $1"; exit 1 ;;
            *) if [[ -z "$env_name_flag" ]]; then env_name_flag="$1"; else print_error "Unexpected: $1"; exit 1; fi; shift ;;
        esac
    done

    local env_name="$env_name_flag"
    if [[ -z "$env_name" ]]; then
        env_name=$(prompt_or_die "Environment name" "--name")
    fi
    validate_k8s_name "$env_name" "Environment name"
    load_conf

    # Guard: env already exists
    local ns_file="${TARGET_DIR}/k8s/namespaces/${env_name}.yaml"
    if [[ -f "$ns_file" ]]; then
        print_error "Environment '${env_name}' already exists at ${ns_file}"
        exit 1
    fi

    # Detect apps
    local apps=()
    while IFS= read -r app; do
        apps+=("$app")
    done < <(detect_apps)

    # For each app, detect its project assignment
    declare -A app_projects
    if [[ ${#apps[@]} -gt 0 ]]; then
        local app
        for app in "${apps[@]}"; do
            app_projects["$app"]="$(detect_app_project "$app")"
        done
    fi

    # Preview
    print_header "Add Environment: ${env_name}"
    print_info "Namespace: k8s/namespaces/${env_name}.yaml"
    if [[ ${#apps[@]} -gt 0 ]]; then
        local app
        for app in "${apps[@]}"; do
            print_info "Overlay: k8s/apps/${app}/overlays/${env_name}/kustomization.yaml"
            print_info "ArgoCD:  argocd/apps/${app}-${env_name}.yaml (project: ${app_projects[$app]})"
        done
    else
        print_warning "No applications found. Only the namespace will be created."
        print_info "Run 'infra-ctl.sh add-app <app>' to create overlays later."
    fi
    if is_kargo_enabled; then
        if [[ ${#apps[@]} -gt 0 ]]; then
            local app
            for app in "${apps[@]}"; do
                if [[ -d "${TARGET_DIR}/kargo/${app}" ]]; then
                    print_info "Kargo:   kargo/${app}/${env_name}-stage.yaml"
                fi
            done
        fi
    fi

    if [[ "$yes" != "true" ]] && [[ -t 0 ]]; then
        confirm_or_abort "Create these files?"
    fi

    local created_files=()

    # Create namespace
    if safe_render_template \
        "${TEMPLATE_DIR}/k8s/namespace.yaml" \
        "$ns_file" \
        "ENV=${env_name}"; then
        created_files+=("$ns_file")
    fi

    # Remove .gitkeep from namespaces dir if it exists (no longer empty)
    rm -f "${TARGET_DIR}/k8s/namespaces/.gitkeep"

    # Create overlays and ArgoCD apps per app
    if [[ ${#apps[@]} -gt 0 ]]; then
        local app
        for app in "${apps[@]}"; do
            local project="${app_projects[$app]}"

            # Overlay kustomization
            local overlay="${TARGET_DIR}/k8s/apps/${app}/overlays/${env_name}/kustomization.yaml"
            if safe_render_template \
                "${TEMPLATE_DIR}/k8s/overlay-kustomization.yaml" \
                "$overlay" \
                "APP_NAME=${app}" \
                "ENV=${env_name}"; then
                created_files+=("$overlay")
            fi

            # ArgoCD Application manifest
            local argo_app="${TARGET_DIR}/argocd/apps/${app}-${env_name}.yaml"
            if safe_render_template \
                "${TEMPLATE_DIR}/argocd/app-env.yaml" \
                "$argo_app" \
                "APP_NAME=${app}" \
                "ENV=${env_name}" \
                "PROJECT=${project}" \
                "REPO_URL=${REPO_URL}"; then
                created_files+=("$argo_app")
            fi
        done
    fi

    # Generate Kargo Stages for the new environment
    if is_kargo_enabled; then
        read_promotion_order

        # Add env to promotion order (sorted by convention) if not already present
        local env_in_order=false
        local i
        for i in "${!PROMOTION_ORDER[@]}"; do
            if [[ "${PROMOTION_ORDER[$i]}" == "$env_name" ]]; then
                env_in_order=true
                break
            fi
        done

        if [[ "$env_in_order" == false ]]; then
            # Rebuild the file with the new env inserted in conventional order
            local all_envs=("${PROMOTION_ORDER[@]}" "$env_name")
            rebuild_promotion_order "${all_envs[@]}"
        fi

        # Re-read the (possibly updated) order
        read_promotion_order

        print_info "Promotion order:"
        for i in "${!PROMOTION_ORDER[@]}"; do
            print_info "  $((i + 1)). ${PROMOTION_ORDER[$i]}"
        done

        # Find the upstream env (the one before this env in the order)
        local upstream_env=""
        for i in "${!PROMOTION_ORDER[@]}"; do
            if [[ "${PROMOTION_ORDER[$i]}" == "$env_name" ]]; then
                if [[ $i -gt 0 ]]; then
                    upstream_env="${PROMOTION_ORDER[$((i - 1))]}"
                fi
                break
            fi
        done

        # Find the position of the new env and its downstream neighbor
        local new_idx=-1
        local downstream_env=""
        for i in "${!PROMOTION_ORDER[@]}"; do
            if [[ "${PROMOTION_ORDER[$i]}" == "$env_name" ]]; then
                new_idx=$i
                if [[ $((i + 1)) -lt ${#PROMOTION_ORDER[@]} ]]; then
                    downstream_env="${PROMOTION_ORDER[$((i + 1))]}"
                fi
                break
            fi
        done

        # Generate stages for each existing app
        if [[ ${#apps[@]} -gt 0 ]]; then
            local app
            for app in "${apps[@]}"; do
                local kargo_app_dir="${TARGET_DIR}/kargo/${app}"

                # Only generate if the app has Kargo resources
                [[ -d "$kargo_app_dir" ]] || continue

                # Read image repo from existing warehouse
                local image_repo
                image_repo="$(grep 'repoURL:' "${kargo_app_dir}/warehouse.yaml" 2>/dev/null \
                    | head -1 | sed 's/.*repoURL:\s*//' | xargs)" || image_repo="ghcr.io/${REPO_OWNER}/${app}"

                # 1. Generate the new env's Stage
                local stage_file="${kargo_app_dir}/${env_name}-stage.yaml"
                if [[ $new_idx -eq 0 ]]; then
                    # First in chain: sources directly from Warehouse
                    if safe_render_template \
                        "${TEMPLATE_DIR}/kargo/stage-direct.yaml" \
                        "$stage_file" \
                        "APP_NAME=${app}" \
                        "ENV=${env_name}" \
                        "IMAGE_REPO=${image_repo}" \
                        "REPO_URL=${REPO_URL}"; then
                        created_files+=("$stage_file")
                    fi

                    # The old first env (now second) needs to switch from direct to promoted
                    if [[ -n "$downstream_env" && -f "${kargo_app_dir}/${downstream_env}-stage.yaml" ]]; then
                        render_template \
                            "${TEMPLATE_DIR}/kargo/stage-promoted.yaml" \
                            "${kargo_app_dir}/${downstream_env}-stage.yaml" \
                            "APP_NAME=${app}" \
                            "ENV=${downstream_env}" \
                            "IMAGE_REPO=${image_repo}" \
                            "UPSTREAM_STAGE=${app}-${env_name}" \
                            "REPO_URL=${REPO_URL}"
                        print_warning "Updated ${downstream_env}-stage.yaml: now promoted from ${env_name}"
                    fi
                else
                    # Not first: promoted from upstream
                    if safe_render_template \
                        "${TEMPLATE_DIR}/kargo/stage-promoted.yaml" \
                        "$stage_file" \
                        "APP_NAME=${app}" \
                        "ENV=${env_name}" \
                        "IMAGE_REPO=${image_repo}" \
                        "UPSTREAM_STAGE=${app}-${upstream_env}" \
                        "REPO_URL=${REPO_URL}"; then
                        created_files+=("$stage_file")
                    fi

                    # Update the downstream env's Stage to point to the new env
                    if [[ -n "$downstream_env" && -f "${kargo_app_dir}/${downstream_env}-stage.yaml" ]]; then
                        render_template \
                            "${TEMPLATE_DIR}/kargo/stage-promoted.yaml" \
                            "${kargo_app_dir}/${downstream_env}-stage.yaml" \
                            "APP_NAME=${app}" \
                            "ENV=${downstream_env}" \
                            "IMAGE_REPO=${image_repo}" \
                            "UPSTREAM_STAGE=${app}-${env_name}" \
                            "REPO_URL=${REPO_URL}"
                        print_warning "Updated ${downstream_env}-stage.yaml: now promoted from ${env_name}"
                    fi
                fi
            done
        fi
    fi

    print_summary "${created_files[@]}"
}

cmd_add_project() {
    require_gum

    local name_flag="" desc_flag="" repos_flag=""
    local restrict_repos_flag=""         # "", "true", "false"
    local restrict_ns_flag=""            # "", "true", "false"
    local cluster_resources_flag=""      # "", "true", "false"
    local ns_flags=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)         name_flag="$2"; shift 2 ;;
            --description)  desc_flag="$2"; shift 2 ;;
            --restrict-repos)    restrict_repos_flag="true"; shift ;;
            --no-restrict-repos) restrict_repos_flag="false"; shift ;;
            --source-repos) repos_flag="$2"; shift 2 ;;
            --namespaces)
                IFS=',' read -ra _ns <<<"$2"
                ns_flags+=("${_ns[@]}")
                restrict_ns_flag="true"
                shift 2 ;;
            --no-restrict-namespaces) restrict_ns_flag="false"; shift ;;
            --cluster-resources)    cluster_resources_flag="true"; shift ;;
            --no-cluster-resources) cluster_resources_flag="false"; shift ;;
            -h|--help) echo "Usage: infra-ctl.sh add-project <name> [flags: --description, --restrict-repos, --source-repos, --namespaces, --cluster-resources]"; exit 0 ;;
            -*) print_error "Unknown flag: $1"; exit 1 ;;
            *)  if [[ -z "$name_flag" ]]; then name_flag="$1"; else print_error "Unexpected: $1"; exit 1; fi; shift ;;
        esac
    done

    local project_name="$name_flag"
    if [[ -z "$project_name" ]]; then
        project_name=$(prompt_or_die "Project name" "--name")
    fi
    validate_k8s_name "$project_name" "Project name"
    load_conf

    # Guard: project already exists
    local project_file="${TARGET_DIR}/argocd/projects/${project_name}.yaml"
    if [[ -f "$project_file" ]]; then
        print_error "Project '${project_name}' already exists at ${project_file}"
        print_info "Use 'infra-ctl.sh edit-project ${project_name}' to modify it."
        exit 1
    fi

    print_header "Add Project: ${project_name}"

    # Description
    local description
    if [[ -n "$desc_flag" ]]; then
        description="$desc_flag"
    elif [[ -t 0 ]]; then
        description="$(gum input --placeholder "What does this project scope?" --prompt "Description: ")"
    else
        description=""
    fi

    # Source repo restrictions
    local restrict_repos="no"
    if [[ "$restrict_repos_flag" == "true" ]]; then restrict_repos="yes"
    elif [[ "$restrict_repos_flag" == "false" ]]; then restrict_repos="no"
    elif [[ -n "$repos_flag" ]]; then restrict_repos="yes"  # providing --source-repos implies restriction
    elif [[ -t 0 ]]; then
        gum confirm "Restrict source repositories?" && restrict_repos="yes"
    fi

    local source_repos_block
    if [[ "$restrict_repos" == "yes" ]]; then
        local repos_input
        if [[ -n "$repos_flag" ]]; then
            repos_input="$repos_flag"
        elif [[ -t 0 ]]; then
            repos_input="$(gum input --value "${REPO_URL}" --prompt "Allowed repos (comma-separated): ")"
        else
            repos_input="${REPO_URL}"
        fi
        source_repos_block=""
        IFS=',' read -ra repos <<<"$repos_input"
        local repo
        for repo in "${repos[@]}"; do
            repo="$(echo "$repo" | xargs)" # trim whitespace
            validate_github_repo "$repo"
            source_repos_block+="    - ${repo}"$'\n'
        done
        source_repos_block="${source_repos_block%$'\n'}"
    else
        source_repos_block="    - '*'"
    fi

    # Destination namespace restrictions
    local restrict_ns="no"
    if [[ "$restrict_ns_flag" == "true" ]]; then restrict_ns="yes"
    elif [[ "$restrict_ns_flag" == "false" ]]; then restrict_ns="no"
    elif [[ ${#ns_flags[@]} -gt 0 ]]; then restrict_ns="yes"
    elif [[ -t 0 ]]; then
        gum confirm "Restrict destination namespaces?" && restrict_ns="yes"
    fi

    local destinations_block
    if [[ "$restrict_ns" == "yes" ]]; then
        local envs=()
        while IFS= read -r env; do
            envs+=("$env")
        done < <(detect_envs)

        local selected_namespaces=()
        if [[ ${#ns_flags[@]} -gt 0 ]]; then
            selected_namespaces=("${ns_flags[@]}")
        elif [[ -t 0 ]] && [[ ${#envs[@]} -gt 0 ]]; then
            mapfile -t selected_namespaces < <(printf "%s\n" "${envs[@]}" | gum choose --no-limit)
        elif [[ -t 0 ]]; then
            local ns_input
            ns_input="$(gum input --placeholder "dev, staging, prod" --prompt "Allowed namespaces (comma-separated): ")"
            IFS=',' read -ra selected_namespaces <<<"$ns_input"
        else
            print_error "--namespaces is required when restricting namespaces non-interactively"
            exit 1
        fi

        destinations_block=""
        local ns
        for ns in "${selected_namespaces[@]}"; do
            ns="$(echo "$ns" | xargs)"
            [[ -z "$ns" ]] && continue
            destinations_block+="    - namespace: ${ns}"$'\n'
            destinations_block+="      server: https://kubernetes.default.svc"$'\n'
        done
        destinations_block="${destinations_block%$'\n'}"
    else
        destinations_block="    - namespace: '*'"$'\n'
        destinations_block+="      server: https://kubernetes.default.svc"
    fi

    # Cluster-scoped resource access
    local allow_cluster="no"
    if [[ "$cluster_resources_flag" == "true" ]]; then allow_cluster="yes"
    elif [[ "$cluster_resources_flag" == "false" ]]; then allow_cluster="no"
    elif [[ -t 0 ]]; then
        gum confirm "Allow full cluster-scoped resource access? (Namespaces, ClusterRoles, CRDs, etc.)" && allow_cluster="yes"
    fi

    local cluster_resources_block
    if [[ "$allow_cluster" == "yes" ]]; then
        cluster_resources_block="    - group: '*'"$'\n'
        cluster_resources_block+="      kind: '*'"
    else
        cluster_resources_block="    - group: ''"$'\n'
        cluster_resources_block+="      kind: Namespace"
    fi

    # Render template
    render_template \
        "${TEMPLATE_DIR}/argocd/appproject.yaml" \
        "$project_file" \
        "PROJECT_NAME=${project_name}" \
        "PROJECT_DESCRIPTION=${description}" \
        "SOURCE_REPOS=${source_repos_block}" \
        "DESTINATIONS=${destinations_block}" \
        "CLUSTER_RESOURCES=${cluster_resources_block}"

    # Remove .gitkeep from projects dir if it exists
    rm -f "${TARGET_DIR}/argocd/projects/.gitkeep"

    print_summary "$project_file"
}

cmd_edit_project() {
    require_gum

    local name_flag="" desc_flag="" repos_flag=""
    local restrict_repos_flag=""
    local restrict_ns_flag=""
    local cluster_resources_flag=""
    local ns_flags=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)         name_flag="$2"; shift 2 ;;
            --description)  desc_flag="$2"; shift 2 ;;
            --restrict-repos)    restrict_repos_flag="true"; shift ;;
            --no-restrict-repos) restrict_repos_flag="false"; shift ;;
            --source-repos) repos_flag="$2"; shift 2 ;;
            --namespaces)
                IFS=',' read -ra _ns <<<"$2"
                ns_flags+=("${_ns[@]}")
                restrict_ns_flag="true"
                shift 2 ;;
            --no-restrict-namespaces) restrict_ns_flag="false"; shift ;;
            --cluster-resources)    cluster_resources_flag="true"; shift ;;
            --no-cluster-resources) cluster_resources_flag="false"; shift ;;
            -h|--help) echo "Usage: infra-ctl.sh edit-project [name] [flags]"; exit 0 ;;
            -*) print_error "Unknown flag: $1"; exit 1 ;;
            *)  if [[ -z "$name_flag" ]]; then name_flag="$1"; else print_error "Unexpected: $1"; exit 1; fi; shift ;;
        esac
    done

    local project_name="$name_flag"

    if [[ -z "$project_name" ]]; then
        load_conf
        if [[ -t 0 ]]; then
            project_name="$(detect_projects | choose_from "Select project to edit:" "No projects to edit.")" || exit 0
        else
            print_error "--name is required when not running interactively"
            exit 1
        fi
    fi

    load_conf

    local project_file="${TARGET_DIR}/argocd/projects/${project_name}.yaml"
    if [[ ! -f "$project_file" ]]; then
        print_error "Project '${project_name}' not found at ${project_file}"
        exit 1
    fi

    print_header "Edit Project: ${project_name}"

    # Parse current values from the existing file
    local current_description
    current_description="$(grep '^\s*description:' "$project_file" | sed 's/.*description:\s*"\?\([^"]*\)"\?/\1/')"

    # Check if currently restricted
    local current_repos_restricted=false
    if ! grep -q "sourceRepos:" "$project_file" || ! grep -A1 "sourceRepos:" "$project_file" | grep -q "'\*'"; then
        current_repos_restricted=true
    fi

    local current_ns_restricted=false
    if ! grep -q "destinations:" "$project_file" || ! grep -A1 "destinations:" "$project_file" | grep -q "namespace: '\*'"; then
        current_ns_restricted=true
    fi

    # Description: flag wins, else prompt (pre-filled), else keep current
    local description
    if [[ -n "$desc_flag" ]]; then
        description="$desc_flag"
    elif [[ -t 0 ]]; then
        description="$(gum input --value "$current_description" --prompt "Description: ")"
    else
        description="$current_description"
    fi

    # Source repo restrictions
    local restrict_repos
    if [[ "$restrict_repos_flag" == "true" ]]; then restrict_repos="yes"
    elif [[ "$restrict_repos_flag" == "false" ]]; then restrict_repos="no"
    elif [[ -n "$repos_flag" ]]; then restrict_repos="yes"
    elif [[ -t 0 ]]; then
        local confirm_msg="Restrict source repositories?"
        [[ "$current_repos_restricted" == true ]] && confirm_msg="Restrict source repositories? (currently restricted)"
        if gum confirm "$confirm_msg"; then restrict_repos="yes"; else restrict_repos="no"; fi
    else
        restrict_repos=$([[ "$current_repos_restricted" == true ]] && echo "yes" || echo "no")
    fi

    local source_repos_block
    if [[ "$restrict_repos" == "yes" ]]; then
        local current_repos=""
        if [[ "$current_repos_restricted" == true ]]; then
            current_repos="$(awk '/sourceRepos:/,/destinations:/{if(/- / && !/sourceRepos:/ && !/destinations:/) print}' "$project_file" | sed 's/.*- //' | tr '\n' ',' | sed 's/,$//')"
        else
            current_repos="${REPO_URL}"
        fi
        local repos_input
        if [[ -n "$repos_flag" ]]; then
            repos_input="$repos_flag"
        elif [[ -t 0 ]]; then
            repos_input="$(gum input --value "$current_repos" --prompt "Allowed repos (comma-separated): ")"
        else
            repos_input="$current_repos"
        fi
        source_repos_block=""
        IFS=',' read -ra repos <<<"$repos_input"
        local repo
        for repo in "${repos[@]}"; do
            repo="$(echo "$repo" | xargs)"
            validate_github_repo "$repo"
            source_repos_block+="    - ${repo}"$'\n'
        done
        source_repos_block="${source_repos_block%$'\n'}"
    else
        source_repos_block="    - '*'"
    fi

    # Destination namespace restrictions
    local restrict_ns
    if [[ "$restrict_ns_flag" == "true" ]]; then restrict_ns="yes"
    elif [[ "$restrict_ns_flag" == "false" ]]; then restrict_ns="no"
    elif [[ ${#ns_flags[@]} -gt 0 ]]; then restrict_ns="yes"
    elif [[ -t 0 ]]; then
        local confirm_msg="Restrict destination namespaces?"
        [[ "$current_ns_restricted" == true ]] && confirm_msg="Restrict destination namespaces? (currently restricted)"
        if gum confirm "$confirm_msg"; then restrict_ns="yes"; else restrict_ns="no"; fi
    else
        restrict_ns=$([[ "$current_ns_restricted" == true ]] && echo "yes" || echo "no")
    fi

    local destinations_block
    if [[ "$restrict_ns" == "yes" ]]; then
        local envs=()
        while IFS= read -r env; do
            envs+=("$env")
        done < <(detect_envs)

        local selected_namespaces=()
        if [[ ${#ns_flags[@]} -gt 0 ]]; then
            selected_namespaces=("${ns_flags[@]}")
        elif [[ -t 0 ]] && [[ ${#envs[@]} -gt 0 ]]; then
            mapfile -t selected_namespaces < <(printf "%s\n" "${envs[@]}" | gum choose --no-limit)
        elif [[ -t 0 ]]; then
            local ns_input
            ns_input="$(gum input --placeholder "dev, staging, prod" --prompt "Allowed namespaces (comma-separated): ")"
            IFS=',' read -ra selected_namespaces <<<"$ns_input"
        else
            print_error "--namespaces is required when restricting namespaces non-interactively"
            exit 1
        fi

        destinations_block=""
        local ns
        for ns in "${selected_namespaces[@]}"; do
            ns="$(echo "$ns" | xargs)"
            [[ -z "$ns" ]] && continue
            destinations_block+="    - namespace: ${ns}"$'\n'
            destinations_block+="      server: https://kubernetes.default.svc"$'\n'
        done
        destinations_block="${destinations_block%$'\n'}"
    else
        destinations_block="    - namespace: '*'"$'\n'
        destinations_block+="      server: https://kubernetes.default.svc"
    fi

    # Cluster-scoped resource access
    local current_cluster_restricted=false
    if ! grep -q "clusterResourceWhitelist:" "$project_file" || ! grep -A1 "clusterResourceWhitelist:" "$project_file" | grep -q "group: '\*'"; then
        current_cluster_restricted=true
    fi

    local allow_cluster
    if [[ "$cluster_resources_flag" == "true" ]]; then allow_cluster="yes"
    elif [[ "$cluster_resources_flag" == "false" ]]; then allow_cluster="no"
    elif [[ -t 0 ]]; then
        local confirm_msg="Allow full cluster-scoped resource access? (Namespaces, ClusterRoles, CRDs, etc.)"
        [[ "$current_cluster_restricted" == true ]] && confirm_msg="Allow full cluster-scoped resource access? (currently restricted)"
        if gum confirm "$confirm_msg"; then allow_cluster="yes"; else allow_cluster="no"; fi
    else
        allow_cluster=$([[ "$current_cluster_restricted" == true ]] && echo "no" || echo "yes")
    fi

    local cluster_resources_block
    if [[ "$allow_cluster" == "yes" ]]; then
        cluster_resources_block="    - group: '*'"$'\n'
        cluster_resources_block+="      kind: '*'"
    else
        cluster_resources_block="    - group: ''"$'\n'
        cluster_resources_block+="      kind: Namespace"
    fi

    # Regenerate from template
    render_template \
        "${TEMPLATE_DIR}/argocd/appproject.yaml" \
        "$project_file" \
        "PROJECT_NAME=${project_name}" \
        "PROJECT_DESCRIPTION=${description}" \
        "SOURCE_REPOS=${source_repos_block}" \
        "DESTINATIONS=${destinations_block}" \
        "CLUSTER_RESOURCES=${cluster_resources_block}"

    print_success "Project '${project_name}' updated."
}

cmd_enable_kargo() {
    require_gum
    require_gh
    require_gh_scope "read:packages"
    load_conf

    if is_kargo_enabled; then
        print_warning "Kargo is already enabled in .infra-ctl.conf"
        exit 0
    fi

    print_header "Enable Kargo"

    # Set KARGO_ENABLED in conf
    local conf_file="${TARGET_DIR}/.infra-ctl.conf"
    if grep -q '^KARGO_ENABLED=' "$conf_file"; then
        local tmp
        tmp="$(awk '/^KARGO_ENABLED=/{print "KARGO_ENABLED=true"; next}1' "$conf_file")"
        printf '%s\n' "$tmp" >"$conf_file"
    else
        echo "KARGO_ENABLED=true" >>"$conf_file"
    fi
    print_success "Set KARGO_ENABLED=true in .infra-ctl.conf"

    # Create promotion-order.txt from existing environments, sorted by convention
    local envs=()
    while IFS= read -r env; do
        envs+=("$env")
    done < <(detect_envs)

    if [[ ${#envs[@]} -gt 0 ]]; then
        rebuild_promotion_order "${envs[@]}"
        print_info "Detected environments, sorted by convention:"
        read_promotion_order
        local i
        for i in "${!PROMOTION_ORDER[@]}"; do
            print_info "  $((i + 1)). ${PROMOTION_ORDER[$i]}"
        done

        confirm_or_abort "Use this order? (Edit kargo/promotion-order.txt after to change)"
    else
        mkdir -p "${TARGET_DIR}/kargo"
        touch "${TARGET_DIR}/kargo/promotion-order.txt"
        print_info "No environments detected. Promotion order will be built as you add environments."
    fi
    rm -f "${TARGET_DIR}/kargo/.gitkeep"
    print_success "Created kargo/promotion-order.txt"

    local created_files=("${TARGET_DIR}/kargo/promotion-order.txt")

    # Render the kargo.yaml umbrella Application if it doesn't exist.
    # This is what applies the Kargo Project/Warehouse/Stage resources to the
    # cluster. Without it, resources under kargo/ are never deployed.
    local kargo_apps="${TARGET_DIR}/argocd/apps/kargo.yaml"
    if [[ ! -f "$kargo_apps" ]]; then
        render_template \
            "${TEMPLATE_DIR}/argocd/kargo-apps.yaml" \
            "$kargo_apps" \
            "REPO_URL=${REPO_URL}"
        created_files+=("$kargo_apps")
        print_success "Created argocd/apps/kargo.yaml"
    fi

    # Generate Kargo resources for existing apps
    local apps=()
    while IFS= read -r app; do
        apps+=("$app")
    done < <(detect_apps)

    if [[ ${#apps[@]} -gt 0 ]]; then
        read_promotion_order

        local app
        for app in "${apps[@]}"; do
            local kargo_app_dir="${TARGET_DIR}/kargo/${app}"
            mkdir -p "$kargo_app_dir"

            # Prompt for image repository per app (no tag -- Kargo discovers tags)
            local image_repo
            while true; do
                image_repo="$(gum input --value "ghcr.io/${REPO_OWNER}/${app}" --prompt "Image repo for ${app} (no tag): ")"
                validate_image_repo "$image_repo" && break
            done

            # Project
            if safe_render_template \
                "${TEMPLATE_DIR}/kargo/project.yaml" \
                "${kargo_app_dir}/project.yaml" \
                "APP_NAME=${app}"; then
                created_files+=("${kargo_app_dir}/project.yaml")
            fi

            # Warehouse
            if safe_render_template \
                "${TEMPLATE_DIR}/kargo/warehouse.yaml" \
                "${kargo_app_dir}/warehouse.yaml" \
                "APP_NAME=${app}" \
                "IMAGE_REPO=${image_repo}"; then
                created_files+=("${kargo_app_dir}/warehouse.yaml")
            fi

            # Stages
            local envs_csv
            envs_csv="$(
                IFS=','
                echo "${envs[*]}"
            )"
            while IFS= read -r stage_file; do
                created_files+=("$stage_file")
            done < <(generate_kargo_stages "$app" "$image_repo" "$kargo_app_dir" "$envs_csv")
        done
    else
        print_info "No apps found. Kargo resources will be generated when you run 'add-app'."
    fi

    print_summary "${created_files[@]}"
}

cmd_list_apps() {
    require_gum
    load_conf

    print_header "Applications"

    local apps=()
    while IFS= read -r app; do
        apps+=("$app")
    done < <(detect_apps)

    if [[ ${#apps[@]} -eq 0 ]]; then
        print_warning "No applications found."
        return
    fi

    local app
    for app in "${apps[@]}"; do
        # Show which envs have overlays
        local overlay_envs=()
        local overlay_dir="${TARGET_DIR}/k8s/apps/${app}/overlays"
        if [[ -d "$overlay_dir" ]]; then
            local d
            for d in "$overlay_dir"/*/; do
                [[ -d "$d" ]] || continue
                overlay_envs+=("$(basename "$d")")
            done
        fi

        local project
        project="$(detect_app_project "$app")"

        if [[ ${#overlay_envs[@]} -gt 0 ]]; then
            print_info "${app}  (project: ${project}, envs: ${overlay_envs[*]})"
        else
            print_info "${app}  (project: ${project}, no overlays)"
        fi
    done
}

cmd_list_envs() {
    require_gum
    load_conf

    print_header "Environments"

    local envs=()
    while IFS= read -r env; do
        envs+=("$env")
    done < <(detect_envs)

    if [[ ${#envs[@]} -eq 0 ]]; then
        print_warning "No environments found."
        return
    fi

    local env
    for env in "${envs[@]}"; do
        print_info "${env}"
    done

    if is_kargo_enabled && [[ -f "${TARGET_DIR}/kargo/promotion-order.txt" ]]; then
        read_promotion_order
        print_info "Promotion order: ${PROMOTION_ORDER[*]}"
    fi
}

cmd_list_projects() {
    require_gum
    load_conf

    print_header "Projects"

    local projects=()
    while IFS= read -r proj; do
        projects+=("$proj")
    done < <(detect_projects)

    if [[ ${#projects[@]} -eq 0 ]]; then
        print_warning "No projects found. Apps use the 'default' project."
        return
    fi

    local proj
    for proj in "${projects[@]}"; do
        # Show description from the project file
        local desc=""
        local proj_file="${TARGET_DIR}/argocd/projects/${proj}.yaml"
        if [[ -f "$proj_file" ]]; then
            desc="$(grep '^\s*description:' "$proj_file" | head -1 | sed 's/.*description:\s*"\?\([^"]*\)"\?/\1/')" || true
        fi

        if [[ -n "$desc" ]]; then
            print_info "${proj}  (${desc})"
        else
            print_info "${proj}"
        fi
    done
}

cmd_remove_project() {
    require_gum

    local project_name="${1:-}"

    if [[ -z "$project_name" ]]; then
        load_conf
        project_name="$(detect_projects | choose_from "Select project to remove:" "No projects to remove.")" || exit 0
    fi

    validate_k8s_name "$project_name" "Project name"
    load_conf

    local project_file="${TARGET_DIR}/argocd/projects/${project_name}.yaml"
    if [[ ! -f "$project_file" ]]; then
        print_error "Project '${project_name}' not found at ${project_file}"
        exit 1
    fi

    # Find apps assigned to this project
    local assigned_apps=()
    local apps=()
    while IFS= read -r app; do
        apps+=("$app")
    done < <(detect_apps)

    local app
    for app in "${apps[@]}"; do
        local app_project
        app_project="$(detect_app_project "$app")"
        if [[ "$app_project" == "$project_name" ]]; then
            assigned_apps+=("$app")
        fi
    done

    # Preview
    print_header "Remove Project: ${project_name}"
    print_info "Delete file: ${project_file}"

    if [[ ${#assigned_apps[@]} -gt 0 ]]; then
        print_warning "These apps are assigned to project '${project_name}':"
        local app
        for app in "${assigned_apps[@]}"; do
            print_info "  ${app}"
        done

        # Build reassignment choices: other projects + default
        local other_projects=("default")
        while IFS= read -r proj; do
            [[ "$proj" == "$project_name" ]] && continue
            other_projects+=("$proj")
        done < <(detect_projects)

        local reassign_to
        reassign_to="$(printf '%s\n' "${other_projects[@]}" | gum choose --header "Reassign these apps to:")"

        print_info "Apps will be reassigned to project '${reassign_to}'"
    fi

    confirm_or_abort "Remove project '${project_name}'?"

    # Reassign apps if needed
    if [[ ${#assigned_apps[@]} -gt 0 ]]; then
        local envs=()
        while IFS= read -r env; do
            envs+=("$env")
        done < <(detect_envs)

        local app
        for app in "${assigned_apps[@]}"; do
            local env
            for env in "${envs[@]}"; do
                local manifest="${TARGET_DIR}/argocd/apps/${app}-${env}.yaml"
                [[ -f "$manifest" ]] || continue
                # Replace the project field in the ArgoCD Application manifest
                local tmp
                tmp="$(sed "s/^\\(  project:\\).*/\\1 ${reassign_to}/" "$manifest")"
                printf '%s\n' "$tmp" >"$manifest"
            done
        done
        print_success "Reassigned ${#assigned_apps[@]} app(s) to project '${reassign_to}'"
    fi

    # Delete the project file
    rm -f "$project_file"

    # Restore .gitkeep if projects dir is now empty
    local projects_dir="${TARGET_DIR}/argocd/projects"
    local has_yaml=false
    local f
    for f in "$projects_dir"/*.yaml; do
        [[ -f "$f" ]] && has_yaml=true && break
    done
    if [[ "$has_yaml" == false ]]; then
        touch "${projects_dir}/.gitkeep"
    fi

    print_removed "$project_file"
}

cmd_remove_app() {
    require_gum

    local app_name="${1:-}"

    if [[ -z "$app_name" ]]; then
        load_conf
        app_name="$(detect_apps | choose_from "Select application to remove:" "No applications to remove.")" || exit 0
    fi
    validate_k8s_name "$app_name" "App name"
    load_conf

    # Guard: app must exist
    local app_dir="${TARGET_DIR}/k8s/apps/${app_name}"
    if [[ ! -d "$app_dir" ]]; then
        print_error "Application '${app_name}' not found at ${app_dir}"
        exit 1
    fi

    # Detect envs for ArgoCD manifest cleanup
    local envs=()
    while IFS= read -r env; do
        envs+=("$env")
    done < <(detect_envs)

    # Build list of files/dirs to remove
    local to_remove=()

    # App directory (base + all overlays)
    to_remove+=("${app_dir}")

    # ArgoCD Application manifests
    local env
    for env in "${envs[@]}"; do
        local argo_app="${TARGET_DIR}/argocd/apps/${app_name}-${env}.yaml"
        [[ -f "$argo_app" ]] && to_remove+=("$argo_app")
    done

    # Kargo resources
    local kargo_app_dir="${TARGET_DIR}/kargo/${app_name}"
    if is_kargo_enabled && [[ -d "$kargo_app_dir" ]]; then
        to_remove+=("$kargo_app_dir")
    fi

    # Preview
    print_header "Remove Application: ${app_name}"
    local item
    for item in "${to_remove[@]}"; do
        if [[ -d "$item" ]]; then
            print_info "Delete dir:  ${item}"
        else
            print_info "Delete file: ${item}"
        fi
    done

    confirm_or_abort "Remove application '${app_name}' and all its resources?"

    # Execute removal
    local removed_files=()
    for item in "${to_remove[@]}"; do
        if [[ -d "$item" ]]; then
            rm -rf "$item"
        else
            rm -f "$item"
        fi
        removed_files+=("$item")
    done

    # Restore .gitkeep if k8s/apps/ is now empty
    local apps_dir="${TARGET_DIR}/k8s/apps"
    if [[ -d "$apps_dir" ]] && ! ls -d "$apps_dir"/*/ &>/dev/null; then
        touch "${apps_dir}/.gitkeep"
        removed_files+=("(restored ${apps_dir}/.gitkeep)")
    fi

    print_removed "${removed_files[@]}"
}

cmd_remove_env() {
    require_gum

    local env_name="${1:-}"

    if [[ -z "$env_name" ]]; then
        load_conf
        env_name="$(detect_envs | choose_from "Select environment to remove:" "No environments to remove.")" || exit 0
    fi
    validate_k8s_name "$env_name" "Environment name"
    load_conf

    # Guard: env must exist
    local ns_file="${TARGET_DIR}/k8s/namespaces/${env_name}.yaml"
    if [[ ! -f "$ns_file" ]]; then
        print_error "Environment '${env_name}' not found at ${ns_file}"
        exit 1
    fi

    # Detect apps for overlay/manifest cleanup
    local apps=()
    while IFS= read -r app; do
        apps+=("$app")
    done < <(detect_apps)

    # Build list of files/dirs to remove
    local to_remove=()

    # Namespace file
    to_remove+=("$ns_file")

    # Per-app overlay dirs and ArgoCD manifests
    local app
    for app in "${apps[@]}"; do
        local overlay_dir="${TARGET_DIR}/k8s/apps/${app}/overlays/${env_name}"
        [[ -d "$overlay_dir" ]] && to_remove+=("$overlay_dir")

        local argo_app="${TARGET_DIR}/argocd/apps/${app}-${env_name}.yaml"
        [[ -f "$argo_app" ]] && to_remove+=("$argo_app")
    done

    # Kargo: compute chain repair info before deletion
    local kargo_repair=false
    local downstream_env=""
    local upstream_env=""
    local kargo_stages_to_remove=()

    if is_kargo_enabled; then
        # Collect stage files to remove
        for app in "${apps[@]}"; do
            local stage_file="${TARGET_DIR}/kargo/${app}/${env_name}-stage.yaml"
            [[ -f "$stage_file" ]] && kargo_stages_to_remove+=("$stage_file")
        done

        # Read promotion order and find neighbors
        if [[ -f "${TARGET_DIR}/kargo/promotion-order.txt" ]]; then
            read_promotion_order

            local idx=-1
            local i
            for i in "${!PROMOTION_ORDER[@]}"; do
                if [[ "${PROMOTION_ORDER[$i]}" == "$env_name" ]]; then
                    idx=$i
                    break
                fi
            done

            if [[ $idx -ge 0 ]]; then
                # Find upstream (env before the removed one)
                if [[ $idx -gt 0 ]]; then
                    upstream_env="${PROMOTION_ORDER[$((idx - 1))]}"
                fi

                # Find downstream (env after the removed one)
                if [[ $((idx + 1)) -lt ${#PROMOTION_ORDER[@]} ]]; then
                    downstream_env="${PROMOTION_ORDER[$((idx + 1))]}"
                    kargo_repair=true
                fi
            fi
        fi
    fi

    # Preview
    print_header "Remove Environment: ${env_name}"
    local item
    for item in "${to_remove[@]}"; do
        if [[ -d "$item" ]]; then
            print_info "Delete dir:  ${item}"
        else
            print_info "Delete file: ${item}"
        fi
    done
    for item in "${kargo_stages_to_remove[@]}"; do
        print_info "Delete file: ${item}"
    done

    if [[ "$kargo_repair" == true ]]; then
        print_info "Kargo chain repair:"
        if [[ -z "$upstream_env" ]]; then
            print_info "  ${downstream_env} stage will become first in chain (direct from warehouse)"
        else
            print_info "  ${downstream_env} stage will be re-linked to upstream: ${upstream_env}"
        fi
    fi

    if is_kargo_enabled && [[ -f "${TARGET_DIR}/kargo/promotion-order.txt" ]]; then
        print_info "Update: kargo/promotion-order.txt (remove '${env_name}')"
    fi

    confirm_or_abort "Remove environment '${env_name}' and all its resources?"

    # Execute removal
    local removed_files=()
    for item in "${to_remove[@]}"; do
        if [[ -d "$item" ]]; then
            rm -rf "$item"
        else
            rm -f "$item"
        fi
        removed_files+=("$item")
    done

    for item in "${kargo_stages_to_remove[@]}"; do
        rm -f "$item"
        removed_files+=("$item")
    done

    # Kargo: update promotion-order.txt and repair chain
    local regenerated_files=()
    if is_kargo_enabled && [[ -f "${TARGET_DIR}/kargo/promotion-order.txt" ]]; then
        # Remove env from promotion-order.txt
        local order_file="${TARGET_DIR}/kargo/promotion-order.txt"
        local tmp
        tmp="$(grep -v "^${env_name}$" "$order_file")"
        printf '%s\n' "$tmp" >"$order_file"

        # Repair downstream stages
        if [[ "$kargo_repair" == true ]]; then
            for app in "${apps[@]}"; do
                local kargo_app_dir="${TARGET_DIR}/kargo/${app}"
                [[ -d "$kargo_app_dir" ]] || continue

                local downstream_stage="${kargo_app_dir}/${downstream_env}-stage.yaml"
                [[ -f "$downstream_stage" ]] || continue

                # Read image repo from warehouse
                local image_repo
                image_repo="$(grep 'repoURL:' "${kargo_app_dir}/warehouse.yaml" 2>/dev/null \
                    | head -1 | sed 's/.*repoURL:\s*//' | xargs)" || image_repo="ghcr.io/${REPO_OWNER}/${app}"

                if [[ -z "$upstream_env" ]]; then
                    # Downstream becomes first in chain: direct from warehouse
                    render_template \
                        "${TEMPLATE_DIR}/kargo/stage-direct.yaml" \
                        "$downstream_stage" \
                        "APP_NAME=${app}" \
                        "ENV=${downstream_env}" \
                        "IMAGE_REPO=${image_repo}" \
                        "REPO_URL=${REPO_URL}"
                else
                    # Re-link downstream to new upstream
                    render_template \
                        "${TEMPLATE_DIR}/kargo/stage-promoted.yaml" \
                        "$downstream_stage" \
                        "APP_NAME=${app}" \
                        "ENV=${downstream_env}" \
                        "IMAGE_REPO=${image_repo}" \
                        "UPSTREAM_STAGE=${app}-${upstream_env}" \
                        "REPO_URL=${REPO_URL}"
                fi
                regenerated_files+=("$downstream_stage")
            done
        fi
    fi

    # Restore .gitkeep if k8s/namespaces/ is now empty
    local ns_dir="${TARGET_DIR}/k8s/namespaces"
    if [[ -d "$ns_dir" ]]; then
        local has_yaml=false
        local f
        for f in "$ns_dir"/*.yaml; do
            [[ -f "$f" ]] && has_yaml=true && break
        done
        if [[ "$has_yaml" == false ]]; then
            touch "${ns_dir}/.gitkeep"
            removed_files+=("(restored ${ns_dir}/.gitkeep)")
        fi
    fi

    print_removed "${removed_files[@]}"

    if [[ ${#regenerated_files[@]} -gt 0 ]]; then
        print_header "Regenerated (Kargo chain repair):"
        local f
        for f in "${regenerated_files[@]}"; do
            print_success "$f"
        done
    fi
}

cmd_reset() {
    require_gum

    print_header "Reset GitOps Repository"

    local targets=()
    local target
    for target in \
        "${TARGET_DIR}/k8s" \
        "${TARGET_DIR}/argocd" \
        "${TARGET_DIR}/kargo" \
        "${TARGET_DIR}/helm" \
        "${TARGET_DIR}/.infra-ctl.conf" \
        "${TARGET_DIR}/.sealed-secrets-cert.pem" \
        "${TARGET_DIR}/.sealed-secrets-key.json"; do
        if [[ -e "$target" ]]; then
            targets+=("$target")
        fi
    done

    if [[ ${#targets[@]} -eq 0 ]]; then
        print_warning "Nothing to reset in ${TARGET_DIR}"
        exit 0
    fi

    print_info "This will remove:"
    local t
    for t in "${targets[@]}"; do
        print_info "  ${t#"${TARGET_DIR}/"}"
    done

    confirm_destructive_or_abort "Reset this GitOps repository? This cannot be undone."

    for t in "${targets[@]}"; do
        rm -rf "$t"
    done

    print_removed "${targets[@]}"
    print_info "Run 'infra-ctl.sh init' to start fresh."
}

# --- Usage ---

cmd_preflight_check() {
    echo "  infra-ctl.sh dependencies:"
    preflight_check \
        "gum:brew install gum" \
        "gh:brew install gh"
}

usage() {
    cat <<EOF
Usage: infra-ctl.sh <command> [options]

Commands:
  init                  Initialize a GitOps repository skeleton
  add-app <name>        Scaffold a new application across all environments
  add-env <name>        Scaffold a new environment across all applications
  add-project <name>    Create an ArgoCD AppProject
  edit-project [name]   Modify an existing ArgoCD AppProject
  list-apps             List all applications
  list-envs             List all environments
  list-projects         List all ArgoCD AppProjects
  add-ingress [app]       Add an Ingress resource to an application
  list-ingress            List all Ingress resources
  remove-ingress [app]    Remove an Ingress resource from an application
  remove-app [name]     Remove an application and all its resources
  remove-env [name]     Remove an environment and all its resources
  remove-project [name] Remove an ArgoCD AppProject
  enable-kargo          Enable Kargo and generate resources for existing apps
  reset                 Remove all generated files (inverse of init)
  preflight-check       Verify all required tools are installed
$(print_global_options)
EOF
}

# --- Main ---

main() {
    parse_global_args "$@"
    set -- ${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}

    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi

    local command="$1"
    shift

    case "$command" in
        init) cmd_init "$@" ;;
        add-app) cmd_add_app "$@" ;;
        add-env) cmd_add_env "$@" ;;
        add-project) cmd_add_project "$@" ;;
        edit-project) cmd_edit_project "$@" ;;
        list-apps) cmd_list_apps "$@" ;;
        list-envs) cmd_list_envs "$@" ;;
        list-projects) cmd_list_projects "$@" ;;
        add-ingress) cmd_add_ingress "$@" ;;
        list-ingress) cmd_list_ingress ;;
        remove-ingress) cmd_remove_ingress "$@" ;;
        remove-app) cmd_remove_app "$@" ;;
        remove-env) cmd_remove_env "$@" ;;
        remove-project) cmd_remove_project "$@" ;;
        enable-kargo) cmd_enable_kargo "$@" ;;
        reset) cmd_reset "$@" ;;
        preflight-check) cmd_preflight_check "$@" ;;
        -h | --help) usage ;;
        *)
            print_error "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

main "$@"
