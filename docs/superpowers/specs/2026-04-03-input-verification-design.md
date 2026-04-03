# Input Verification

Verify user-provided values that can be checked before continuing, rather than letting bad input cause cryptic failures downstream.

## Problem

The scripts collect several inputs (GitHub PATs, repo URLs, container image references, port numbers, node counts) with minimal or no validation. Bad input is only caught later when a `kubectl`, `helm`, or ArgoCD operation fails with an unrelated error message. Users waste time debugging infrastructure failures that were actually typos.

## Design Decisions

- **Always verify against external systems** when the input references one (GitHub API, container registry, Git remote). No "format only" half-measures.
- **`gh` CLI becomes a required dependency** for scripts that interact with GitHub (cluster-ctl.sh, infra-ctl.sh). It handles auth automatically and gives better error messages than raw `curl`.
- **Hard failures re-prompt the user.** Warnings print but continue. The distinction: if the input is definitely wrong (port out of range, PAT returns 401), block. If it might be wrong due to external state (repo not created yet, image not pushed yet), warn.
- **No password complexity enforcement** for the Kargo admin password. This is a local dev cluster; the confirmation prompt is sufficient.
- **Secret key names warn on non-uppercase** but don't block, since Kubernetes allows any key name and some apps expect specific casing.

## New Dependency

`gh` (GitHub CLI) is required by `cluster-ctl.sh` and `infra-ctl.sh`. A new `require_gh()` function in `lib/common.sh` checks that `gh` is installed and authenticated (`gh auth status`). Both scripts call it at startup alongside `require_gum`.

## New Validation Functions in `lib/common.sh`

### `require_gh()`

Checks `gh` is on PATH and authenticated. Exits with install instructions if missing, exits with "run `gh auth login`" if not authenticated.

### `validate_port(value)`

Checks the value is a positive integer in range 1-65535. Returns 1 on failure with an error message describing what's wrong.

### `validate_positive_integer(value, label)`

Checks the value is a positive integer (> 0). Returns 1 on failure with an error message using the provided label.

### `validate_github_repo(url)`

Extracts the `owner/repo` from the URL (HTTPS or SSH format) and runs `gh repo view owner/repo --json name`. On failure, prints a warning ("repository not accessible -- it may not exist yet or may be private") and returns 0. This is a warning, not a blocker.

### `validate_github_pat(pat, required_scopes...)`

1. Calls `GET https://api.github.com/user` with the PAT as a Bearer token.
2. If 401/403, fails with "PAT is invalid or expired."
3. Reads the `X-OAuth-Scopes` response header and checks each required scope is present.
4. If a required scope is missing, fails with "PAT is missing required scope: `<scope>`".
5. Returns 1 on failure (hard failure, re-prompt).

### `validate_image_repo(ref)`

1. Format check: must not contain a `:` followed by a tag (allows `:` for port in registry URL). Regex: reject if matches `:[a-zA-Z]` (tag portion). Must be non-empty and contain at least one `/`.
2. Registry check: attempts to query the registry for the repository. Uses `gh api` for `ghcr.io` images, or `curl` for other registries to hit the OCI distribution API (`/v2/<name>/tags/list`). On failure, prints a warning ("image repository not found in registry -- it may not exist yet") and returns 0. This is a warning, not a blocker.

### `validate_secret_key(key)`

Checks the key against `^[A-Z][A-Z0-9_]*$`. If it doesn't match, prints a warning ("secret key names are conventionally uppercase, e.g., DATABASE_URL") and returns 0. This is a warning, not a blocker.

## Where Each Validator Is Called

### `infra-ctl.sh`

| Function | Input | Validator | Behavior on failure |
|----------|-------|-----------|-------------------|
| `cmd_init` | Repository URL | `validate_github_repo` | Warning, continue |
| `cmd_add_app` | Container port | `validate_port` | Re-prompt |
| `cmd_add_app` | Image repository (Kargo) | `validate_image_repo` | Format: re-prompt. Registry: warning |
| `cmd_add_project` | Allowed repo URLs (CSV) | `validate_github_repo` per URL | Warning per URL, continue |
| `cmd_edit_project` | Allowed repo URLs (CSV) | `validate_github_repo` per URL | Warning per URL, continue |
| `cmd_enable_kargo` | Image repository (per app) | `validate_image_repo` | Format: re-prompt. Registry: warning |

### `cluster-ctl.sh`

| Function | Input | Validator | Behavior on failure |
|----------|-------|-----------|-------------------|
| `cmd_init_cluster` | Cluster name | `validate_k8s_name` (already exists) | Error, exit |
| `cmd_init_cluster` | Agent nodes | `validate_positive_integer` | Re-prompt |
| `cmd_add_repo_creds` | GitHub PAT | `validate_github_pat` with `repo` scope | Re-prompt |
| `cmd_add_kargo_creds` | GitHub PAT | `validate_github_pat` with `read:packages` scope | Re-prompt |

### `secret-ctl.sh`

| Function | Input | Validator | Behavior on failure |
|----------|-------|-----------|-------------------|
| `cmd_add` | Secret key name | `validate_secret_key` | Warning, continue |

## Re-prompt Pattern

For hard-failure validations in interactive prompts, wrap the input + validation in a loop:

```bash
while true; do
    port=$(gum input --value "8080" --prompt "Container port: ")
    validate_port "$port" && break
done
```

The validator prints the error message. The loop re-displays the prompt until a valid value is entered.

## Scope Exclusions

- **Kargo admin password**: no complexity enforcement (local dev cluster)
- **Project description**: no validation (free text)
- **Secret values**: no validation (opaque by nature)
- **Namespace selections from `gum choose`**: already constrained to valid detected values
- **Role/username/SA name**: already validated by `validate_k8s_name`
