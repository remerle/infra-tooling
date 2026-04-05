#compdef infra-ctl.sh cluster-ctl.sh secret-ctl.sh config-ctl.sh user-ctl.sh

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
        'add-ingress:Add an Ingress resource to an application'
        'list-ingress:List all Ingress resources'
        'remove-ingress:Remove an Ingress resource from an application'
        'enable-kargo:Enable Kargo progressive delivery'
        'reset:Remove all generated files (inverse of init)'
        'preflight-check:Validate repository structure'
    )

    _arguments -s \
        '--target-dir[Directory to operate on]:directory:_directories' \
        '--show-me[Print commands instead of hiding behind spinners]' \
        '--explain[Print commands with explanations (learning mode)]' \
        '--debug[Show full command output]' \
        '1:command:(( ${commands} ))' \
        '*:: :->args'

    case "$state" in
        args)
            case "${words[1]}" in
                init)
                    _arguments \
                        '--repo-url[GitOps repo URL]:url:' \
                        '--yes[Skip confirmation]' '-y[Skip confirmation]'
                    ;;
                add-app)
                    _arguments \
                        '--name[Application name]:name:' \
                        '--project[Project to add the app to]:project:_infra_complete_projects' \
                        '--workload-type[Workload type]:type:(deployment statefulset)' \
                        '--preset[Preset to use]:preset:' \
                        '*--set[KEY=VAL preset placeholder]:key=val:' \
                        '*--secret-key[Secret key name]:key:' \
                        '*--config[KEY=VAL configMap entry]:key=val:' \
                        '--kargo[Generate Kargo resources]' \
                        '--no-kargo[Skip Kargo resources]' \
                        '--image-repo[OCI image repository (Kargo)]:url:' \
                        '--custom[Provide custom image/port/probe values]' \
                        '--image[Container image]:image:' \
                        '--port[Service port]:port:' \
                        '--secret-name[Secret name]:name:' \
                        '--probe-path[HTTP probe path]:path:' \
                        '--yes[Skip confirmation]' '-y[Skip confirmation]'
                    ;;
                add-env)
                    _arguments \
                        '--name[Environment name]:name:' \
                        '--yes[Skip confirmation]' '-y[Skip confirmation]'
                    ;;
                add-project)
                    _arguments \
                        '--name[Project name]:name:' \
                        '--description[Project description]:text:' \
                        '--restrict-repos[Restrict source repos to the main repo]' \
                        '--no-restrict-repos[Allow any source repo]' \
                        '*--source-repo[Allowed source repo URL]:url:' \
                        '*--namespace[Destination namespace]:namespace:_infra_complete_envs' \
                        '--no-restrict-namespaces[Allow all destination namespaces]' \
                        '--cluster-resources[Allow cluster-scoped resources]' \
                        '--no-cluster-resources[Deny cluster-scoped resources]'
                    ;;
                edit-project)
                    _arguments \
                        '--name[Project name]:name:_infra_complete_projects' \
                        '--description[Project description]:text:' \
                        '--restrict-repos[Restrict source repos]' \
                        '--no-restrict-repos[Allow any repo]' \
                        '*--source-repo[Allowed source repo URL]:url:' \
                        '*--namespace[Destination namespace]:namespace:_infra_complete_envs' \
                        '--no-restrict-namespaces[Allow all destination namespaces]' \
                        '--cluster-resources[Allow cluster-scoped resources]' \
                        '--no-cluster-resources[Deny cluster-scoped resources]'
                    ;;
                add-ingress)
                    _arguments \
                        '--app[Application]:app:_infra_complete_apps' \
                        '*--env[Environment]:env:_infra_complete_envs' \
                        '--yes[Skip confirmation]' '-y[Skip confirmation]' \
                        '*:app:_infra_complete_apps'
                    ;;
                remove-ingress)
                    _arguments \
                        '--app[Application]:app:_infra_complete_apps' \
                        '*--env[Environment]:env:_infra_complete_envs' \
                        '--yes[Skip confirmation]' '-y[Skip confirmation]' \
                        '*:app:_infra_complete_apps'
                    ;;
                enable-kargo)
                    _arguments \
                        '*--image-repo[<app>=<url> image repo]:app=url:' \
                        '--yes[Skip confirmation]' '-y[Skip confirmation]'
                    ;;
                remove-app)
                    _arguments \
                        '--name[Application name]:name:_infra_complete_apps' \
                        '--yes[Skip confirmation]' '-y[Skip confirmation]' \
                        '*:app:_infra_complete_apps'
                    ;;
                remove-env)
                    _arguments \
                        '--name[Environment name]:name:_infra_complete_envs' \
                        '--yes[Skip confirmation]' '-y[Skip confirmation]' \
                        '*:env:_infra_complete_envs'
                    ;;
                remove-project)
                    _arguments \
                        '--name[Project name]:name:_infra_complete_projects' \
                        '--reassign-to[Reassign apps to this project]:project:_infra_complete_projects' \
                        '--yes[Skip confirmation]' '-y[Skip confirmation]' \
                        '*:project:_infra_complete_projects'
                    ;;
                reset)
                    _arguments '--yes[Skip confirmation]' '-y[Skip confirmation]'
                    ;;
            esac
            ;;
    esac
}

_cluster_ctl() {
    local -a commands=(
        'init-cluster:Create a k3d cluster and install tooling'
        'delete-cluster:Delete a k3d cluster'
        'add-argo-creds:Configure ArgoCD access to a private Git repo'
        'add-registry-creds:Configure container registry credentials for image pulls'
        'add-kargo-creds:Configure Kargo access to a private registry'
        'upgrade-argocd:Upgrade ArgoCD Helm release'
        'upgrade-kargo:Upgrade Kargo Helm release'
        'argo-init:Bootstrap ArgoCD with the parent-app'
        'argo-sync:Force ArgoCD to sync all applications'
        'argo-status:Show ArgoCD application status and errors'
        'renew-tls:Regenerate mkcert certificates'
        'status:Show cluster status'
        'preflight-check:Validate cluster prerequisites'
    )

    _arguments -s \
        '--target-dir[Directory context]:directory:_directories' \
        '--show-me[Print commands instead of hiding behind spinners]' \
        '--explain[Print commands with explanations (learning mode)]' \
        '--debug[Show full command output]' \
        '1:command:(( ${commands} ))' \
        '*:: :->args'

    case "$state" in
        args)
            case "${words[1]}" in
                init-cluster)
                    _arguments \
                        '--name[Cluster name]:name:' \
                        '--agents[Number of agent nodes]:count:' \
                        '--expose-ports[Expose ports 80/443]' \
                        '--no-expose-ports[Do not expose ports]' \
                        '--tls[Enable HTTPS with mkcert]' \
                        '--no-tls[Skip HTTPS]' \
                        '--argocd[Install ArgoCD]' \
                        '--no-argocd[Skip ArgoCD]' \
                        '--kargo[Install Kargo]' \
                        '--no-kargo[Skip Kargo]' \
                        '--kargo-password[Kargo admin password]:password:'
                    ;;
                delete-cluster)
                    local -a cluster_names
                    cluster_names=(${(f)"$(k3d cluster list -o json 2>/dev/null | jq -r '.[].name' 2>/dev/null)"})
                    _arguments \
                        "--name[Cluster name]:name:(${cluster_names})" \
                        '--yes[Skip confirmation]' '-y[Skip confirmation]' \
                        "*:cluster:(${cluster_names})"
                    ;;
                add-argo-creds)
                    _arguments \
                        '--pat[GitHub personal access token]:pat:' \
                        '--yes[Skip confirmation]' '-y[Skip confirmation]'
                    ;;
                add-registry-creds)
                    _arguments \
                        '--registry[Container registry URL]:url:' \
                        '--username[Registry username]:user:' \
                        '--token[Registry token/password]:token:' \
                        '*--env[Environment]:env:_infra_complete_envs' \
                        '--yes[Skip overwrite confirmation]' '-y[Skip overwrite confirmation]'
                    ;;
                add-kargo-creds)
                    _arguments \
                        '--app[Application]:app:_infra_complete_apps' \
                        '--pat[GitHub personal access token]:pat:' \
                        '--private-registry[App uses a private registry]' \
                        '--no-private-registry[App uses a public registry]' \
                        '--yes[Skip overwrite confirmation]' '-y[Skip overwrite confirmation]'
                    ;;
            esac
            ;;
    esac
}

_secret_ctl() {
    local -a commands=(
        'init:Install Sealed Secrets controller'
        'add:Encrypt and store a secret for an app/env'
        'list:List sealed secrets'
        'remove:Remove a sealed secret for an app/env'
        'verify:Check for missing secret references'
        'preflight-check:Validate sealed secrets setup'
    )

    _arguments -s \
        '--target-dir[Directory to operate on]:directory:_directories' \
        '--show-me[Print commands instead of hiding behind spinners]' \
        '--explain[Print commands with explanations (learning mode)]' \
        '--debug[Show full command output]' \
        '1:command:(( ${commands} ))' \
        '*:: :->args'

    case "$state" in
        args)
            case "${words[1]}" in
                init)
                    _arguments \
                        '--restore-key[Restore sealed-secrets key from backup]' \
                        '--no-restore-key[Generate a new key]'
                    ;;
                add)
                    _arguments \
                        '--app[Application]:app:_infra_complete_apps' \
                        '--env[Environment]:env:_infra_complete_envs' \
                        '*--secret-val[KEY=VAL secret value]:key=val:' \
                        '--overwrite[Overwrite existing sealed secret]' \
                        '--no-overwrite[Do not overwrite existing]'
                    ;;
                remove)
                    _arguments \
                        '--app[Application]:app:_infra_complete_apps' \
                        '--env[Environment]:env:_infra_complete_envs' \
                        '--yes[Skip confirmation]' '-y[Skip confirmation]'
                    ;;
                verify)
                    _arguments \
                        '--env[Environment]:env:_infra_complete_envs' \
                        '--walk[Walk the whole repo]' \
                        '--no-walk[Only check the given env]'
                    ;;
                list)
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
        '--show-me[Print commands instead of hiding behind spinners]' \
        '--explain[Print commands with explanations (learning mode)]' \
        '--debug[Show full command output]' \
        '1:command:(( ${commands} ))' \
        '*:: :->args'

    case "$state" in
        args)
            case "${words[1]}" in
                add-role)
                    _arguments \
                        '--name[Role name]:name:' \
                        '--preset[Permission preset]:preset:(admin-readonly-settings developer viewer custom)' \
                        '*--argocd-resource[ArgoCD resource]:resource:(applications projects repositories clusters certificates accounts logs exec)' \
                        '*--action[ArgoCD action]:action:(get create update delete sync override action \*)' \
                        '--k8s-scope[K8s access scope]:scope:(cluster-wide namespace-scoped)' \
                        '*--k8s-verb[kubectl verb]:verb:(get list watch create update patch delete \*)' \
                        '*--namespace[Namespace]:namespace:_infra_complete_envs'
                    ;;
                remove-role)
                    _arguments \
                        '--name[Role name]:name:' \
                        '--yes[Skip confirmation]' '-y[Skip confirmation]'
                    ;;
                remove)
                    _arguments \
                        '--name[Username]:name:' \
                        '--yes[Skip confirmation]' '-y[Skip confirmation]'
                    ;;
                remove-sa)
                    _arguments \
                        '--name[SA name]:name:' \
                        '--yes[Skip confirmation]' '-y[Skip confirmation]'
                    ;;
                add)
                    _arguments \
                        '--name[Username]:name:' \
                        '--group[RBAC group (role name)]:group:'
                    ;;
                add-sa)
                    _arguments \
                        '--name[Service account name]:name:' \
                        '--group[RBAC group (role name)]:group:' \
                        '--duration[Token duration (e.g. 2160h)]:duration:'
                    ;;
                refresh-sa)
                    _arguments \
                        '--name[Service account name]:name:' \
                        '--duration[Token duration (e.g. 2160h)]:duration:'
                    ;;
            esac
            ;;
    esac
}

_config_ctl() {
    local -a commands=(
        'add:Add config values to an application'
        'list:List config values for an application'
        'remove:Remove config values from an application'
        'verify:Check for missing config references'
    )

    _arguments -s \
        '--target-dir[Directory to operate on]:directory:_directories' \
        '--show-me[Print commands instead of hiding behind spinners]' \
        '--explain[Print commands with explanations (learning mode)]' \
        '--debug[Show full command output]' \
        '1:command:(( ${commands} ))' \
        '*:: :->args'

    case "$state" in
        args)
            case "${words[1]}" in
                add)
                    _arguments \
                        '--app[Application]:app:_infra_complete_apps' \
                        '--env[Environment]:env:_infra_complete_envs' \
                        '*--config[KEY=VAL configMap entry]:key=val:'
                    ;;
                remove)
                    _arguments \
                        '--app[Application]:app:_infra_complete_apps' \
                        '--env[Environment]:env:_infra_complete_envs' \
                        '*--key[Config key prefix]:key:' \
                        '--yes[Skip confirmation]' '-y[Skip confirmation]'
                    ;;
                verify)
                    _arguments \
                        '--env[Environment]:env:_infra_complete_envs' \
                        '--walk[Walk the whole repo]' \
                        '--no-walk[Only check the given env]'
                    ;;
                list)
                    case "$CURRENT" in
                        2) _infra_complete_apps ;;
                        3) _infra_complete_envs ;;
                    esac ;;
            esac ;;
    esac
}

compdef _infra_ctl infra-ctl.sh
compdef _cluster_ctl cluster-ctl.sh
compdef _secret_ctl secret-ctl.sh
compdef _config_ctl config-ctl.sh
compdef _user_ctl user-ctl.sh
