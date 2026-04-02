# remove-app and remove-env Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `remove-app` and `remove-env` commands to `infra-ctl.sh` that cleanly delete all generated files for an application or environment, including Kargo resources and promotion chain repair.

**Architecture:** Two new `cmd_*` functions in `infra-ctl.sh` following existing command patterns (preview, confirm, execute). One new `print_removed` helper in `lib/common.sh` for summary output. Kargo chain repair in `remove-env` reuses existing `render_template` and `read_promotion_order` from `common.sh`.

**Tech Stack:** Bash, gum (interactive prompts), existing template rendering infrastructure

---

### Task 1: Add `print_removed` helper to `lib/common.sh`

**Files:**
- Modify: `lib/common.sh:503-518` (after `print_summary`)

- [ ] **Step 1: Add `print_removed` function**

Add this function immediately after `print_summary` (after line 518) in `lib/common.sh`:

```bash
# Prints a summary of removed files.
# Usage: print_removed "${removed_files[@]}"
print_removed() {
    local files=("$@")
    if [[ ${#files[@]} -eq 0 ]]; then
        print_warning "No files were removed."
        return
    fi
    echo ""
    print_header "Removed:"
    local f
    for f in "${files[@]}"; do
        print_success "$f"
    done
    echo ""
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/common.sh
git commit -m "Add print_removed helper to common.sh

- Symmetric with print_summary, prints a styled list of deleted files"
```

---

### Task 2: Add `cmd_remove_app` to `infra-ctl.sh`

**Files:**
- Modify: `infra-ctl.sh` (add function after `cmd_enable_kargo`, around line 817)

- [ ] **Step 1: Add `cmd_remove_app` function**

Add this function after `cmd_enable_kargo` (after line 817) in `infra-ctl.sh`:

```bash
cmd_remove_app() {
    require_gum

    if [[ $# -eq 0 ]]; then
        print_error "Usage: infra-ctl.sh remove-app <app-name>"
        exit 1
    fi

    local app_name="$1"
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
```

- [ ] **Step 2: Commit**

```bash
git add infra-ctl.sh
git commit -m "Add remove-app command to infra-ctl.sh

- Deletes app base/overlays, ArgoCD manifests, and Kargo resources
- Restores .gitkeep in k8s/apps/ when last app is removed
- Preview and confirmation before deletion"
```

---

### Task 3: Add `cmd_remove_env` to `infra-ctl.sh`

**Files:**
- Modify: `infra-ctl.sh` (add function after `cmd_remove_app`)

- [ ] **Step 1: Add `cmd_remove_env` function**

Add this function after `cmd_remove_app` in `infra-ctl.sh`:

```bash
cmd_remove_env() {
    require_gum

    if [[ $# -eq 0 ]]; then
        print_error "Usage: infra-ctl.sh remove-env <env-name>"
        exit 1
    fi

    local env_name="$1"
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
```

- [ ] **Step 2: Commit**

```bash
git add infra-ctl.sh
git commit -m "Add remove-env command to infra-ctl.sh

- Deletes namespace, per-app overlays, ArgoCD manifests, and Kargo stages
- Repairs Kargo promotion chain when a middle environment is removed
- Updates kargo/promotion-order.txt
- Restores .gitkeep in k8s/namespaces/ when last env is removed
- Preview and confirmation before deletion"
```

---

### Task 4: Wire up dispatcher, usage, and verify

**Files:**
- Modify: `infra-ctl.sh` (update `usage()` and `main()` case statement)

- [ ] **Step 1: Update `usage()` function**

In the `usage()` function in `infra-ctl.sh`, add two lines after `edit-project`:

```
  remove-app <name>     Remove an application and all its resources
  remove-env <name>     Remove an environment and all its resources
```

The full Commands section should read:

```
Commands:
  init                  Initialize a GitOps repository skeleton
  add-app <name>        Scaffold a new application across all environments
  add-env <name>        Scaffold a new environment across all applications
  add-project <name>    Create an ArgoCD AppProject
  edit-project <name>   Modify an existing ArgoCD AppProject
  remove-app <name>     Remove an application and all its resources
  remove-env <name>     Remove an environment and all its resources
  enable-kargo          Enable Kargo and generate resources for existing apps
  preflight-check       Verify all required tools are installed
```

- [ ] **Step 2: Update `main()` case statement**

Add two cases after the `edit-project` case in the `main()` function:

```bash
        remove-app) cmd_remove_app "$@" ;;
        remove-env) cmd_remove_env "$@" ;;
```

The relevant section of the case statement should read:

```bash
        edit-project) cmd_edit_project "$@" ;;
        remove-app) cmd_remove_app "$@" ;;
        remove-env) cmd_remove_env "$@" ;;
        enable-kargo) cmd_enable_kargo "$@" ;;
```

- [ ] **Step 3: Verify script parses correctly**

Run: `bash -n infra-ctl.sh`
Expected: No output (exit 0, no syntax errors)

- [ ] **Step 4: Verify usage output**

Run: `bash infra-ctl.sh --help`
Expected: Help text includes `remove-app` and `remove-env` entries

- [ ] **Step 5: Verify error handling for missing args**

Run: `bash infra-ctl.sh remove-app`
Expected: Error message "Usage: infra-ctl.sh remove-app <app-name>"

Run: `bash infra-ctl.sh remove-env`
Expected: Error message "Usage: infra-ctl.sh remove-env <env-name>"

- [ ] **Step 6: Verify guard for non-existent app/env**

Run: `bash infra-ctl.sh remove-app nonexistent --target-dir /tmp/test-dir`
Expected: Error message about application not found (will error on missing conf first if no test dir; that's fine)

- [ ] **Step 7: Commit**

```bash
git add infra-ctl.sh
git commit -m "Wire up remove-app and remove-env in dispatcher and usage

- Add case entries in main() for both commands
- Add help text entries in usage()"
```
