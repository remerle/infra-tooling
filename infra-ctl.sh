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

    # Detect repo URL from git remote, prompt with it as default.
    # Convert SSH URLs to HTTPS since ArgoCD uses HTTPS for repo access.
    local default_url=""
    if git -C "$TARGET_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
        default_url="$(git -C "$TARGET_DIR" remote get-url origin 2>/dev/null || true)"
        if [[ "$default_url" =~ ^git@github\.com:(.+)$ ]]; then
            default_url="https://github.com/${BASH_REMATCH[1]}"
        fi
    fi

    local repo_url
    repo_url="$(gum input --value "$default_url" --placeholder "https://github.com/owner/repo" --prompt "Repository URL: ")"

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

    # Create Kargo promotion order file if enabled (empty initially;
    # add-env populates it as environments are created, sorted by convention)
    if is_kargo_enabled; then
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

    # Save configuration
    save_conf "$repo_url" "$repo_owner"
    created_files+=("${TARGET_DIR}/.infra-ctl.conf")

    # Detect Kargo in the cluster and enable it in the conf.
    # This covers the case where cluster-ctl installed Kargo before init ran
    # (so the conf file didn't exist yet when the flag would have been written).
    if kubectl get namespace kargo &>/dev/null 2>&1; then
        local conf_file="${TARGET_DIR}/.infra-ctl.conf"
        if ! grep -q '^KARGO_ENABLED=true' "$conf_file"; then
            echo "KARGO_ENABLED=true" >>"$conf_file"
            print_info "Detected Kargo in cluster, enabled in .infra-ctl.conf"
        fi
    fi

    print_summary "${created_files[@]}"
    print_info "Repository initialized. Next steps:"
    print_info "  1. Add environments and apps:    infra-ctl.sh add-env / add-app"
    print_info "  2. (Optional) Add a project:     infra-ctl.sh add-project <name>"
    print_info "  3. If your repo is private:      cluster-ctl.sh add-repo-creds"
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
    if is_kargo_enabled; then
        print_info "Kargo:   kargo/${app_name}/project.yaml"
        print_info "Kargo:   kargo/${app_name}/warehouse.yaml"
        if [[ ${#envs[@]} -gt 0 ]]; then
            local env
            for env in "${envs[@]}"; do
                print_info "Kargo:   kargo/${app_name}/${env}-stage.yaml"
            done
        fi
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

    # Generate Kargo resources if enabled
    if is_kargo_enabled; then
        # Prompt for container image
        local image_repo
        image_repo="$(gum input --value "ghcr.io/${REPO_OWNER}/${app_name}" --header "Container image for Kargo:")"

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

    if is_kargo_enabled && [[ -d "${TARGET_DIR}/kargo/${app_name}" ]]; then
        print_info "If your repo or registry is private, configure credentials:"
        print_info "  cluster-ctl.sh add-kargo-creds"
    fi
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

        echo ""
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
        IFS=',' read -ra repos <<<"$repos_input"
        local repo
        for repo in "${repos[@]}"; do
            repo="$(echo "$repo" | xargs)" # trim whitespace
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
        done <<<"$selected_namespaces"
        destinations_block="${destinations_block%$'\n'}"
    else
        destinations_block="    - namespace: '*'"$'\n'
        destinations_block+="      server: https://kubernetes.default.svc"
    fi

    # Prompt for cluster-scoped resource access
    local cluster_resources_block
    if gum confirm "Allow full cluster-scoped resource access? (Namespaces, ClusterRoles, CRDs, etc.)"; then
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

    local project_name="${1:-}"

    if [[ -z "$project_name" ]]; then
        load_conf
        local projects=()
        while IFS= read -r proj; do
            projects+=("$proj")
        done < <(detect_projects)
        if [[ ${#projects[@]} -eq 0 ]]; then
            print_warning "No projects to edit."
            exit 0
        fi
        project_name="$(printf '%s\n' "${projects[@]}" | gum choose --header "Select project to edit:")"
    fi

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
        IFS=',' read -ra repos <<<"$repos_input"
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
        done <<<"$selected_namespaces"
        destinations_block="${destinations_block%$'\n'}"
    else
        destinations_block="    - namespace: '*'"$'\n'
        destinations_block+="      server: https://kubernetes.default.svc"
    fi

    # Prompt for cluster-scoped resource access
    local current_cluster_restricted=false
    if ! grep -q "clusterResourceWhitelist:" "$project_file" || ! grep -A1 "clusterResourceWhitelist:" "$project_file" | grep -q "group: '\*'"; then
        current_cluster_restricted=true
    fi

    local cluster_resources_block
    confirm_msg="Allow full cluster-scoped resource access? (Namespaces, ClusterRoles, CRDs, etc.)"
    if [[ "$current_cluster_restricted" == true ]]; then
        confirm_msg="Allow full cluster-scoped resource access? (currently restricted)"
    fi
    if gum confirm "$confirm_msg"; then
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
    echo ""
}

cmd_enable_kargo() {
    require_gum
    load_conf

    if is_kargo_enabled; then
        print_warning "Kargo is already enabled in .infra-ctl.conf"
        exit 0
    fi

    print_header "Enable Kargo"
    echo ""

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
        echo ""

        if ! gum confirm "Use this order? (Edit kargo/promotion-order.txt after to change)"; then
            print_warning "Aborted. Set KARGO_ENABLED=false in .infra-ctl.conf to disable."
            exit 0
        fi
    else
        mkdir -p "${TARGET_DIR}/kargo"
        touch "${TARGET_DIR}/kargo/promotion-order.txt"
        print_info "No environments detected. Promotion order will be built as you add environments."
    fi
    rm -f "${TARGET_DIR}/kargo/.gitkeep"
    print_success "Created kargo/promotion-order.txt"

    local created_files=("$promo_file")

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

            # Prompt for image repo per app
            local image_repo
            image_repo="$(gum input --value "ghcr.io/${REPO_OWNER}/${app}" --header "Container image for ${app}:")"

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
    echo ""

    local apps=()
    while IFS= read -r app; do
        apps+=("$app")
    done < <(detect_apps)

    if [[ ${#apps[@]} -eq 0 ]]; then
        print_warning "No applications found."
        echo ""
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
    echo ""
}

cmd_list_envs() {
    require_gum
    load_conf

    print_header "Environments"
    echo ""

    local envs=()
    while IFS= read -r env; do
        envs+=("$env")
    done < <(detect_envs)

    if [[ ${#envs[@]} -eq 0 ]]; then
        print_warning "No environments found."
        echo ""
        return
    fi

    local env
    for env in "${envs[@]}"; do
        print_info "${env}"
    done

    if is_kargo_enabled && [[ -f "${TARGET_DIR}/kargo/promotion-order.txt" ]]; then
        read_promotion_order
        echo ""
        print_info "Promotion order: ${PROMOTION_ORDER[*]}"
    fi
    echo ""
}

cmd_list_projects() {
    require_gum
    load_conf

    print_header "Projects"
    echo ""

    local projects=()
    while IFS= read -r proj; do
        projects+=("$proj")
    done < <(detect_projects)

    if [[ ${#projects[@]} -eq 0 ]]; then
        print_warning "No projects found. Apps use the 'default' project."
        echo ""
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
    echo ""
}

cmd_remove_project() {
    require_gum

    local project_name="${1:-}"

    if [[ -z "$project_name" ]]; then
        load_conf
        local projects=()
        while IFS= read -r proj; do
            projects+=("$proj")
        done < <(detect_projects)
        if [[ ${#projects[@]} -eq 0 ]]; then
            print_warning "No projects to remove."
            exit 0
        fi
        project_name="$(printf '%s\n' "${projects[@]}" | gum choose --header "Select project to remove:")"
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
    echo ""
    print_info "Delete file: ${project_file}"

    if [[ ${#assigned_apps[@]} -gt 0 ]]; then
        echo ""
        print_warning "These apps are assigned to project '${project_name}':"
        local app
        for app in "${assigned_apps[@]}"; do
            print_info "  ${app}"
        done
        echo ""

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
    echo ""

    if ! gum confirm "Remove project '${project_name}'?"; then
        print_warning "Aborted."
        exit 0
    fi

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
        local apps=()
        while IFS= read -r app; do
            apps+=("$app")
        done < <(detect_apps)
        if [[ ${#apps[@]} -eq 0 ]]; then
            print_warning "No applications to remove."
            exit 0
        fi
        app_name="$(printf '%s\n' "${apps[@]}" | gum choose --header "Select application to remove:")"
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
    echo ""
    local item
    for item in "${to_remove[@]}"; do
        if [[ -d "$item" ]]; then
            print_info "Delete dir:  ${item}"
        else
            print_info "Delete file: ${item}"
        fi
    done
    echo ""

    if ! gum confirm "Remove application '${app_name}' and all its resources?"; then
        print_warning "Aborted."
        exit 0
    fi

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
        local envs=()
        while IFS= read -r env; do
            envs+=("$env")
        done < <(detect_envs)
        if [[ ${#envs[@]} -eq 0 ]]; then
            print_warning "No environments to remove."
            exit 0
        fi
        env_name="$(printf '%s\n' "${envs[@]}" | gum choose --header "Select environment to remove:")"
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
    echo ""
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
        echo ""
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
    echo ""

    if ! gum confirm "Remove environment '${env_name}' and all its resources?"; then
        print_warning "Aborted."
        exit 0
    fi

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
        echo ""
        print_header "Regenerated (Kargo chain repair):"
        local f
        for f in "${regenerated_files[@]}"; do
            print_success "$f"
        done
        echo ""
    fi
}

# --- Usage ---

cmd_preflight_check() {
    echo ""
    echo "  infra-ctl.sh dependencies:"
    echo ""
    preflight_check \
        "gum:brew install gum"
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
  remove-app [name]     Remove an application and all its resources
  remove-env [name]     Remove an environment and all its resources
  remove-project [name] Remove an ArgoCD AppProject
  enable-kargo          Enable Kargo and generate resources for existing apps
  preflight-check       Verify all required tools are installed

Global options:
  --target-dir <path>   Directory to operate on (default: current directory)
  --show-me             Print commands instead of hiding behind spinners (or set SHOW_ME=1)
  --explain             Print commands with explanations (learning mode, implies --show-me)
  --debug               Show full command output (implies --show-me; or set DEBUG=1)
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
        remove-app) cmd_remove_app "$@" ;;
        remove-env) cmd_remove_env "$@" ;;
        remove-project) cmd_remove_project "$@" ;;
        enable-kargo) cmd_enable_kargo "$@" ;;
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
