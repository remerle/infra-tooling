#compdef infra-ctl.sh cluster-ctl.sh secret-ctl.sh user-ctl.sh

# Shell completions for infra-tooling scripts.
#
# Usage — add one of the following to your .zshrc:
#
#   # If the tooling repo is on your PATH:
#   source /path/to/infra-tooling/completions.zsh
#
#   # Or via fpath (lazy-loaded):
#   fpath=(/path/to/infra-tooling $fpath)
#   autoload -Uz compinit && compinit

# --- Shared helpers for dynamic argument completion ---

# Detect the target directory from --target-dir or default to $PWD.
_infra_target_dir() {
    local i
    for (( i=1; i < ${#words[@]}; i++ )); do
        if [[ "${words[$i]}" == "--target-dir" && -n "${words[$((i+1))]}" ]]; then
            echo "${words[$((i+1))]}"
            return
        fi
    done
    echo "$PWD"
}

_infra_complete_apps() {
    local target_dir="$(_infra_target_dir)"
    local apps_dir="${target_dir}/k8s/apps"
    [[ -d "$apps_dir" ]] || return
    local -a app_names=()
    local d
    for d in "$apps_dir"/*/; do
        [[ -d "$d" ]] || continue
        app_names+=("$(basename "$d")")
    done
    compadd -a app_names
}

_infra_complete_envs() {
    local target_dir="$(_infra_target_dir)"
    local ns_dir="${target_dir}/k8s/namespaces"
    [[ -d "$ns_dir" ]] || return
    local -a env_names=()
    local f
    for f in "$ns_dir"/*.yaml; do
        [[ -f "$f" ]] || continue
        env_names+=("$(basename "$f" .yaml)")
    done
    compadd -a env_names
}

_infra_complete_projects() {
    local target_dir="$(_infra_target_dir)"
    local proj_dir="${target_dir}/argocd/projects"
    [[ -d "$proj_dir" ]] || return
    local -a proj_names=()
    local f
    for f in "$proj_dir"/*.yaml; do
        [[ -f "$f" ]] || continue
        proj_names+=("$(basename "$f" .yaml)")
    done
    compadd -a proj_names
}

# --- Script completions ---

_infra_ctl() {
    local -a commands=(
        'init:Bootstrap the GitOps repository structure'
        'add-app:Add a new application'
        'add-env:Add a new environment'
        'add-project:Create an ArgoCD AppProject'
        'edit-project:Edit an existing AppProject'
        'list-apps:List all applications'
        'list-envs:List all environments'
        'list-projects:List all ArgoCD AppProjects'
        'remove-app:Remove an application and all its resources'
        'remove-env:Remove an environment and all its resources'
        'remove-project:Remove an ArgoCD AppProject'
        'enable-kargo:Enable Kargo progressive delivery'
        'preflight-check:Validate repository structure'
    )

    _arguments -s \
        '--target-dir[Directory to operate on]:directory:_directories' \
        '1:command:(( ${commands} ))' \
        '*:: :->args'

    case "$state" in
        args)
            case "${words[1]}" in
                remove-app)      _infra_complete_apps ;;
                remove-env)      _infra_complete_envs ;;
                edit-project)    _infra_complete_projects ;;
                remove-project)  _infra_complete_projects ;;
            esac
            ;;
    esac
}

_cluster_ctl() {
    local -a commands=(
        'init-cluster:Create a k3d cluster and install tooling'
        'delete-cluster:Delete a k3d cluster'
        'add-repo-creds:Configure ArgoCD access to a private Git repo'
        'add-kargo-creds:Configure Kargo access to a private registry'
        'upgrade-argocd:Upgrade ArgoCD Helm release'
        'upgrade-kargo:Upgrade Kargo Helm release'
        'status:Show cluster status'
        'preflight-check:Validate cluster prerequisites'
    )

    _arguments -s \
        '--target-dir[Directory context]:directory:_directories' \
        '1:command:(( ${commands} ))' \
        '*:: :->args'
}

_secret_ctl() {
    local -a commands=(
        'init:Install Sealed Secrets controller'
        'add:Encrypt and store a secret for an app/env'
        'list:List sealed secrets'
        'preflight-check:Validate sealed secrets setup'
    )

    _arguments -s \
        '--target-dir[Directory to operate on]:directory:_directories' \
        '1:command:(( ${commands} ))' \
        '*:: :->args'

    case "$state" in
        args)
            case "${words[1]}" in
                add|list)
                    case "$CURRENT" in
                        2) _infra_complete_apps ;;
                        3) _infra_complete_envs ;;
                    esac
                    ;;
            esac
            ;;
    esac
}

_user_ctl() {
    local -a commands=(
        'add-role:Create an RBAC role with a permission preset'
        'remove-role:Remove an RBAC role'
        'list-roles:List RBAC roles'
        'add:Create a human user with x509 cert'
        'remove:Remove a human user'
        'list:List users'
        'add-sa:Create a service account with token'
        'remove-sa:Remove a service account'
        'refresh-sa:Refresh a service account token'
        'preflight-check:Validate RBAC setup'
    )

    _arguments -s \
        '--target-dir[Directory to operate on]:directory:_directories' \
        '1:command:(( ${commands} ))' \
        '*:: :->args'
}

compdef _infra_ctl infra-ctl.sh
compdef _cluster_ctl cluster-ctl.sh
compdef _secret_ctl secret-ctl.sh
compdef _user_ctl user-ctl.sh
