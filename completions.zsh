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

_infra_ctl() {
    local -a commands=(
        'init:Bootstrap the GitOps repository structure'
        'add-app:Add a new application'
        'add-env:Add a new environment'
        'add-project:Create an ArgoCD AppProject'
        'edit-project:Edit an existing AppProject'
        'enable-kargo:Enable Kargo progressive delivery'
        'preflight-check:Validate repository structure'
    )

    _arguments -s \
        '--target-dir[Directory to operate on]:directory:_directories' \
        '1:command:(( ${commands} ))' \
        '*:: :->args'
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
