# Private Repository Credentials

Two new commands in `cluster-ctl.sh` for configuring ArgoCD and Kargo access to private Git repositories and container registries.

## Problem

The tooling assumes public repositories. For private repos:
- ArgoCD cannot pull manifests to sync without Git read credentials
- Kargo cannot push image tag updates without Git write credentials
- Kargo Warehouses cannot watch private container registries without registry read credentials

Nothing in the current tooling creates these credentials or prompts the user to do so.

## Commands

### `cluster-ctl.sh add-repo-creds`

Creates an ArgoCD repository Secret for private Git repo access.

**Prerequisites:**
- ArgoCD installed (checks for `argocd` namespace)
- `.infra-ctl.conf` exists (reads `REPO_URL`)

**Behavior:**
1. Calls `load_conf` to read `REPO_URL`
2. Checks that the `argocd` namespace exists; exits with error if not
3. Checks if a secret with label `argocd.argoproj.io/secret-type=repository` already exists for this repo URL; if so, asks to overwrite via `gum confirm`
4. Prompts for GitHub PAT via `gum input --password`
5. Creates (or replaces) the Secret:
   - Namespace: `argocd`
   - Name: `repo-creds` (deterministic, not generated)
   - Labels: `argocd.argoproj.io/secret-type=repository`
   - Data: `type=git`, `url=<REPO_URL>`, `username=git`, `password=<PAT>`
6. Prints success message

**Dependencies:** `require_gum`, `require_cmd kubectl`

### `cluster-ctl.sh add-kargo-creds <app>`

Creates Git write credentials and optional registry read credentials in a Kargo Project namespace.

**Prerequisites:**
- Kargo directory exists for the app (`kargo/<app>/` in TARGET_DIR)
- `.infra-ctl.conf` exists (reads `REPO_URL`)
- The app's Kubernetes namespace exists in the cluster (the Kargo Project namespace equals the app name)

**Behavior:**
1. Validates the app name argument (required, validated with `validate_k8s_name`)
2. Calls `load_conf` to read `REPO_URL`
3. Checks that `kargo/<app>/` exists in TARGET_DIR; exits with error if not
4. Reads `IMAGE_REPO` from `kargo/<app>/warehouse.yaml` (grep for `repoURL:`)
5. Checks that the namespace `<app>` exists in the cluster; exits with error and hint if not ("Apply the Kargo Project resource first, or push and let ArgoCD create it")
6. Prompts for GitHub PAT via `gum input --password`
7. Creates a Git credential Secret:
   - Namespace: `<app>`
   - Name: `gitops-repo-creds`
   - Labels: `kargo.akuity.io/cred-type=git`
   - Data: `type=git`, `url=<REPO_URL>`, `username=git`, `password=<PAT>`
8. Asks "Is the container registry private?" via `gum confirm`
9. If yes, creates a registry credential Secret:
   - Namespace: `<app>`
   - Name: `registry-creds`
   - Labels: `kargo.akuity.io/cred-type=image`
   - Data: `type=image`, `repoURL=<IMAGE_REPO>`, `username=git`, `password=<PAT>` (reuses the same PAT)
10. Prints success message

**Dependencies:** `require_gum`, `require_cmd kubectl`

## Post-Install Hints

### After ArgoCD install in `cmd_init_cluster`

After the existing ArgoCD success/info messages, add:

```
print_info "If your GitOps repo is private, run: cluster-ctl.sh add-repo-creds"
```

### After Kargo install in `cmd_init_cluster`

After the existing Kargo info messages, add:

```
print_info "If your repo or registry is private, run: cluster-ctl.sh add-kargo-creds <app> (after adding apps)"
```

## Usage and Help Text

Update the `usage()` function:

```
Commands:
  init-cluster        Create a local k3d cluster and optionally install ArgoCD
  delete-cluster      Tear down a k3d cluster
  add-repo-creds      Configure ArgoCD access to a private Git repository
  add-kargo-creds     Configure Kargo access to a private Git repo and container registry
  upgrade-argocd      Re-apply ArgoCD Helm values (after editing helm/argocd-values.yaml)
  upgrade-kargo       Re-apply Kargo Helm release
  status              Show cluster and ArgoCD health
```

## README Updates

The "Example: Deploying an Application" walkthrough is updated to assume both ArgoCD and Kargo are enabled throughout:

- **Step 1** mentions answering yes to both ArgoCD and Kargo install prompts
- **Step 3** notes that `add-app` also generates Kargo resources (Warehouse, Stages) for backend and frontend, but not postgres (since postgres uses a public upstream image and isn't promoted through environments)
- **New step between current steps 5 and 6**: "Configure repository credentials" covering `add-repo-creds` and `add-kargo-creds backend` / `add-kargo-creds frontend`. Explains that postgres doesn't need Kargo creds because it has no Kargo resources.
- Step numbers shift accordingly (current 6 becomes 7, current 7 becomes 8)
- The "What you end up with" section remains unchanged

## Scope Exclusions

- No changes to `infra-ctl.sh` or `secret-ctl.sh`
- No automatic credential creation during `add-app` (infra-ctl stays git-only)
- No credential rotation, deletion, or listing commands
- No changes to the agent context document (it will be updated separately if needed)
