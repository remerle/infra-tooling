# DRY Refactoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract repeated patterns across the four main scripts into shared helpers in `lib/common.sh` and `lib/user-ctl-helpers.sh`, reducing duplication and enforcing consistency.

**Architecture:** Add 5 new helper functions to `lib/common.sh` (`choose_from`, `confirm_or_abort`, `confirm_destructive_or_abort`, `print_global_options`, `detect_sa_accounts`) and 1 to `lib/user-ctl-helpers.sh` (`_fetch_cluster_info`). Then systematically replace all call sites. Also consolidate `calculate_expiry_date` internal duplication.

**Tech Stack:** Bash, gum CLI

---

## File Map

- **Modify:** `lib/common.sh` -- add `choose_from`, `confirm_or_abort`, `confirm_destructive_or_abort`, `print_global_options`
- **Modify:** `lib/user-ctl-helpers.sh` -- add `_fetch_cluster_info`, refactor kubeconfig generators, consolidate `calculate_expiry_date`, extract `detect_sa_accounts`
- **Modify:** `infra-ctl.sh` -- replace chooser/confirm patterns, use `print_global_options`
- **Modify:** `cluster-ctl.sh` -- replace chooser/confirm patterns, use `print_global_options`
- **Modify:** `secret-ctl.sh` -- replace chooser/confirm patterns, use `print_global_options`
- **Modify:** `user-ctl.sh` -- replace chooser/confirm patterns, use `print_global_options`, use `detect_sa_accounts`

---

### Task 1: Add `choose_from` helper to `lib/common.sh`

**Files:**
- Modify: `lib/common.sh` (insert after the `detect_app_project` function, around line 457)

This helper replaces the repeated pattern of: read items into array, check if empty, present gum chooser. It accepts items via stdin (one per line) to work with both `detect_*` functions and arbitrary pipelines.

- [ ] **Step 1: Add the `choose_from` function**

Insert after the detection functions section (after `detect_app_project`), before the `# --- Kargo support ---` section:

```bash
# Prompts the user to select an item from a list provided on stdin.
# Returns 1 (with a warning) if the list is empty; caller handles exit.
# Usage: var="$(detect_apps | choose_from "Select app:" "No apps.")" || exit 0
#   header:    gum choose --header text
#   empty_msg: message shown (via print_warning) when stdin is empty
#   Prints the selected item to stdout.
#
# IMPORTANT: This function runs in a subshell when called via $(...),
# so it cannot exit the parent script directly. Use `|| exit 0` at the
# call site to exit cleanly when the list is empty.
choose_from() {
    local header="$1"
    local empty_msg="$2"

    local items=()
    while IFS= read -r item; do
        [[ -n "$item" ]] && items+=("$item")
    done

    if [[ ${#items[@]} -eq 0 ]]; then
        print_warning "$empty_msg"
        return 1
    fi

    printf '%s\n' "${items[@]}" | gum choose --header "$header"
}
```

- [ ] **Step 2: Verify common.sh still sources correctly**

Run: `bash -n lib/common.sh`
Expected: no output (syntax OK)

- [ ] **Step 3: Commit**

```bash
git add lib/common.sh
git commit -m "Add choose_from helper to lib/common.sh

- Accepts items on stdin, shows gum chooser with header
- Returns 1 with warning if list is empty; callers use || exit 0
- Replaces ~12 instances of detect/check-empty/choose pattern"
```

---

### Task 2: Add `confirm_or_abort` and `confirm_destructive_or_abort` to `lib/common.sh`

**Files:**
- Modify: `lib/common.sh` (insert after `choose_from`)

- [ ] **Step 1: Add the confirmation helpers**

Insert immediately after `choose_from`:

```bash
# Prompts for confirmation; exits 0 with "Aborted." if declined.
# Usage: confirm_or_abort "Create these files?"
confirm_or_abort() {
    if ! gum confirm "$1"; then
        print_warning "Aborted."
        exit 0
    fi
}

# Same as confirm_or_abort but with red-styled prompt for destructive actions.
# Usage: confirm_destructive_or_abort "Delete cluster 'foo'? This cannot be undone."
confirm_destructive_or_abort() {
    if ! gum confirm --prompt.foreground 196 "$1"; then
        print_warning "Aborted."
        exit 0
    fi
}
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n lib/common.sh`
Expected: no output (syntax OK)

- [ ] **Step 3: Commit**

```bash
git add lib/common.sh
git commit -m "Add confirm_or_abort and confirm_destructive_or_abort helpers

- confirm_or_abort: standard confirmation with abort on decline
- confirm_destructive_or_abort: red-styled for dangerous operations
- Replaces ~10 instances of the confirm/abort pattern"
```

---

### Task 3: Add `print_global_options` to `lib/common.sh`

**Files:**
- Modify: `lib/common.sh` (insert in the styled output section, after `print_info`)

- [ ] **Step 1: Add the function**

Insert after `print_info` (around line 657), before `print_summary`:

```bash
# Prints the global options block shared by all script usage() functions.
print_global_options() {
    cat <<EOF

Global options:
  --target-dir <path>   Directory to operate on (default: current directory)
  --show-me             Print commands instead of hiding behind spinners (or set SHOW_ME=1)
  --explain             Print commands with explanations (learning mode, implies --show-me)
  --debug               Show full command output (implies --show-me; or set DEBUG=1)
EOF
}
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n lib/common.sh`
Expected: no output

- [ ] **Step 3: Commit**

```bash
git add lib/common.sh
git commit -m "Add print_global_options helper to lib/common.sh

- Extracts the 4-line global options block shared by all scripts' usage()"
```

---

### Task 4: Extract `_fetch_cluster_info` and consolidate `calculate_expiry_date` in `lib/user-ctl-helpers.sh`

**Files:**
- Modify: `lib/user-ctl-helpers.sh`

- [ ] **Step 1: Add `_fetch_cluster_info` helper**

Insert before `generate_cert_kubeconfig` (around line 306):

```bash
# Fetches current cluster connection info into caller-scoped variables.
# Sets: _cluster_name, _server, _ca_data
# Usage: _fetch_cluster_info (caller reads the variables directly)
_fetch_cluster_info() {
    _cluster_name="$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')"
    _server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
    _ca_data="$(kubectl config view --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
}
```

- [ ] **Step 2: Refactor `generate_cert_kubeconfig` to use `_fetch_cluster_info`**

Replace the three `local cluster_name server ca_data` + kubectl lines (lines 316-319) with:

```bash
    local _cluster_name _server _ca_data
    _fetch_cluster_info
```

Then update the heredoc to use `_cluster_name`, `_server`, `_ca_data` instead of `cluster_name`, `server`, `ca_data`. The full function becomes:

```bash
generate_cert_kubeconfig() {
    local username="$1"
    local cert_file="$2"
    local key_file="$3"
    local output_file="$4"

    local _cluster_name _server _ca_data
    _fetch_cluster_info

    cat >"$output_file" <<EOF
apiVersion: v1
kind: Config
clusters:
  - cluster:
      certificate-authority-data: ${_ca_data}
      server: ${_server}
    name: ${_cluster_name}
contexts:
  - context:
      cluster: ${_cluster_name}
      user: ${username}
    name: ${username}@${_cluster_name}
current-context: ${username}@${_cluster_name}
users:
  - name: ${username}
    user:
      client-certificate-data: $(base64 <"$cert_file" | tr -d '\n')
      client-key-data: $(base64 <"$key_file" | tr -d '\n')
EOF
    chmod 600 "$output_file"
}
```

- [ ] **Step 3: Refactor `generate_token_kubeconfig` to use `_fetch_cluster_info`**

Replace the three kubectl lines (lines 351-354) the same way. The full function becomes:

```bash
generate_token_kubeconfig() {
    local sa_name="$1"
    local token="$2"
    local output_file="$3"

    local _cluster_name _server _ca_data
    _fetch_cluster_info

    cat >"$output_file" <<EOF
apiVersion: v1
kind: Config
clusters:
  - cluster:
      certificate-authority-data: ${_ca_data}
      server: ${_server}
    name: ${_cluster_name}
contexts:
  - context:
      cluster: ${_cluster_name}
      user: ${sa_name}
    name: ${sa_name}@${_cluster_name}
current-context: ${sa_name}@${_cluster_name}
users:
  - name: ${sa_name}
    user:
      token: ${token}
EOF
    chmod 600 "$output_file"
}
```

- [ ] **Step 4: Consolidate `calculate_expiry_date`**

Replace the current function (with three nearly-identical case branches) with:

```bash
calculate_expiry_date() {
    local duration="$1"

    local amount="${duration%%[!0-9]*}"
    local unit="${duration##*[0-9]}"

    if [[ -z "$amount" || -z "$unit" ]]; then
        echo "(unknown expiry)"
        return
    fi

    local date_flag date_unit
    case "$unit" in
        h) date_flag="H"; date_unit="hours" ;;
        m) date_flag="M"; date_unit="minutes" ;;
        s) date_flag="S"; date_unit="seconds" ;;
        *)
            echo "(unknown expiry: unsupported unit '${unit}')"
            return
            ;;
    esac

    # macOS date vs GNU date
    if date -v+1S "+%s" &>/dev/null 2>&1; then
        date -v+"${amount}${date_flag}" "+%Y-%m-%d %H:%M"
    else
        date -d "+${amount} ${date_unit}" "+%Y-%m-%d %H:%M"
    fi
}
```

- [ ] **Step 5: Verify syntax**

Run: `bash -n lib/user-ctl-helpers.sh`
Expected: no output

- [ ] **Step 6: Commit**

```bash
git add lib/user-ctl-helpers.sh
git commit -m "Extract _fetch_cluster_info and consolidate calculate_expiry_date

- _fetch_cluster_info: shared cluster info fetch for kubeconfig generators
- calculate_expiry_date: collapse 3 identical case branches into one
- Refactor both kubeconfig generators to use _fetch_cluster_info"
```

---

### Task 5: Extract `detect_sa_accounts` into `lib/user-ctl-helpers.sh`

**Files:**
- Modify: `lib/user-ctl-helpers.sh` (add function in the Detection section at the bottom)
- Modify: `user-ctl.sh` (replace duplicated SA detection in `cmd_refresh_sa` and `cmd_remove_sa`)

The SA detection pattern (parse yq output, filter for accounts with kubeconfig but no cert) is duplicated verbatim between `cmd_refresh_sa` (lines 762-773) and `cmd_remove_sa` (lines 814-826).

- [ ] **Step 1: Add `detect_sa_accounts` to `lib/user-ctl-helpers.sh`**

Insert at the end of the file, before the closing (there's no closing, it's sourced):

```bash
# Prints detected service account names (one per line).
# SA accounts have a kubeconfig but no certificate file.
# Usage: detect_sa_accounts <values_file> <users_dir>
detect_sa_accounts() {
    local values_file="$1"
    local users_dir="$2"

    local accounts
    accounts="$(yq '.configs.cm | keys | .[]' "$values_file" 2>/dev/null \
        | grep '^accounts\.' | sed 's/^accounts\.//')" || true

    local acct
    while IFS= read -r acct; do
        [[ -z "$acct" ]] && continue
        if [[ -f "${users_dir}/${acct}.kubeconfig" && ! -f "${users_dir}/${acct}.crt" ]]; then
            echo "$acct"
        fi
    done <<<"$accounts"
}
```

- [ ] **Step 2: Replace the SA detection block in `cmd_refresh_sa`**

In `user-ctl.sh`, replace lines 763-778 (the `local users_dir` through `gum choose` block inside the `if [[ -z "$sa_name" ]]` branch) with:

```bash
    if [[ -z "$sa_name" ]]; then
        require_yq
        sa_name="$(detect_sa_accounts "$VALUES_FILE" "${TARGET_DIR}/users" \
            | choose_from "Select service account to refresh:" "No service accounts found.")" || exit 0
    fi
```

- [ ] **Step 3: Replace the SA detection block in `cmd_remove_sa`**

In `user-ctl.sh`, replace the equivalent block in `cmd_remove_sa` (lines 815-831) with:

```bash
    if [[ -z "$sa_name" ]]; then
        require_yq
        sa_name="$(detect_sa_accounts "$VALUES_FILE" "${TARGET_DIR}/users" \
            | choose_from "Select service account to remove:" "No service accounts to remove.")" || exit 0
    fi
```

- [ ] **Step 4: Verify syntax**

Run: `bash -n lib/user-ctl-helpers.sh && bash -n user-ctl.sh`
Expected: no output

- [ ] **Step 5: Commit**

```bash
git add lib/user-ctl-helpers.sh user-ctl.sh
git commit -m "Extract detect_sa_accounts into user-ctl-helpers.sh

- Eliminates duplicated SA detection in cmd_refresh_sa and cmd_remove_sa
- Uses choose_from helper for interactive selection"
```

---

### Task 6: Replace chooser patterns in `infra-ctl.sh`

**Files:**
- Modify: `infra-ctl.sh`

Replace all instances of the detect-into-array/check-empty/gum-choose pattern with `choose_from`. There are 5 occurrences.

- [ ] **Step 1: Replace chooser in `cmd_edit_project` (line 646-656)**

Replace:

```bash
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
```

With:

```bash
    if [[ -z "$project_name" ]]; then
        load_conf
        project_name="$(detect_projects | choose_from "Select project to edit:" "No projects to edit.")" || exit 0
    fi
```

- [ ] **Step 2: Replace chooser in `cmd_remove_project` (line 988-998)**

Replace:

```bash
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
```

With:

```bash
    if [[ -z "$project_name" ]]; then
        load_conf
        project_name="$(detect_projects | choose_from "Select project to remove:" "No projects to remove.")" || exit 0
    fi
```

- [ ] **Step 3: Replace chooser in `cmd_remove_app` (line 1099-1109)**

Replace:

```bash
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
```

With:

```bash
    if [[ -z "$app_name" ]]; then
        load_conf
        app_name="$(detect_apps | choose_from "Select application to remove:" "No applications to remove.")" || exit 0
    fi
```

- [ ] **Step 4: Replace chooser in `cmd_remove_env` (line 1188-1198)**

Replace:

```bash
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
```

With:

```bash
    if [[ -z "$env_name" ]]; then
        load_conf
        env_name="$(detect_envs | choose_from "Select environment to remove:" "No environments to remove.")" || exit 0
    fi
```

- [ ] **Step 5: Verify syntax**

Run: `bash -n infra-ctl.sh`
Expected: no output

- [ ] **Step 6: Commit**

```bash
git add infra-ctl.sh
git commit -m "Replace chooser patterns in infra-ctl.sh with choose_from

- cmd_edit_project, cmd_remove_project, cmd_remove_app, cmd_remove_env
- Each reduced from 10 lines to 3"
```

---

### Task 7: Replace confirmation patterns in `infra-ctl.sh`

**Files:**
- Modify: `infra-ctl.sh`

Replace all `gum confirm` + abort blocks with the helpers. There are 5 standard confirms and 1 destructive confirm.

- [ ] **Step 1: Replace standard confirms**

Replace each occurrence of:

```bash
    if ! gum confirm "Some message?"; then
        print_warning "Aborted."
        exit 0
    fi
```

With:

```bash
    confirm_or_abort "Some message?"
```

Locations (search for `gum confirm` in infra-ctl.sh and replace the ones that follow the abort pattern):
- Line 43: `confirm_or_abort "Proceed with repo URL '${repo_url}' and owner '${repo_owner}'?"`
- Line 196: `confirm_or_abort "Create these files?"`
- Line 367: `confirm_or_abort "Create these files?"`
- Line 817: `confirm_or_abort "Use this order? (Edit kargo/promotion-order.txt after to change)"`
- Line 1050: `confirm_or_abort "Remove project '${project_name}'?"`
- Line 1157: `confirm_or_abort "Remove application '${app_name}' and all its resources?"`
- Line 1300: `confirm_or_abort "Remove environment '${env_name}' and all its resources?"`

- [ ] **Step 2: Replace destructive confirm**

Line 1425:

```bash
    confirm_destructive_or_abort "Reset this GitOps repository? This cannot be undone."
```

- [ ] **Step 3: Verify syntax**

Run: `bash -n infra-ctl.sh`
Expected: no output

- [ ] **Step 4: Commit**

```bash
git add infra-ctl.sh
git commit -m "Replace confirmation patterns in infra-ctl.sh with helpers

- 7 confirm_or_abort replacements
- 1 confirm_destructive_or_abort replacement"
```

---

### Task 8: Replace chooser and confirmation patterns in `secret-ctl.sh`

**Files:**
- Modify: `secret-ctl.sh`

- [ ] **Step 1: Replace app chooser in `cmd_add` (lines 81-92)**

Replace:

```bash
    if [[ -z "$app_name" ]]; then
        load_conf
        local apps=()
        while IFS= read -r app; do
            apps+=("$app")
        done < <(detect_apps)
        if [[ ${#apps[@]} -eq 0 ]]; then
            print_warning "No applications found. Run 'infra-ctl.sh add-app' first."
            exit 0
        fi
        app_name="$(printf '%s\n' "${apps[@]}" | gum choose --header "Select application:")"
    fi
```

With:

```bash
    if [[ -z "$app_name" ]]; then
        load_conf
        app_name="$(detect_apps | choose_from "Select application:" "No applications found. Run 'infra-ctl.sh add-app' first.")" || exit 0
    fi
```

- [ ] **Step 2: Replace env chooser in `cmd_add` (lines 94-105)**

Replace:

```bash
    if [[ -z "$env_name" ]]; then
        [[ -z "${REPO_URL:-}" ]] && load_conf
        local envs=()
        while IFS= read -r env; do
            envs+=("$env")
        done < <(detect_envs)
        if [[ ${#envs[@]} -eq 0 ]]; then
            print_warning "No environments found. Run 'infra-ctl.sh add-env' first."
            exit 0
        fi
        env_name="$(printf '%s\n' "${envs[@]}" | gum choose --header "Select environment:")"
    fi
```

With:

```bash
    if [[ -z "$env_name" ]]; then
        [[ -z "${REPO_URL:-}" ]] && load_conf
        env_name="$(detect_envs | choose_from "Select environment:" "No environments found. Run 'infra-ctl.sh add-env' first.")" || exit 0
    fi
```

- [ ] **Step 3: Replace app chooser in `cmd_remove` (lines 293-301)**

Replace the same pattern with:

```bash
    if [[ -z "$app_name" ]]; then
        load_conf
        app_name="$(detect_apps | choose_from "Select application:" "No applications found.")" || exit 0
    fi
```

- [ ] **Step 4: Replace env chooser in `cmd_remove` (lines 310-320)**

This one uses a custom list (`available_envs`), not `detect_envs`, so keep the array but feed it to `choose_from`:

Replace:

```bash
        if [[ ${#available_envs[@]} -eq 0 ]]; then
            print_warning "No sealed secrets found for '${app_name}'."
            exit 0
        fi
        env_name="$(printf '%s\n' "${available_envs[@]}" | gum choose --header "Select environment:")"
```

With:

```bash
        env_name="$(printf '%s\n' "${available_envs[@]}" | choose_from "Select environment:" "No sealed secrets found for '${app_name}'.")" || exit 0
```

- [ ] **Step 5: Replace confirmation in `cmd_remove` (line 335)**

Replace:

```bash
    if ! gum confirm "Remove sealed secret for '${app_name}' in '${env_name}'?"; then
        print_warning "Aborted."
        exit 0
    fi
```

With:

```bash
    confirm_or_abort "Remove sealed secret for '${app_name}' in '${env_name}'?"
```

- [ ] **Step 6: Verify syntax**

Run: `bash -n secret-ctl.sh`
Expected: no output

- [ ] **Step 7: Commit**

```bash
git add secret-ctl.sh
git commit -m "Replace chooser and confirmation patterns in secret-ctl.sh

- 4 choose_from replacements
- 1 confirm_or_abort replacement"
```

---

### Task 9: Replace chooser and confirmation patterns in `cluster-ctl.sh`

**Files:**
- Modify: `cluster-ctl.sh`

- [ ] **Step 1: Replace cluster chooser in `cmd_delete_cluster` (lines 315-323)**

Replace:

```bash
        local clusters
        clusters="$(k3d cluster list -o json 2>/dev/null | jq -r '.[].name')"

        if [[ -z "$clusters" ]]; then
            print_warning "No k3d clusters found."
            exit 0
        fi

        cluster_name="$(echo "$clusters" | gum choose --header "Select cluster to delete:")"
```

With:

```bash
        cluster_name="$(k3d cluster list -o json 2>/dev/null | jq -r '.[].name' \
            | choose_from "Select cluster to delete:" "No k3d clusters found.")" || exit 0
```

- [ ] **Step 2: Replace destructive confirm in `cmd_delete_cluster` (line 328)**

Replace:

```bash
    if ! gum confirm --prompt.foreground 196 "Delete cluster '${cluster_name}'? This cannot be undone."; then
        print_warning "Aborted."
        exit 0
    fi
```

With:

```bash
    confirm_destructive_or_abort "Delete cluster '${cluster_name}'? This cannot be undone."
```

- [ ] **Step 3: Replace overwrite confirm in `cmd_add_repo_creds` (line 419)**

Replace:

```bash
        if ! gum confirm "Overwrite existing credentials?"; then
            print_warning "Aborted."
            exit 0
        fi
```

With:

```bash
        confirm_or_abort "Overwrite existing credentials?"
```

- [ ] **Step 4: Verify syntax**

Run: `bash -n cluster-ctl.sh`
Expected: no output

- [ ] **Step 5: Commit**

```bash
git add cluster-ctl.sh
git commit -m "Replace chooser and confirmation patterns in cluster-ctl.sh

- 1 choose_from replacement (delete-cluster)
- 1 confirm_destructive_or_abort replacement
- 1 confirm_or_abort replacement"
```

---

### Task 10: Replace chooser and confirmation patterns in `user-ctl.sh`

**Files:**
- Modify: `user-ctl.sh`

- [ ] **Step 1: Replace role chooser in `cmd_remove_role` (lines 236-245)**

Replace:

```bash
    if [[ -z "$role_name" ]]; then
        local policy
        policy="$(yq '.configs.rbac."policy.csv" // ""' "$VALUES_FILE")" || true
        local roles
        roles="$(echo "$policy" | grep -oE 'role:[^,[:space:]]+' | sed 's/^role://' | sort -u)" || true
        if [[ -z "$roles" ]]; then
            print_warning "No roles to remove."
            exit 0
        fi
        role_name="$(echo "$roles" | gum choose --header "Select role to remove:")"
    fi
```

With:

```bash
    if [[ -z "$role_name" ]]; then
        local policy
        policy="$(yq '.configs.rbac."policy.csv" // ""' "$VALUES_FILE")" || true
        role_name="$(echo "$policy" | grep -oE 'role:[^,[:space:]]+' | sed 's/^role://' | sort -u \
            | choose_from "Select role to remove:" "No roles to remove.")" || exit 0
    fi
```

- [ ] **Step 2: Replace user chooser in `cmd_remove` (lines 416-424)**

Replace:

```bash
    if [[ -z "$username" ]]; then
        local accounts
        accounts="$(yq '.configs.cm | keys | .[]' "$VALUES_FILE" 2>/dev/null \
            | grep '^accounts\.' | sed 's/^accounts\.//')" || true
        if [[ -z "$accounts" ]]; then
            print_warning "No users to remove."
            exit 0
        fi
        username="$(echo "$accounts" | gum choose --header "Select user to remove:")"
    fi
```

With:

```bash
    if [[ -z "$username" ]]; then
        username="$(yq '.configs.cm | keys | .[]' "$VALUES_FILE" 2>/dev/null \
            | grep '^accounts\.' | sed 's/^accounts\.//' \
            | choose_from "Select user to remove:" "No users to remove.")" || exit 0
    fi
```

- [ ] **Step 3: Replace destructive confirms**

Three locations:

Line 255 (`cmd_remove_role`):
```bash
    confirm_destructive_or_abort "Remove role '${role_name}'? This removes ArgoCD policy and k8s RBAC."
```

Line 434 (`cmd_remove`):
```bash
    confirm_destructive_or_abort "Remove user '${username}'?"
```

Line 836 (`cmd_remove_sa`):
```bash
    confirm_destructive_or_abort "Remove service account '${sa_name}'?"
```

- [ ] **Step 4: Verify syntax**

Run: `bash -n user-ctl.sh`
Expected: no output

- [ ] **Step 5: Commit**

```bash
git add user-ctl.sh
git commit -m "Replace chooser and confirmation patterns in user-ctl.sh

- 2 choose_from replacements (remove-role, remove user)
- 3 confirm_destructive_or_abort replacements"
```

---

### Task 11: Replace `print_global_options` in all usage() functions

**Files:**
- Modify: `infra-ctl.sh`, `cluster-ctl.sh`, `secret-ctl.sh`, `user-ctl.sh`

- [ ] **Step 1: Replace in `infra-ctl.sh` usage() (lines 1466-1470)**

Replace:

```bash
Global options:
  --target-dir <path>   Directory to operate on (default: current directory)
  --show-me             Print commands instead of hiding behind spinners (or set SHOW_ME=1)
  --explain             Print commands with explanations (learning mode, implies --show-me)
  --debug               Show full command output (implies --show-me; or set DEBUG=1)
EOF
```

With:

```bash
$(print_global_options)
EOF
```

- [ ] **Step 2: Replace in `cluster-ctl.sh` usage() (lines 681-685)**

Same replacement. Note: cluster-ctl.sh says "Directory context" instead of "Directory to operate on" -- standardize to "Directory to operate on".

Replace:

```bash
Global options:
  --target-dir <path>   Directory context (default: current directory)
  --show-me             Print commands instead of hiding behind spinners (or set SHOW_ME=1)
  --explain             Print commands with explanations (learning mode, implies --show-me)
  --debug               Show full command output (implies --show-me; or set DEBUG=1)
EOF
```

With:

```bash
$(print_global_options)
EOF
```

- [ ] **Step 3: Replace in `secret-ctl.sh` usage() (lines 377-381)**

Same replacement.

- [ ] **Step 4: Replace in `user-ctl.sh` usage() (lines 901-905)**

Same replacement.

- [ ] **Step 5: Verify all scripts**

Run: `bash -n infra-ctl.sh && bash -n cluster-ctl.sh && bash -n secret-ctl.sh && bash -n user-ctl.sh`
Expected: no output

- [ ] **Step 6: Commit**

```bash
git add infra-ctl.sh cluster-ctl.sh secret-ctl.sh user-ctl.sh
git commit -m "Use print_global_options in all usage() functions

- Replaces 4 copies of the global options block
- Fixes inconsistent wording in cluster-ctl.sh ('Directory context' -> 'Directory to operate on')"
```

---

### Task 12: Final verification

**Files:** All modified files

- [ ] **Step 1: Syntax check all scripts**

Run: `bash -n lib/common.sh && bash -n lib/user-ctl-helpers.sh && bash -n infra-ctl.sh && bash -n cluster-ctl.sh && bash -n secret-ctl.sh && bash -n user-ctl.sh`
Expected: no output

- [ ] **Step 2: Run each script's preflight-check to verify sourcing works**

Run:
```bash
./infra-ctl.sh preflight-check
./cluster-ctl.sh preflight-check
./secret-ctl.sh preflight-check
./user-ctl.sh preflight-check
```

Expected: Each prints its dependency list with check marks (may show some missing tools depending on what's installed, but should not error on source/parse).

- [ ] **Step 3: Run each script with --help to verify usage works**

Run:
```bash
./infra-ctl.sh --help
./cluster-ctl.sh --help
./secret-ctl.sh --help
./user-ctl.sh --help
```

Expected: Each prints its usage with the shared global options block at the bottom.

- [ ] **Step 4: Verify no remaining duplication of old patterns**

Run:
```bash
# Should return 0 results for the old abort pattern (outside of common.sh)
grep -rn 'print_warning "Aborted."' infra-ctl.sh cluster-ctl.sh secret-ctl.sh user-ctl.sh
```

Expected: No matches (all moved to helpers). Note: some `gum confirm` calls that don't follow the abort pattern (e.g., `gum confirm "Restrict source repositories?"` in edit-project) are intentionally left alone because they branch into different logic rather than aborting.
