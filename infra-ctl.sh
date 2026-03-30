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
