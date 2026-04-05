#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib/common.sh"

# --- Commands ---

cmd_init() {
    require_gum
    require_cmd "kubectl" "brew install kubectl"
    require_cmd "kubeseal" "brew install kubeseal"

    local restore_flag=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --restore-key)
                restore_flag="true"
                shift
                ;;
            --no-restore-key)
                restore_flag="false"
                shift
                ;;
            -h | --help)
                echo "Usage: secret-ctl.sh init [--restore-key | --no-restore-key]"
                exit 0
                ;;
            -*)
                print_error "Unknown flag: $1"
                exit 1
                ;;
            *)
                print_error "Unexpected: $1"
                exit 1
                ;;
        esac
    done

    print_header "Initialize Sealed Secrets"

    local key_backup="${TARGET_DIR}/.sealed-secrets-key.json"
    local cert_file="${TARGET_DIR}/.sealed-secrets-cert.pem"

    # If a key backup exists, offer to restore it
    if [[ -f "$key_backup" ]]; then
        print_info "Found existing key backup at .sealed-secrets-key.json"
        local restore="no"
        if [[ "$restore_flag" == "true" ]]; then
            restore="yes"
        elif [[ "$restore_flag" == "false" ]]; then
            restore="no"
        elif [[ -t 0 ]]; then
            gum confirm "Restore this key into the cluster? (keeps existing SealedSecrets decryptable)" && restore="yes"
        fi
        if [[ "$restore" == "yes" ]]; then
            run_cmd "Restoring sealed-secrets key..." \
                --explain "Restoring a previously-backed-up encryption key lets the controller decrypt SealedSecrets that were encrypted with the old key. Without it, you'd need to re-encrypt all secrets." \
                kubectl apply -f "$key_backup"

            print_success "Key restored from backup."
        fi
    fi

    # Install the Sealed Secrets controller
    local manifest_url="https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.3/controller.yaml"

    run_cmd "Installing Sealed Secrets controller..." \
        --explain "The controller runs in-cluster, watches for SealedSecret custom resources, and decrypts them into regular Secrets using its private key. Only the controller can decrypt; the private key never leaves the cluster." \
        kubectl apply -f "$manifest_url"

    if run_cmd "Waiting for Sealed Secrets controller to be ready..." \
        --explain "The controller registers a validating webhook on startup. Until the webhook is registered, kubeseal commands will fail. Waiting ensures the controller is ready to accept seal/unseal requests." \
        kubectl wait --for=condition=available deployment/sealed-secrets-controller \
        -n kube-system --timeout=90s; then
        print_success "Sealed Secrets controller is ready."
    else
        print_warning "Controller not ready yet. It may need a moment to stabilize."
        print_info "  kubectl get pods -n kube-system -l name=sealed-secrets-controller"
    fi

    # Export the public cert for offline encryption
    run_cmd_sh "Exporting public cert..." \
        --explain "Sealed Secrets uses asymmetric encryption. The public certificate (committed to Git) encrypts secrets locally -- anyone with it can encrypt. Only the controller's private key (in-cluster) can decrypt. This allows developers to encrypt secrets without cluster access." \
        "kubeseal --fetch-cert --controller-name=sealed-secrets-controller --controller-namespace=kube-system >\"$cert_file\""

    print_success "Public cert saved to .sealed-secrets-cert.pem (commit this file)."

    # Back up the private key
    kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key \
        -o json >"$key_backup"

    print_success "Private key backed up to .sealed-secrets-key.json (gitignored)."

    # Add key backup to .gitignore (idempotent)
    local gitignore="${TARGET_DIR}/.gitignore"
    if [[ ! -f "$gitignore" ]] || ! grep -qF '.sealed-secrets-key.json' "$gitignore"; then
        echo '.sealed-secrets-key.json' >>"$gitignore"
        print_success "Added .sealed-secrets-key.json to .gitignore"
    fi

    print_header "Sealed Secrets Ready"
    print_info "Encrypt secrets with: secret-ctl.sh add <app> <env>"
    print_info "Public cert: .sealed-secrets-cert.pem (safe to commit)"
    print_info "Key backup:  .sealed-secrets-key.json (gitignored)"
}

cmd_add() {
    require_gum
    require_cmd "kubeseal" "brew install kubeseal"
    require_cmd "jq" "brew install jq"

    local app_flag="" env_flag="" overwrite_flag=""
    local secret_val_entries=()
    local cli_positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app)
                require_flag_value "--app" "${2:-}"
                app_flag="$2"
                shift 2
                ;;
            --env)
                require_flag_value "--env" "${2:-}"
                env_flag="$2"
                shift 2
                ;;
            --secret-val)
                require_flag_value "--secret-val" "${2:-}"
                secret_val_entries+=("$2")
                shift 2
                ;;
            --overwrite)
                overwrite_flag="true"
                shift
                ;;
            --no-overwrite)
                overwrite_flag="false"
                shift
                ;;
            -h | --help)
                echo "Usage: secret-ctl.sh add <app> <env> [--secret-val KEY=VAL]... [--overwrite]"
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

    # Map positional args: first two are app/env, remainder (if any) are
    # legacy KEY=VAL pairs accepted for backward compatibility.
    local app_name="$app_flag"
    local env_name="$env_flag"
    local cli_pairs=("${secret_val_entries[@]}")
    if [[ -z "$app_name" ]] && [[ ${#cli_positional[@]} -gt 0 ]]; then
        app_name="${cli_positional[0]}"
        cli_positional=("${cli_positional[@]:1}")
    fi
    if [[ -z "$env_name" ]] && [[ ${#cli_positional[@]} -gt 0 ]]; then
        env_name="${cli_positional[0]}"
        cli_positional=("${cli_positional[@]:1}")
    fi
    # Any remaining positional are legacy KEY=VAL pairs
    cli_pairs+=("${cli_positional[@]}")

    if [[ -z "$app_name" ]]; then
        load_conf
        if [[ -t 0 ]]; then
            app_name="$(detect_apps | choose_from "Select application:" "No applications found. Run 'infra-ctl.sh add-app' first.")" || exit 0
        else
            print_error "--app is required when not running interactively"
            exit 1
        fi
    fi

    if [[ -z "$env_name" ]]; then
        [[ -z "${REPO_URL:-}" ]] && load_conf
        if [[ -t 0 ]]; then
            env_name="$(detect_envs | choose_from "Select environment:" "No environments found. Run 'infra-ctl.sh add-env' first.")" || exit 0
        else
            print_error "--env is required when not running interactively"
            exit 1
        fi
    fi
    validate_k8s_name "$app_name" "App name"
    validate_k8s_name "$env_name" "Environment name"

    # Validate app exists
    local app_dir="${TARGET_DIR}/k8s/apps/${app_name}"
    if [[ ! -d "$app_dir" ]]; then
        print_error "Application '${app_name}' not found at ${app_dir}"
        print_info "Run 'infra-ctl.sh add-app ${app_name}' to create it first."
        exit 1
    fi

    # Validate env exists
    local ns_file="${TARGET_DIR}/k8s/namespaces/${env_name}.yaml"
    if [[ ! -f "$ns_file" ]]; then
        print_error "Environment '${env_name}' not found at ${ns_file}"
        print_info "Run 'infra-ctl.sh add-env ${env_name}' to create it first."
        exit 1
    fi

    # Validate public cert exists
    local cert_file="${TARGET_DIR}/.sealed-secrets-cert.pem"
    if [[ ! -f "$cert_file" ]]; then
        print_error "No public cert found at .sealed-secrets-cert.pem"
        print_info "Run 'secret-ctl.sh init' to install Sealed Secrets first."
        exit 1
    fi

    local overlay_dir="${app_dir}/overlays/${env_name}"
    local sealed_file="${overlay_dir}/sealed-secret.yaml"

    print_header "Add Secrets: ${app_name} / ${env_name}"

    # Show existing keys if sealed-secret.yaml already exists
    if [[ -f "$sealed_file" ]]; then
        print_info "Existing sealed secret found. New keys will be merged."

        # Extract existing encrypted keys from the encryptedData section only
        local existing_keys
        existing_keys="$(awk '/^  encryptedData:/{found=1; next} found && /^  [a-zA-Z]/{found=0} found && /^    [a-zA-Z_]/{print}' "$sealed_file" \
            | sed 's/^\s*//' | cut -d: -f1 | sort -u)" || true

        if [[ -n "$existing_keys" ]]; then
            print_info "Existing keys: $(echo "$existing_keys" | tr '\n' ' ')"
        fi
    fi

    # Collect key/value pairs from CLI args or interactive prompt
    local keys=()
    local values=()

    if [[ ${#cli_pairs[@]} -gt 0 ]]; then
        # Parse KEY=value pairs (inline, @file, or - stdin)
        local pair
        for pair in "${cli_pairs[@]}"; do
            if [[ "$pair" != *"="* ]]; then
                print_error "Invalid argument '${pair}'. Expected KEY=value format."
                exit 1
            fi
            local key="${pair%%=*}"
            local value="${pair#*=}"
            if [[ "$value" == "-" ]]; then
                value="$(cat)"
            elif [[ "$value" == @* ]]; then
                local file="${value#@}"
                if [[ ! -f "$file" ]]; then
                    print_error "File not found: ${file}"
                    exit 1
                fi
                value="$(cat "$file")"
            fi
            validate_secret_key "$key"

            # Overwrite check
            if [[ -f "$sealed_file" ]] && grep -q "^\s*${key}:" "$sealed_file"; then
                if [[ "$overwrite_flag" == "true" ]]; then
                    : # allow
                elif [[ "$overwrite_flag" == "false" ]]; then
                    print_info "Skipping existing key '${key}' (--no-overwrite)"
                    continue
                elif [[ -t 0 ]]; then
                    if ! gum confirm "Key '${key}' already exists. Overwrite?"; then
                        continue
                    fi
                else
                    print_error "Key '${key}' already exists. Pass --overwrite or --no-overwrite"
                    exit 1
                fi
            fi
            keys+=("$key")
            values+=("$value")
            print_info "Secret: ${key}"
        done
    elif [[ -t 0 ]]; then
        # Interactive prompt
        while true; do
            local key
            key="$(gum input --prompt "Secret key (empty to finish): " --placeholder "e.g. DATABASE_URL")"

            if [[ -z "$key" ]]; then
                break
            fi

            validate_secret_key "$key"

            # Warn if key exists in current sealed secret
            if [[ -f "$sealed_file" ]] && grep -q "^\s*${key}:" "$sealed_file"; then
                if ! gum confirm "Key '${key}' already exists. Overwrite?"; then
                    continue
                fi
            fi

            local value
            value="$(gum input --prompt "Value for ${key}: " --password)"

            keys+=("$key")
            values+=("$value")
            print_success "Added: ${key}"
        done
    else
        print_error "--secret-val KEY=VAL is required when not running interactively (repeat for multiple keys)"
        exit 1
    fi

    if [[ ${#keys[@]} -eq 0 ]]; then
        print_warning "No secrets entered. Aborted."
        exit 0
    fi

    # Build the secret JSON using jq for safe escaping of keys and values
    local data_json="{}"
    local i
    for i in "${!keys[@]}"; do
        data_json="$(printf '%s' "$data_json" | jq --arg k "${keys[$i]}" --arg v "${values[$i]}" '. + {($k): $v}')"
    done

    local secret_json
    local secret_name="${app_name}-secrets"
    secret_json="$(jq -n --arg name "$secret_name" --arg ns "$env_name" --argjson data "$data_json" \
        '{"apiVersion":"v1","kind":"Secret","metadata":{"name":$name,"namespace":$ns},"type":"Opaque","stringData":$data}')"

    if [[ -f "$sealed_file" ]]; then
        print_info "Merging with existing sealed secret..."
    fi

    # Attempt merge-into if the file already exists; fall back to fresh seal otherwise
    if [[ -f "$sealed_file" ]]; then
        printf '%s' "$secret_json" | kubeseal \
            --cert "$cert_file" \
            --format yaml \
            --merge-into "$sealed_file"
    else
        mkdir -p "$overlay_dir"
        printf '%s' "$secret_json" | kubeseal \
            --cert "$cert_file" \
            --format yaml >"$sealed_file"
    fi

    print_success "SealedSecret written to ${sealed_file}"

    # Add sealed-secret.yaml to overlay kustomization.yaml if not already present
    local kustomization="${overlay_dir}/kustomization.yaml"
    if [[ -f "$kustomization" ]] && ! grep -qF 'sealed-secret.yaml' "$kustomization"; then
        local tmp_kust
        tmp_kust="$(mktemp)"
        awk '/^resources:/{print; print "  - sealed-secret.yaml"; next} {print}' \
            "$kustomization" >"$tmp_kust" && mv "$tmp_kust" "$kustomization"
        print_success "Added sealed-secret.yaml to overlay kustomization.yaml"
    fi

    print_summary "$sealed_file"
}

cmd_list() {
    require_gum

    local filter_app="${1:-}"
    local filter_env="${2:-}"

    print_header "Sealed Secrets"

    local apps_dir="${TARGET_DIR}/k8s/apps"
    if [[ ! -d "$apps_dir" ]]; then
        print_warning "No applications found."
        exit 0
    fi

    local found=false
    local app_dir
    for app_dir in "$apps_dir"/*/; do
        [[ -d "$app_dir" ]] || continue
        local app_name
        app_name="$(basename "$app_dir")"

        # Filter by app if specified
        if [[ -n "$filter_app" && "$app_name" != "$filter_app" ]]; then
            continue
        fi

        local overlays_dir="${app_dir}overlays"
        [[ -d "$overlays_dir" ]] || continue

        local env_dir
        for env_dir in "$overlays_dir"/*/; do
            [[ -d "$env_dir" ]] || continue
            local env_name
            env_name="$(basename "$env_dir")"

            # Filter by env if specified
            if [[ -n "$filter_env" && "$env_name" != "$filter_env" ]]; then
                continue
            fi

            local sealed_file="${env_dir}sealed-secret.yaml"
            if [[ -f "$sealed_file" ]]; then
                found=true
                # Count the encrypted keys
                local key_count
                key_count="$(awk '/^  encryptedData:/{found=1; next} found && /^  [a-zA-Z]/{found=0} found && /^    [a-zA-Z_]/{c++} END{print c+0}' "$sealed_file" 2>/dev/null)" || key_count=0
                print_info "${app_name} / ${env_name}  (${key_count} keys)"
            fi
        done
    done

    if [[ "$found" == false ]]; then
        print_warning "No sealed secrets found."
    fi
}

cmd_remove() {
    require_gum

    local app_flag="" env_flag="" yes="false"
    local cli_positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app)
                require_flag_value "--app" "${2:-}"
                app_flag="$2"
                shift 2
                ;;
            --env)
                require_flag_value "--env" "${2:-}"
                env_flag="$2"
                shift 2
                ;;
            --yes | -y)
                yes="true"
                shift
                ;;
            -h | --help)
                echo "Usage: secret-ctl.sh remove <app> <env> [--yes]"
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
    if [[ -z "$app_name" ]] && [[ ${#cli_positional[@]} -gt 0 ]]; then
        app_name="${cli_positional[0]}"
    fi
    if [[ -z "$env_name" ]] && [[ ${#cli_positional[@]} -gt 1 ]]; then
        env_name="${cli_positional[1]}"
    fi

    load_conf

    # Interactive selection if args not provided
    if [[ -z "$app_name" ]]; then
        if [[ -t 0 ]]; then
            app_name="$(detect_apps | choose_from "Select application:" "No applications found.")" || exit 0
        else
            print_error "--app is required when not running interactively"
            exit 1
        fi
    fi

    if [[ -z "$env_name" ]]; then
        # Only show envs that have a sealed secret for this app
        local available_envs=()
        local overlay_dir="${TARGET_DIR}/k8s/apps/${app_name}/overlays"
        if [[ -d "$overlay_dir" ]]; then
            local d
            for d in "$overlay_dir"/*/; do
                [[ -d "$d" ]] || continue
                [[ -f "${d}sealed-secret.yaml" ]] || continue
                available_envs+=("$(basename "$d")")
            done
        fi
        if [[ -t 0 ]]; then
            env_name="$(printf '%s\n' "${available_envs[@]}" | choose_from "Select environment:" "No sealed secrets found for '${app_name}'.")" || exit 0
        else
            print_error "--env is required when not running interactively"
            exit 1
        fi
    fi

    validate_k8s_name "$app_name" "App name"
    validate_k8s_name "$env_name" "Environment name"

    local sealed_file="${TARGET_DIR}/k8s/apps/${app_name}/overlays/${env_name}/sealed-secret.yaml"
    if [[ ! -f "$sealed_file" ]]; then
        print_error "No sealed secret found at ${sealed_file}"
        exit 1
    fi

    print_header "Remove Sealed Secret: ${app_name} / ${env_name}"
    print_info "Delete file: ${sealed_file}"

    require_yes "$yes" "remove sealed secret for '${app_name}' in '${env_name}'"

    rm -f "$sealed_file"

    # Remove sealed-secret.yaml reference from kustomization.yaml
    local kustomization="${TARGET_DIR}/k8s/apps/${app_name}/overlays/${env_name}/kustomization.yaml"
    if [[ -f "$kustomization" ]] && grep -qF 'sealed-secret.yaml' "$kustomization"; then
        local tmp
        tmp="$(grep -vF '  - sealed-secret.yaml' "$kustomization")"
        printf '%s\n' "$tmp" >"$kustomization"
        print_success "Removed sealed-secret.yaml from overlay kustomization.yaml"
    fi

    print_removed "$sealed_file"
}

# --- Usage ---

cmd_verify() {
    require_gum
    require_yq
    load_conf

    local env_flag="" walk_flag=""
    local cli_positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --env)
                require_flag_value "--env" "${2:-}"
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
                echo "Usage: secret-ctl.sh verify [env] [--walk | --no-walk]"
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
            env_name="$(detect_envs | choose_from "Select environment:" "No environments found.")" || exit 0
        else
            print_error "--env is required when not running interactively"
            exit 1
        fi
    fi

    print_header "Verifying secrets for environment: ${env_name}"

    local missing_count=0
    local app_dir
    for app_dir in "${TARGET_DIR}/k8s/apps"/*/; do
        [[ -d "$app_dir" ]] || continue
        local app_name
        app_name="$(basename "$app_dir")"

        # Find all secretKeyRef entries in workload manifests
        local workload_file
        for workload_file in "${app_dir}base/"*.yaml; do
            [[ -f "$workload_file" ]] || continue

            # Extract secret name + key pairs using yq
            local refs
            refs="$(yq eval '
                .. | select(has("secretKeyRef")) | .secretKeyRef |
                .name + "=" + .key
            ' "$workload_file" 2>/dev/null)" || continue

            [[ -z "$refs" ]] && continue

            # Check each reference
            while IFS= read -r ref; do
                [[ -z "$ref" ]] && continue
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
            done <<<"$refs"
        done
    done

    if [[ "$missing_count" -eq 0 ]]; then
        print_success "All secret references verified for '${env_name}'."
    else
        print_warning "${missing_count} missing secret(s) found."
        local walk="no"
        if [[ "$walk_flag" == "true" ]]; then
            walk="yes"
        elif [[ "$walk_flag" == "false" ]]; then
            walk="no"
        elif [[ -t 0 ]]; then
            gum confirm "Walk through creating missing secrets now?" && walk="yes"
        fi
        if [[ "$walk" == "yes" ]]; then
            cmd_add "" "$env_name"
        fi
    fi
}

cmd_preflight_check() {
    echo "  secret-ctl.sh dependencies:"
    preflight_check \
        "gum:brew install gum" \
        "kubectl:brew install kubectl" \
        "kubeseal:brew install kubeseal" \
        "jq:brew install jq"
}

usage() {
    cat <<EOF
Usage: secret-ctl.sh <command> [options]

Commands:
  init                Install Sealed Secrets controller and set up key material
  add [app] [env] [KEY=value...]  Create or update a SealedSecret for an app/environment
  list [app] [env]    List app/environment pairs that have sealed secrets
  remove [app] [env]  Remove a SealedSecret for an app/environment
  verify [env]        Check for missing secret references
  preflight-check     Verify all required tools are installed
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
        add) cmd_add "$@" ;;
        list) cmd_list "$@" ;;
        remove) cmd_remove "$@" ;;
        verify) cmd_verify "$@" ;;
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
