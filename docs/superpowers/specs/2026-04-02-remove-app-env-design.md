# Design: `remove-app` and `remove-env` commands for infra-ctl.sh

## Summary

Add `remove-app <name>` and `remove-env <name>` commands to `infra-ctl.sh` that cleanly remove all generated files for an application or environment, including Kargo resources when enabled.

## `remove-app <name>`

### Files deleted

- `k8s/apps/<app>/` (entire directory: base + all overlays)
- `argocd/apps/<app>-<env>.yaml` for every detected environment
- `kargo/<app>/` (entire directory: project, warehouse, all stages) if Kargo enabled

### Flow

1. `require_gum`
2. Validate name with `validate_k8s_name`
3. `load_conf`
4. Guard: `k8s/apps/<app>/` must exist, exit with error if not
5. Detect all environments via `detect_envs`
6. Build list of files/dirs to delete
7. Preview: print each file/dir that will be removed
8. `gum confirm` before proceeding
9. Delete all listed files/dirs
10. Restore `.gitkeep` in `k8s/apps/` if directory is now empty (no subdirectories)
11. Print summary via `print_removed`

## `remove-env <name>`

### Files deleted

- `k8s/namespaces/<env>.yaml`
- `k8s/apps/<app>/overlays/<env>/` for every detected app that has that overlay
- `argocd/apps/<app>-<env>.yaml` for every detected app
- `kargo/<app>/<env>-stage.yaml` for every app with Kargo resources (if Kargo enabled)

### Kargo chain repair

When Kargo is enabled and the removed environment is in `kargo/promotion-order.txt`:

1. Identify the downstream environment (next in promotion order after the removed env)
2. Remove the env line from `promotion-order.txt`
3. For each app with a Kargo directory:
   - If the downstream stage exists, regenerate it:
     - If it is now first in the chain (no upstream), render from `stage-direct.yaml` (sources from warehouse)
     - Otherwise, render from `stage-promoted.yaml` pointing to the new upstream (the env before the removed one)
   - Read `image_repo` from the app's existing `warehouse.yaml` (same approach as `cmd_add_env`)

### Flow

1. `require_gum`
2. Validate name with `validate_k8s_name`
3. `load_conf`
4. Guard: `k8s/namespaces/<env>.yaml` must exist, exit with error if not
5. Detect all apps via `detect_apps`
6. If Kargo enabled, `read_promotion_order` and compute chain repair info
7. Build list of files/dirs to delete and stages to regenerate
8. Preview: print deletions and any regenerations
9. `gum confirm` before proceeding
10. Delete all listed files/dirs
11. If Kargo enabled:
    - Remove env from `kargo/promotion-order.txt`
    - Regenerate downstream stages as computed in step 6
12. Restore `.gitkeep` in `k8s/namespaces/` if directory is now empty
13. Print summary of deleted files; separately note any regenerated stages

## Changes to common.sh

Add `print_removed(files...)` helper, symmetric with `print_summary`:

```bash
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

## Changes to infra-ctl.sh

- Add `cmd_remove_app()` function
- Add `cmd_remove_env()` function
- Add `remove-app` and `remove-env` cases in the `main()` dispatcher
- Add entries to the `usage()` help text

## Edge cases

- App does not exist: exit with error
- Env does not exist: exit with error
- Kargo disabled: skip all Kargo file deletion and chain repair
- Kargo enabled but app has no `kargo/<app>/` directory: skip that app's Kargo cleanup
- Removing last env: `k8s/namespaces/` gets `.gitkeep` restored
- Removing last app: `k8s/apps/` gets `.gitkeep` restored
- Removing an env not in promotion-order.txt: skip chain repair for that env (just delete the stage files if they exist)
- Removing the first env in the chain: downstream becomes the new first, regenerated as `stage-direct.yaml`
- Removing the last env in the chain: no downstream to repair
- Removing a middle env: downstream gets re-linked to the previous env
