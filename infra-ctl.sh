#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib/common.sh"

# --- Commands ---

cmd_init() {
    require_gum

    # Idempotency guard
    if [[ -d "${TARGET_DIR}/argocd" || -d "${TARGET_DIR}/k8s" ]]; then
        print_error "Repository already initialized (argocd/ or k8s/ exists in ${TARGET_DIR})."
        echo "  If you want to re-initialize, remove these directories first." >&2
        exit 1
    fi

    print_header "Initialize GitOps Repository"
    echo ""

    # Prompt for repo URL
    local repo_url
    repo_url="$(gum input --placeholder "https://github.com/owner/repo" --prompt "Repository URL: ")"

    if [[ -z "$repo_url" ]]; then
        print_error "Repository URL is required."
        exit 1
    fi

    # Extract and confirm owner
    local repo_owner
    repo_owner="$(extract_repo_owner "$repo_url")"
    print_info "Detected repo owner: ${repo_owner}"
    echo ""

    if ! gum confirm "Proceed with repo URL '${repo_url}' and owner '${repo_owner}'?"; then
        print_warning "Aborted."
        exit 0
    fi

    local created_files=()

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

    # Save configuration
    save_conf "$repo_url" "$repo_owner"
    created_files+=("${TARGET_DIR}/.infra-ctl.conf")

    print_summary "${created_files[@]}"
    print_info "Repository initialized. Next steps:"
    print_info "  1. (Optional) Add a project:  infra-ctl.sh add-project <name>"
    print_info "  2. Add an environment:        infra-ctl.sh add-env <env-name>"
    print_info "  3. Add an application:         infra-ctl.sh add-app <app-name>"
}

cmd_add_app() {
    require_gum

    if [[ $# -eq 0 ]]; then
        print_error "Usage: infra-ctl.sh add-app <app-name>"
        exit 1
    fi

    local app_name="$1"
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

    # Project selection
    local project="default"
    if [[ ${#projects[@]} -gt 0 ]]; then
        print_header "Select project for '${app_name}'"
        project="$(printf "%s\n" "default" "${projects[@]}" | gum choose)"
    fi

    # Workload type selection (Deployment is default, listed first)
    local workload_type
    workload_type="$(printf "Deployment\nStatefulSet" | gum choose)"

    # Container port
    local port
    port="$(gum input --value "8080" --prompt "Container port: ")"

    # Preview what will be created
    print_header "Add Application: ${app_name}"
    echo ""
    print_info "Project: ${project}"
    print_info "Workload: ${workload_type}"
    print_info "Port: ${port}"
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
    echo ""

    if ! gum confirm "Create these files?"; then
        print_warning "Aborted."
        exit 0
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
                "ENV=${env}" \
                "REPO_OWNER=${REPO_OWNER}"; then
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

    print_summary "${created_files[@]}"
}

cmd_add_env() {
    require_gum

    if [[ $# -eq 0 ]]; then
        print_error "Usage: infra-ctl.sh add-env <env-name>"
        exit 1
    fi

    local env_name="$1"
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
    echo ""
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
    echo ""

    if ! gum confirm "Create these files?"; then
        print_warning "Aborted."
        exit 0
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
                "ENV=${env_name}" \
                "REPO_OWNER=${REPO_OWNER}"; then
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

    print_summary "${created_files[@]}"
}

cmd_add_project() {
    require_gum

    if [[ $# -eq 0 ]]; then
        print_error "Usage: infra-ctl.sh add-project <project-name>"
        exit 1
    fi

    local project_name="$1"
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
    echo ""

    # Prompt for description
    local description
    description="$(gum input --placeholder "What does this project scope?" --prompt "Description: ")"

    # Prompt for source repo restrictions
    local source_repos_block
    if gum confirm "Restrict source repositories?"; then
        local repos_input
        repos_input="$(gum input --value "${REPO_URL}" --prompt "Allowed repos (comma-separated): ")"
        source_repos_block=""
        IFS=',' read -ra repos <<< "$repos_input"
        local repo
        for repo in "${repos[@]}"; do
            repo="$(echo "$repo" | xargs)"  # trim whitespace
            source_repos_block+="    - ${repo}"$'\n'
        done
        # Remove trailing newline
        source_repos_block="${source_repos_block%$'\n'}"
    else
        source_repos_block="    - '*'"
    fi

    # Prompt for destination namespace restrictions
    local destinations_block
    if gum confirm "Restrict destination namespaces?"; then
        local envs=()
        while IFS= read -r env; do
            envs+=("$env")
        done < <(detect_envs)

        local selected_namespaces
        if [[ ${#envs[@]} -gt 0 ]]; then
            selected_namespaces="$(printf "%s\n" "${envs[@]}" | gum choose --no-limit)"
        else
            selected_namespaces="$(gum input --placeholder "dev, staging, prod" --prompt "Allowed namespaces (comma-separated): ")"
            # Convert comma-separated to newline-separated
            selected_namespaces="$(echo "$selected_namespaces" | tr ',' '\n' | xargs -I{} echo {})"
        fi

        destinations_block=""
        while IFS= read -r ns; do
            ns="$(echo "$ns" | xargs)"
            [[ -z "$ns" ]] && continue
            destinations_block+="    - namespace: ${ns}"$'\n'
            destinations_block+="      server: https://kubernetes.default.svc"$'\n'
        done <<< "$selected_namespaces"
        destinations_block="${destinations_block%$'\n'}"
    else
        destinations_block="    - namespace: '*'"$'\n'
        destinations_block+="      server: https://kubernetes.default.svc"
    fi

    # Render template
    render_template \
        "${TEMPLATE_DIR}/argocd/appproject.yaml" \
        "$project_file" \
        "PROJECT_NAME=${project_name}" \
        "PROJECT_DESCRIPTION=${description}" \
        "SOURCE_REPOS=${source_repos_block}" \
        "DESTINATIONS=${destinations_block}"

    # Remove .gitkeep from projects dir if it exists
    rm -f "${TARGET_DIR}/argocd/projects/.gitkeep"

    print_summary "$project_file"
}

cmd_edit_project() {
    require_gum

    if [[ $# -eq 0 ]]; then
        print_error "Usage: infra-ctl.sh edit-project <project-name>"
        exit 1
    fi

    local project_name="$1"
    load_conf

    local project_file="${TARGET_DIR}/argocd/projects/${project_name}.yaml"
    if [[ ! -f "$project_file" ]]; then
        print_error "Project '${project_name}' not found at ${project_file}"
        exit 1
    fi

    print_header "Edit Project: ${project_name}"
    echo ""

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

    # Prompt for description
    local description
    description="$(gum input --value "$current_description" --prompt "Description: ")"

    # Prompt for source repo restrictions
    local source_repos_block
    local confirm_msg="Restrict source repositories?"
    if [[ "$current_repos_restricted" == true ]]; then
        confirm_msg="Restrict source repositories? (currently restricted)"
    fi
    if gum confirm "$confirm_msg"; then
        local current_repos=""
        if [[ "$current_repos_restricted" == true ]]; then
            current_repos="$(awk '/sourceRepos:/,/destinations:/{if(/- / && !/sourceRepos:/ && !/destinations:/) print}' "$project_file" | sed 's/.*- //' | tr '\n' ',' | sed 's/,$//')"
        else
            current_repos="${REPO_URL}"
        fi
        local repos_input
        repos_input="$(gum input --value "$current_repos" --prompt "Allowed repos (comma-separated): ")"
        source_repos_block=""
        IFS=',' read -ra repos <<< "$repos_input"
        local repo
        for repo in "${repos[@]}"; do
            repo="$(echo "$repo" | xargs)"
            source_repos_block+="    - ${repo}"$'\n'
        done
        source_repos_block="${source_repos_block%$'\n'}"
    else
        source_repos_block="    - '*'"
    fi

    # Prompt for destination namespace restrictions
    local destinations_block
    confirm_msg="Restrict destination namespaces?"
    if [[ "$current_ns_restricted" == true ]]; then
        confirm_msg="Restrict destination namespaces? (currently restricted)"
    fi
    if gum confirm "$confirm_msg"; then
        local envs=()
        while IFS= read -r env; do
            envs+=("$env")
        done < <(detect_envs)

        local selected_namespaces
        if [[ ${#envs[@]} -gt 0 ]]; then
            selected_namespaces="$(printf "%s\n" "${envs[@]}" | gum choose --no-limit)"
        else
            selected_namespaces="$(gum input --placeholder "dev, staging, prod" --prompt "Allowed namespaces (comma-separated): ")"
            selected_namespaces="$(echo "$selected_namespaces" | tr ',' '\n' | xargs -I{} echo {})"
        fi

        destinations_block=""
        while IFS= read -r ns; do
            ns="$(echo "$ns" | xargs)"
            [[ -z "$ns" ]] && continue
            destinations_block+="    - namespace: ${ns}"$'\n'
            destinations_block+="      server: https://kubernetes.default.svc"$'\n'
        done <<< "$selected_namespaces"
        destinations_block="${destinations_block%$'\n'}"
    else
        destinations_block="    - namespace: '*'"$'\n'
        destinations_block+="      server: https://kubernetes.default.svc"
    fi

    # Regenerate from template
    render_template \
        "${TEMPLATE_DIR}/argocd/appproject.yaml" \
        "$project_file" \
        "PROJECT_NAME=${project_name}" \
        "PROJECT_DESCRIPTION=${description}" \
        "SOURCE_REPOS=${source_repos_block}" \
        "DESTINATIONS=${destinations_block}"

    print_success "Project '${project_name}' updated."
    echo ""
}

# --- Usage ---

usage() {
    cat <<EOF
Usage: infra-ctl.sh <command> [options]

Commands:
  init                  Initialize a GitOps repository skeleton
  add-app <name>        Scaffold a new application across all environments
  add-env <name>        Scaffold a new environment across all applications
  add-project <name>    Create an ArgoCD AppProject
  edit-project <name>   Modify an existing ArgoCD AppProject

Global options:
  --target-dir <path>   Directory to operate on (default: current directory)
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
        init)       cmd_init "$@" ;;
        add-app)    cmd_add_app "$@" ;;
        add-env)    cmd_add_env "$@" ;;
        add-project)    cmd_add_project "$@" ;;
        edit-project)   cmd_edit_project "$@" ;;
        -h|--help)  usage ;;
        *)
            print_error "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

main "$@"
