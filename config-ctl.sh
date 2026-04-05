#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib/common.sh"

# --- Commands ---

cmd_add() {
    require_gum
    require_yq
    load_conf

    local app_flag="" env_flag=""
    local config_flag_entries=()
    local cli_positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app)
                app_flag="$2"
                shift 2
                ;;
            --env)
                env_flag="$2"
                shift 2
                ;;
            --config)
                config_flag_entries+=("$2")
                shift 2
                ;;
            -h | --help)
                echo "Usage: config-ctl.sh add <app> <env|base> [--config KEY=VAL]..."
                exit 0
                ;;
            -*)
                print_error "Unknown flag: $1"
                exit 1
                ;;
            *)
                cli_positional+=("$1")
                shift
                ;;
        esac
    done

    local app_name="$app_flag"
    local env_name="$env_flag"
    [[ -z "$app_name" ]] && [[ ${#cli_positional[@]} -gt 0 ]] && app_name="${cli_positional[0]}"
    [[ -z "$env_name" ]] && [[ ${#cli_positional[@]} -gt 1 ]] && env_name="${cli_positional[1]}"

    if [[ -z "$app_name" ]]; then
        if [[ -t 0 ]]; then
            app_name="$(detect_apps | choose_from "Select application:" "No applications found. Run 'infra-ctl.sh add-app' first.")" || exit 0
        else
            print_error "--app is required when not running interactively"
            exit 1
        fi
    fi

    if [[ -z "$env_name" ]]; then
        if [[ -t 0 ]]; then
            env_name="$( (
                echo "base"
                detect_envs
            ) | choose_from "Select target:" "No environments found. Run 'infra-ctl.sh add-env' first.")" || exit 0
        else
            print_error "--env is required when not running interactively (use 'base' for base overlay)"
            exit 1
        fi
    fi

    validate_k8s_name "$app_name" "App name"

    local app_dir="${TARGET_DIR}/k8s/apps/${app_name}"
    if [[ ! -d "$app_dir" ]]; then
        print_error "Application '${app_name}' not found at ${app_dir}"
        print_info "Run 'infra-ctl.sh add-app ${app_name}' to create it first."
        exit 1
    fi

    # Resolve kustomization file path
    local kust_file
    if [[ "$env_name" == "base" ]]; then
        kust_file="${app_dir}/base/kustomization.yaml"
    else
        validate_k8s_name "$env_name" "Environment name"
        kust_file="${app_dir}/overlays/${env_name}/kustomization.yaml"
    fi

    if [[ ! -f "$kust_file" ]]; then
        print_error "Kustomization file not found: ${kust_file}"
        exit 1
    fi

    print_header "Add Config: ${app_name} / ${env_name}"

    # Collect KEY=VALUE pairs: flags win, else prompt, else die
    local entries=()
    if [[ ${#config_flag_entries[@]} -gt 0 ]]; then
        local e
        for e in "${config_flag_entries[@]}"; do
            if [[ "$e" != *=* ]]; then
                print_error "--config expects KEY=VAL, got: ${e}"
                exit 1
            fi
            entries+=("$e")
        done
    elif [[ -t 0 ]]; then
        while true; do
            local entry
            entry="$(gum input --prompt "KEY=VALUE (empty to finish): " --placeholder "e.g. LOG_LEVEL=info")"

            if [[ -z "$entry" ]]; then
                break
            fi

            if [[ "$entry" != *=* ]]; then
                print_warning "Invalid format. Use KEY=VALUE (e.g. LOG_LEVEL=info)."
                continue
            fi

            entries+=("$entry")
            print_success "Added: ${entry}"
        done
    else
        print_error "--config KEY=VAL is required when not running interactively (repeat for multiple)"
        exit 1
    fi

    if [[ ${#entries[@]} -eq 0 ]]; then
        print_warning "No config values entered. Aborted."
        exit 0
    fi

    # Ensure configMapGenerator exists with at least one entry
    local has_cmg
    has_cmg="$(yq eval '.configMapGenerator | length' "$kust_file")"
    if [[ "$has_cmg" == "0" || "$has_cmg" == "null" ]]; then
        APP_NAME="$app_name" yq eval -i '.configMapGenerator = [{"name": env(APP_NAME), "literals": []}]' "$kust_file"
    fi

    # Ensure literals array exists on the first generator
    local has_literals
    has_literals="$(yq eval '.configMapGenerator[0].literals' "$kust_file")"
    if [[ "$has_literals" == "null" ]]; then
        yq eval -i '.configMapGenerator[0].literals = []' "$kust_file"
    fi

    # Append each entry
    local entry
    for entry in "${entries[@]}"; do
        YQ_ENTRY="$entry" yq eval -i '.configMapGenerator[0].literals += [env(YQ_ENTRY)]' "$kust_file"
    done

    # Clean up null/empty entries from literals
    yq eval -i '.configMapGenerator[0].literals |= map(select(. != null and . != ""))' "$kust_file"

    print_success "Config values written to ${kust_file}"
}

cmd_list() {
    require_yq
    load_conf

    local app_name="${1:-}"
    local env_name="${2:-}"

    if [[ -z "$app_name" ]]; then
        require_gum
        app_name="$(detect_apps | choose_from "Select application:" "No applications found.")" || exit 0
    fi

    if [[ -z "$env_name" ]]; then
        require_gum
        env_name="$( (
            echo "base"
            detect_envs
        ) | choose_from "Select target:" "No environments found.")" || exit 0
    fi

    validate_k8s_name "$app_name" "App name"

    local app_dir="${TARGET_DIR}/k8s/apps/${app_name}"
    if [[ ! -d "$app_dir" ]]; then
        print_error "Application '${app_name}' not found at ${app_dir}"
        exit 1
    fi

    if [[ "$env_name" == "base" ]]; then
        local base_kust="${app_dir}/base/kustomization.yaml"
        if [[ ! -f "$base_kust" ]]; then
            print_warning "No kustomization.yaml found at ${base_kust}"
            exit 0
        fi

        print_header "Config: ${app_name} / base"

        local literals
        literals="$(yq eval '.configMapGenerator[0].literals[]' "$base_kust" 2>/dev/null)" || true
        if [[ -z "$literals" ]]; then
            print_info "No config values defined."
        else
            echo "$literals"
        fi
    else
        validate_k8s_name "$env_name" "Environment name"

        print_header "Config: ${app_name} / ${env_name} (merged view)"

        # Build associative arrays for base and overlay
        local -A base_values=()
        local -A overlay_values=()

        local base_kust="${app_dir}/base/kustomization.yaml"
        if [[ -f "$base_kust" ]]; then
            local line
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                local key="${line%%=*}"
                base_values["$key"]="$line"
            done < <(yq eval '.configMapGenerator[0].literals[]' "$base_kust" 2>/dev/null || true)
        fi

        local overlay_kust="${app_dir}/overlays/${env_name}/kustomization.yaml"
        if [[ -f "$overlay_kust" ]]; then
            local line
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                local key="${line%%=*}"
                overlay_values["$key"]="$line"
            done < <(yq eval '.configMapGenerator[0].literals[]' "$overlay_kust" 2>/dev/null || true)
        fi

        # Display merged view: base values first, then overlay-only
        local any_output=false

        # Show base values, marking overrides
        local key
        for key in $(printf '%s\n' "${!base_values[@]}" | sort); do
            any_output=true
            if [[ -n "${overlay_values[$key]+x}" ]]; then
                echo "${overlay_values[$key]}  [override]"
            else
                echo "${base_values[$key]}"
            fi
        done

        # Show overlay-only values
        for key in $(printf '%s\n' "${!overlay_values[@]}" | sort); do
            if [[ -z "${base_values[$key]+x}" ]]; then
                any_output=true
                echo "${overlay_values[$key]}  [overlay-only]"
            fi
        done

        if [[ "$any_output" == false ]]; then
            print_info "No config values defined."
        fi
    fi
}

cmd_remove() {
    require_gum
    require_yq
    load_conf

    local app_flag="" env_flag=""
    local key_flags=()
    local cli_positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app)
                app_flag="$2"
                shift 2
                ;;
            --env)
                env_flag="$2"
                shift 2
                ;;
            --key)
                key_flags+=("$2")
                shift 2
                ;;
            -h | --help)
                echo "Usage: config-ctl.sh remove <app> <env|base> [--key <name>]..."
                exit 0
                ;;
            -*)
                print_error "Unknown flag: $1"
                exit 1
                ;;
            *)
                cli_positional+=("$1")
                shift
                ;;
        esac
    done

    local app_name="$app_flag"
    local env_name="$env_flag"
    [[ -z "$app_name" ]] && [[ ${#cli_positional[@]} -gt 0 ]] && app_name="${cli_positional[0]}"
    [[ -z "$env_name" ]] && [[ ${#cli_positional[@]} -gt 1 ]] && env_name="${cli_positional[1]}"

    if [[ -z "$app_name" ]]; then
        if [[ -t 0 ]]; then
            app_name="$(detect_apps | choose_from "Select application:" "No applications found.")" || exit 0
        else
            print_error "--app is required when not running interactively"
            exit 1
        fi
    fi

    if [[ -z "$env_name" ]]; then
        if [[ -t 0 ]]; then
            env_name="$( (
                echo "base"
                detect_envs
            ) | choose_from "Select target:" "No environments found.")" || exit 0
        else
            print_error "--env is required when not running interactively (use 'base' for base overlay)"
            exit 1
        fi
    fi

    validate_k8s_name "$app_name" "App name"

    local app_dir="${TARGET_DIR}/k8s/apps/${app_name}"

    # Resolve kustomization file path
    local kust_file
    if [[ "$env_name" == "base" ]]; then
        kust_file="${app_dir}/base/kustomization.yaml"
    else
        validate_k8s_name "$env_name" "Environment name"
        kust_file="${app_dir}/overlays/${env_name}/kustomization.yaml"
    fi

    if [[ ! -f "$kust_file" ]]; then
        print_error "Kustomization file not found: ${kust_file}"
        exit 1
    fi

    # Get current literals
    local literals
    literals="$(yq eval '.configMapGenerator[0].literals[]' "$kust_file" 2>/dev/null)" || true
    if [[ -z "$literals" ]]; then
        print_warning "No config values found in ${kust_file}"
        exit 0
    fi

    print_header "Remove Config: ${app_name} / ${env_name}"

    # Which to remove: --key flags (match by KEY prefix), else prompt, else die
    local selected
    if [[ ${#key_flags[@]} -gt 0 ]]; then
        # For each --key NAME, find matching literals (NAME=... or NAME)
        local sel_lines=""
        local k lit
        for k in "${key_flags[@]}"; do
            while IFS= read -r lit; do
                if [[ "$lit" == "$k" || "$lit" == "${k}="* ]]; then
                    sel_lines+="${lit}"$'\n'
                fi
            done <<<"$literals"
        done
        selected="${sel_lines%$'\n'}"
        if [[ -z "$selected" ]]; then
            print_error "No matching literals for keys: ${key_flags[*]}"
            exit 1
        fi
    elif [[ -t 0 ]]; then
        selected="$(echo "$literals" | gum choose --no-limit --header "Select values to remove:")" || exit 0
    else
        print_error "--key is required when not running interactively (repeat for multiple)"
        exit 1
    fi

    if [[ -z "$selected" ]]; then
        print_warning "No values selected. Aborted."
        exit 0
    fi

    # Remove selected entries
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        YQ_ENTRY="$entry" yq eval -i '(.configMapGenerator[0].literals) -= [env(YQ_ENTRY)]' "$kust_file"
        print_success "Removed: ${entry}"
    done <<<"$selected"

    # Clean up empty literals array
    local remaining
    remaining="$(yq eval '.configMapGenerator[0].literals | length' "$kust_file")"
    if [[ "$remaining" == "0" ]]; then
        yq eval -i 'del(.configMapGenerator)' "$kust_file"
        print_info "Removed empty configMapGenerator section."
    fi
}

cmd_verify() {
    require_yq
    load_conf

    local env_flag="" walk_flag=""
    local cli_positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --env)
                env_flag="$2"
                shift 2
                ;;
            --walk)
                walk_flag="true"
                shift
                ;;
            --no-walk)
                walk_flag="false"
                shift
                ;;
            -h | --help)
                echo "Usage: config-ctl.sh verify [env] [--walk | --no-walk]"
                exit 0
                ;;
            -*)
                print_error "Unknown flag: $1"
                exit 1
                ;;
            *)
                cli_positional+=("$1")
                shift
                ;;
        esac
    done

    local env_name="$env_flag"
    [[ -z "$env_name" ]] && [[ ${#cli_positional[@]} -gt 0 ]] && env_name="${cli_positional[0]}"

    if [[ -z "$env_name" ]]; then
        if [[ -t 0 ]]; then
            require_gum
            env_name="$(detect_envs | choose_from "Select environment:" "No environments found.")" || exit 0
        else
            print_error "--env is required when not running interactively"
            exit 1
        fi
    fi

    validate_k8s_name "$env_name" "Environment name"

    print_header "Verify ConfigMap References: ${env_name}"

    local apps_dir="${TARGET_DIR}/k8s/apps"
    if [[ ! -d "$apps_dir" ]]; then
        print_warning "No applications directory found."
        exit 0
    fi

    local missing_count=0
    local app_dir
    for app_dir in "$apps_dir"/*/; do
        [[ -d "$app_dir" ]] || continue
        local app_name
        app_name="$(basename "$app_dir")"

        # Scan workload manifests in base for configMapRef
        local base_dir="${app_dir}base"
        [[ -d "$base_dir" ]] || continue

        local configmap_refs=()
        local yaml_file
        for yaml_file in "$base_dir"/*.yaml; do
            [[ -f "$yaml_file" ]] || continue
            while IFS= read -r ref; do
                [[ -n "$ref" && "$ref" != "null" ]] && configmap_refs+=("$ref")
            done < <(yq eval '.. | select(has("configMapRef")) | .configMapRef.name' "$yaml_file" 2>/dev/null || true)
        done
        # Deduplicate
        local -A seen_refs=()
        local unique_refs=()
        local r
        for r in "${configmap_refs[@]}"; do
            if [[ ! -v "seen_refs[$r]" ]]; then
                seen_refs["$r"]=1
                unique_refs+=("$r")
            fi
        done
        configmap_refs=("${unique_refs[@]}")

        if [[ ${#configmap_refs[@]} -eq 0 ]]; then
            continue
        fi

        # Check if configMapGenerator exists in base or overlay
        local base_kust="${base_dir}/kustomization.yaml"
        local overlay_kust="${app_dir}overlays/${env_name}/kustomization.yaml"

        local base_cmg_names=()
        if [[ -f "$base_kust" ]]; then
            while IFS= read -r name; do
                [[ -n "$name" ]] && base_cmg_names+=("$name")
            done < <(yq eval '.configMapGenerator[].name' "$base_kust" 2>/dev/null || true)
        fi

        local overlay_cmg_names=()
        if [[ -f "$overlay_kust" ]]; then
            while IFS= read -r name; do
                [[ -n "$name" ]] && overlay_cmg_names+=("$name")
            done < <(yq eval '.configMapGenerator[].name' "$overlay_kust" 2>/dev/null || true)
        fi

        local all_cmg_names=("${base_cmg_names[@]}" "${overlay_cmg_names[@]}")

        local ref
        for ref in "${configmap_refs[@]}"; do
            local found=false
            local name
            for name in "${all_cmg_names[@]}"; do
                if [[ "$name" == "$ref" ]]; then
                    found=true
                    break
                fi
            done

            if [[ "$found" == false ]]; then
                print_warning "${app_name}: configMapRef '${ref}' not found in configMapGenerator (base or ${env_name} overlay)"
                missing_count=$((missing_count + 1))
            fi
        done
    done

    if [[ "$missing_count" -eq 0 ]]; then
        print_success "All configMapRef references have matching configMapGenerator entries."
    else
        print_warning "${missing_count} missing configmap(s) found."
        if command -v gum &>/dev/null; then
            local walk="no"
            if [[ "$walk_flag" == "true" ]]; then
                walk="yes"
            elif [[ "$walk_flag" == "false" ]]; then
                walk="no"
            elif [[ -t 0 ]]; then
                gum confirm "Walk through adding missing config values?" && walk="yes"
            fi
            if [[ "$walk" == "yes" ]]; then
                cmd_add
            fi
        fi
    fi
}

# --- Usage ---

usage() {
    cat <<EOF
Usage: config-ctl.sh <command> [options]

Manage configMapGenerator literals in Kustomize configurations.

Commands:
  add [app] [env]         Add config values (KEY=VALUE) to an application
  list [app] [env]        List config values for an application
  remove [app] [env]      Remove config values from an application
  verify [env]            Check for missing config references

Arguments:
  app                     Application name (interactive chooser if omitted)
  env                     Target: 'base' or environment name (chooser if omitted)
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
        add) cmd_add "$@" ;;
        list) cmd_list "$@" ;;
        remove) cmd_remove "$@" ;;
        verify) cmd_verify "$@" ;;
        -h | --help) usage ;;
        *)
            print_error "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

main "$@"
