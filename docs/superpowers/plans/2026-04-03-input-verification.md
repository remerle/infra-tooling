# Input Verification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verify user-provided values that can be checked before continuing, preventing cryptic downstream failures.

**Architecture:** New validation functions in `lib/common.sh`, called at input collection points in `infra-ctl.sh`, `cluster-ctl.sh`, and `secret-ctl.sh`. `gh` CLI added as a required dependency. Hard failures re-prompt; warnings print and continue.

**Tech Stack:** Bash, gh CLI, GitHub API, OCI distribution API

---

### Task 1: Add `require_gh` and `validate_positive_integer` to `lib/common.sh`

**Files:**
- Modify: `lib/common.sh:103-152` (dependency checking section)
- Modify: `lib/common.sh:202-228` (input validation section)

- [ ] **Step 1: Add `require_gh()` function**

Add after `require_helm()` (line 152), before `preflight_check()`:

```bash
require_gh() {
    if ! command -v gh &>/dev/null; then
        echo "ERROR: 'gh' (GitHub CLI) is required but not installed." >&2
        echo "  Install: brew install gh" >&2
        echo "  Or visit: https://cli.github.com/" >&2
        exit 1
    fi

    if ! gh auth status &>/dev/null; then
        echo "ERROR: 'gh' is not authenticated." >&2
        echo "  Run: gh auth login" >&2
        exit 1
    fi
}
```

- [ ] **Step 2: Add `validate_positive_integer()` function**

Add after `validate_k8s_name()` (line 228):

```bash
# Validates that a value is a positive integer.
# Returns 0 on success, 1 on failure (prints error message).
# Usage: validate_positive_integer <value> <label>
validate_positive_integer() {
    local value="$1"
    local label="${2:-value}"

    if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -eq 0 ]]; then
        print_error "${label} must be a positive integer (got '${value}')."
        return 1
    fi
}
```

- [ ] **Step 3: Add `validate_port()` function**

Add after `validate_positive_integer()`:

```bash
# Validates that a value is a valid TCP/UDP port number (1-65535).
# Returns 0 on success, 1 on failure (prints error message).
# Usage: validate_port <value>
validate_port() {
    local value="$1"

    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        print_error "Port must be a number (got '${value}')."
        return 1
    fi

    if [[ "$value" -lt 1 || "$value" -gt 65535 ]]; then
        print_error "Port must be between 1 and 65535 (got '${value}')."
        return 1
    fi
}
```

- [ ] **Step 4: Commit**

```bash
git add lib/common.sh
git commit -m "Add require_gh, validate_positive_integer, and validate_port

- require_gh checks gh CLI is installed and authenticated
- validate_positive_integer checks for non-zero positive integers
- validate_port checks TCP/UDP port range 1-65535"
```

---

### Task 2: Add `validate_github_pat` to `lib/common.sh`

**Files:**
- Modify: `lib/common.sh` (input validation section, after validate_port)

- [ ] **Step 1: Add `validate_github_pat()` function**

Add after `validate_port()`:

```bash
# Validates a GitHub Personal Access Token by checking authentication and required scopes.
# Returns 0 on success, 1 on failure (prints error message).
# Usage: validate_github_pat <pat> <required_scope> [<required_scope> ...]
validate_github_pat() {
    local pat="$1"
    shift
    local required_scopes=("$@")

    # Check authentication
    local response headers http_code
    headers="$(mktemp)"
    http_code="$(curl -s -o /dev/null -w '%{http_code}' -D "$headers" \
        -H "Authorization: Bearer ${pat}" \
        -H "Accept: application/vnd.github+json" \
        https://api.github.com/user)"

    if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
        rm -f "$headers"
        print_error "GitHub PAT is invalid or expired (HTTP ${http_code})."
        return 1
    fi

    if [[ "$http_code" != "200" ]]; then
        rm -f "$headers"
        print_error "GitHub API returned unexpected status ${http_code}."
        return 1
    fi

    # Check scopes (fine-grained tokens don't return X-OAuth-Scopes)
    local scopes_header
    scopes_header="$(grep -i '^x-oauth-scopes:' "$headers" | sed 's/^[^:]*: *//' | tr -d '\r')"
    rm -f "$headers"

    # Fine-grained PATs don't have X-OAuth-Scopes header; skip scope check for those
    if [[ -z "$scopes_header" ]]; then
        return 0
    fi

    local scope
    for scope in "${required_scopes[@]}"; do
        if ! echo "$scopes_header" | tr ',' '\n' | sed 's/^ *//' | grep -qx "$scope"; then
            print_error "GitHub PAT is missing required scope: '${scope}'."
            print_info "Current scopes: ${scopes_header}"
            return 1
        fi
    done
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/common.sh
git commit -m "Add validate_github_pat for PAT auth and scope verification

- Checks token authenticates against GitHub API
- Verifies required OAuth scopes are present
- Skips scope check for fine-grained PATs (no X-OAuth-Scopes header)"
```

---

### Task 3: Add `validate_github_repo` and `validate_image_repo` to `lib/common.sh`

**Files:**
- Modify: `lib/common.sh` (input validation section, after validate_github_pat)

- [ ] **Step 1: Add `validate_github_repo()` function**

Add after `validate_github_pat()`:

```bash
# Validates a GitHub repository URL by attempting to access it via gh CLI.
# Prints a warning on failure but returns 0 (warning, not a blocker).
# Usage: validate_github_repo <url>
validate_github_repo() {
    local url="$1"

    # Extract owner/repo from URL
    local owner_repo
    if [[ "$url" =~ github\.com[:/]([^/]+/[^/.]+) ]]; then
        owner_repo="${BASH_REMATCH[1]}"
        # Strip .git suffix if present
        owner_repo="${owner_repo%.git}"
    else
        print_warning "Could not parse GitHub owner/repo from URL: ${url}"
        return 0
    fi

    if ! gh repo view "$owner_repo" --json name &>/dev/null; then
        print_warning "Repository '${owner_repo}' is not accessible. It may not exist yet or may be private."
        return 0
    fi
}
```

- [ ] **Step 2: Add `validate_image_repo()` function**

Add after `validate_github_repo()`:

```bash
# Validates a container image repository reference.
# Format check is a hard failure (returns 1). Registry check is a warning (returns 0).
# Usage: validate_image_repo <ref>
#   Returns: 0 on valid format (with optional registry warning), 1 on invalid format.
validate_image_repo() {
    local ref="$1"

    # Must not be empty
    if [[ -z "$ref" ]]; then
        print_error "Image repository cannot be empty."
        return 1
    fi

    # Must contain at least one slash (registry/repo or registry/org/repo)
    if [[ "$ref" != */* ]]; then
        print_error "Image repository must include a registry prefix (e.g., ghcr.io/owner/app)."
        return 1
    fi

    # Must not contain a tag (colon followed by an alpha char indicates a tag, not a port)
    if [[ "$ref" =~ :[a-zA-Z] ]]; then
        print_error "Image repository must not include a tag (got '${ref}')."
        print_info "Kargo discovers tags automatically. Provide only the repository, e.g., ghcr.io/owner/app"
        return 1
    fi

    # Registry check (warning only)
    # For ghcr.io, use gh api; for others, try OCI distribution API
    local registry="${ref%%/*}"
    local repo_path="${ref#*/}"

    if [[ "$registry" == "ghcr.io" ]]; then
        # gh api for GHCR uses the /user/packages endpoint or /orgs endpoint
        # Simpler: try to list tags via OCI
        local tag_url="https://${registry}/v2/${repo_path}/tags/list"
        local http_code
        http_code="$(curl -s -o /dev/null -w '%{http_code}' \
            -H "Authorization: Bearer $(gh auth token 2>/dev/null || true)" \
            "$tag_url" 2>/dev/null)" || true
        if [[ "$http_code" != "200" ]]; then
            print_warning "Image repository '${ref}' not found in registry. It may not exist yet."
        fi
    else
        local tag_url="https://${registry}/v2/${repo_path}/tags/list"
        local http_code
        http_code="$(curl -s -o /dev/null -w '%{http_code}' "$tag_url" 2>/dev/null)" || true
        if [[ "$http_code" != "200" ]]; then
            print_warning "Image repository '${ref}' not found in registry. It may not exist yet."
        fi
    fi
}
```

- [ ] **Step 3: Commit**

```bash
git add lib/common.sh
git commit -m "Add validate_github_repo and validate_image_repo

- validate_github_repo checks repo accessibility via gh CLI (warning only)
- validate_image_repo enforces OCI format and checks registry (format: hard fail, registry: warning)"
```

---

### Task 4: Add `validate_secret_key` to `lib/common.sh`

**Files:**
- Modify: `lib/common.sh` (input validation section, after validate_image_repo)

- [ ] **Step 1: Add `validate_secret_key()` function**

Add after `validate_image_repo()`:

```bash
# Warns if a secret key name does not follow uppercase environment variable convention.
# Always returns 0 (warning only, never blocks).
# Usage: validate_secret_key <key>
validate_secret_key() {
    local key="$1"

    if ! [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
        print_warning "Secret key '${key}' is not uppercase. Convention is uppercase with underscores (e.g., DATABASE_URL)."
    fi
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/common.sh
git commit -m "Add validate_secret_key for env var naming convention warning"
```

---

### Task 5: Add `gh` to `preflight_check` in `cluster-ctl.sh` and `infra-ctl.sh`

**Files:**
- Modify: `cluster-ctl.sh:634-651` (cmd_preflight_check)
- Modify: `infra-ctl.sh` (cmd_preflight_check, find the function)
- Modify: `lib/common.sh:158-200` (preflight_check function, add gh version detection)

- [ ] **Step 1: Add `gh` version detection to `preflight_check()` in `lib/common.sh`**

In the `preflight_check()` function's case statement (around line 171), add a case for gh:

```bash
                gh) version="$(gh --version 2>/dev/null | head -1 | awk '{print $NF}' || true)" ;;
```

Add this line after the `yq)` case (line 176).

- [ ] **Step 2: Add `gh` to `cluster-ctl.sh` `cmd_preflight_check`**

In `cmd_preflight_check()` (line 634), add `"gh:brew install gh"` to the `preflight_check` call. The full call becomes:

```bash
cmd_preflight_check() {
    echo "  cluster-ctl.sh dependencies:"
    preflight_check \
        "gum:brew install gum" \
        "gh:brew install gh" \
        "k3d:brew install k3d" \
        "kubectl:brew install kubectl" \
        "jq:brew install jq" \
        "helm:brew install helm" \
        "docker:https://docs.docker.com/get-docker/"

    if command -v docker &>/dev/null; then
        if docker info &>/dev/null; then
            printf "  ✓ %-12s %s\n" "docker" "daemon running"
        else
            printf "  ✗ %-12s %s\n" "docker" "daemon NOT running (start Docker or OrbStack)"
        fi
    fi
}
```

- [ ] **Step 3: Add `gh` to `infra-ctl.sh` `cmd_preflight_check`**

Find `cmd_preflight_check` in `infra-ctl.sh` and add `"gh:brew install gh"` to its preflight_check call.

- [ ] **Step 4: Commit**

```bash
git add lib/common.sh cluster-ctl.sh infra-ctl.sh
git commit -m "Add gh CLI to preflight checks in cluster-ctl and infra-ctl

- Add gh version detection to preflight_check function
- Include gh in dependency lists for both scripts"
```

---

### Task 6: Wire up validation in `cluster-ctl.sh`

**Files:**
- Modify: `cluster-ctl.sh:46-104` (cmd_init_cluster - agent nodes validation)
- Modify: `cluster-ctl.sh:388-441` (cmd_add_repo_creds - PAT validation)
- Modify: `cluster-ctl.sh:443-559` (cmd_add_kargo_creds - PAT validation)

- [ ] **Step 1: Add `require_gh` to `cmd_add_repo_creds` and `cmd_add_kargo_creds`**

In `cmd_add_repo_creds()` (line 388), add `require_gh` after `require_gum`:

```bash
cmd_add_repo_creds() {
    require_gum
    require_gh
    require_cmd "kubectl" "brew install kubectl"
    load_conf
```

In `cmd_add_kargo_creds()` (line 443), add `require_gh` after `require_gum`:

```bash
cmd_add_kargo_creds() {
    require_gum
    require_gh
    require_cmd "kubectl" "brew install kubectl"
    load_conf
```

- [ ] **Step 2: Add agent nodes validation with re-prompt loop in `cmd_init_cluster`**

Replace lines 82-83:

```bash
    local agents
    agents="$(gum input --value "3" --prompt "Agent nodes: ")"
```

With:

```bash
    local agents
    while true; do
        agents="$(gum input --value "3" --prompt "Agent nodes: ")"
        validate_positive_integer "$agents" "Agent nodes" && break
    done
```

- [ ] **Step 3: Add `validate_k8s_name` for cluster name in `cmd_init_cluster`**

After the empty check for cluster name (line 69-72), add:

```bash
    if [[ -z "$cluster_name" ]]; then
        print_error "Cluster name is required."
        exit 1
    fi

    validate_k8s_name "$cluster_name" "Cluster name"
```

- [ ] **Step 4: Add PAT validation with re-prompt loop in `cmd_add_repo_creds`**

Replace lines 418-423:

```bash
    local pat
    pat="$(gum input --password --prompt "GitHub PAT: ")"
    if [[ -z "$pat" ]]; then
        print_error "A GitHub PAT is required."
        exit 1
    fi
```

With:

```bash
    local pat
    while true; do
        pat="$(gum input --password --prompt "GitHub PAT: ")"
        if [[ -z "$pat" ]]; then
            print_error "A GitHub PAT is required."
            continue
        fi
        if validate_github_pat "$pat" "repo"; then
            break
        fi
        print_info "Please enter a valid PAT with the required scopes."
    done
```

- [ ] **Step 5: Add PAT validation with re-prompt loop in `cmd_add_kargo_creds`**

Replace lines 516-521:

```bash
    local pat
    pat="$(gum input --password --prompt "GitHub PAT: ")"
    if [[ -z "$pat" ]]; then
        print_error "A GitHub PAT is required."
        exit 1
    fi
```

With:

```bash
    local pat
    while true; do
        pat="$(gum input --password --prompt "GitHub PAT: ")"
        if [[ -z "$pat" ]]; then
            print_error "A GitHub PAT is required."
            continue
        fi
        if validate_github_pat "$pat" "repo" "read:packages"; then
            break
        fi
        print_info "Please enter a valid PAT with the required scopes."
    done
```

- [ ] **Step 6: Commit**

```bash
git add cluster-ctl.sh
git commit -m "Wire up input validation in cluster-ctl.sh

- Validate agent node count is a positive integer (re-prompt on failure)
- Validate cluster name with validate_k8s_name
- Validate GitHub PATs for auth and required scopes (re-prompt on failure)
- Add require_gh to commands that validate PATs"
```

---

### Task 7: Wire up validation in `infra-ctl.sh`

**Files:**
- Modify: `infra-ctl.sh:8-43` (cmd_init - repo URL validation)
- Modify: `infra-ctl.sh:161-163` (cmd_add_app - port validation)
- Modify: `infra-ctl.sh:255-257` (cmd_add_app - image repo validation)
- Modify: `infra-ctl.sh:558-571` (cmd_add_project - repo URLs validation)
- Modify: `infra-ctl.sh:684-693` (cmd_edit_project - repo URLs validation)
- Modify: `infra-ctl.sh:825-827` (cmd_enable_kargo - image repo validation)

- [ ] **Step 1: Add `require_gh` to `cmd_init` and validate repo URL**

Add `require_gh` after `require_gum` in `cmd_init()` (line 9):

```bash
cmd_init() {
    require_gum
    require_gh
```

After the empty check for repo_url (line 33-36), add the validation call:

```bash
    if [[ -z "$repo_url" ]]; then
        print_error "Repository URL is required."
        exit 1
    fi

    validate_github_repo "$repo_url"
```

- [ ] **Step 2: Add port validation with re-prompt loop in `cmd_add_app`**

Replace lines 162-163:

```bash
    local port
    port="$(gum input --value "8080" --prompt "Container port: ")"
```

With:

```bash
    local port
    while true; do
        port="$(gum input --value "8080" --prompt "Container port: ")"
        validate_port "$port" && break
    done
```

- [ ] **Step 3: Add image repo validation with re-prompt loop in `cmd_add_app`**

Replace lines 256-257 (the Kargo image repo prompt):

```bash
        local image_repo
        image_repo="$(gum input --value "ghcr.io/${REPO_OWNER}/${app_name}" --header "Container image repository for Kargo (no tag):")"
```

With:

```bash
        local image_repo
        while true; do
            image_repo="$(gum input --value "ghcr.io/${REPO_OWNER}/${app_name}" --header "Container image repository for Kargo (no tag):")"
            validate_image_repo "$image_repo" && break
        done
```

- [ ] **Step 4: Add repo URL validation in `cmd_add_project`**

After the CSV is split into individual repos in `cmd_add_project` (around line 564-569), add validation for each repo. Replace:

```bash
        IFS=',' read -ra repos <<<"$repos_input"
        local repo
        for repo in "${repos[@]}"; do
            repo="$(echo "$repo" | xargs)" # trim whitespace
            source_repos_block+="    - ${repo}"$'\n'
        done
```

With:

```bash
        IFS=',' read -ra repos <<<"$repos_input"
        local repo
        for repo in "${repos[@]}"; do
            repo="$(echo "$repo" | xargs)" # trim whitespace
            validate_github_repo "$repo"
            source_repos_block+="    - ${repo}"$'\n'
        done
```

- [ ] **Step 5: Add repo URL validation in `cmd_edit_project`**

Apply the same pattern in `cmd_edit_project` (around lines 687-692). Replace:

```bash
        IFS=',' read -ra repos <<<"$repos_input"
        local repo
        for repo in "${repos[@]}"; do
            repo="$(echo "$repo" | xargs)"
            source_repos_block+="    - ${repo}"$'\n'
        done
```

With:

```bash
        IFS=',' read -ra repos <<<"$repos_input"
        local repo
        for repo in "${repos[@]}"; do
            repo="$(echo "$repo" | xargs)"
            validate_github_repo "$repo"
            source_repos_block+="    - ${repo}"$'\n'
        done
```

- [ ] **Step 6: Add image repo validation in `cmd_enable_kargo`**

Replace line 827:

```bash
            image_repo="$(gum input --value "ghcr.io/${REPO_OWNER}/${app}" --header "Container image repository for ${app} (no tag):")"
```

With:

```bash
            while true; do
                image_repo="$(gum input --value "ghcr.io/${REPO_OWNER}/${app}" --header "Container image repository for ${app} (no tag):")"
                validate_image_repo "$image_repo" && break
            done
```

- [ ] **Step 7: Commit**

```bash
git add infra-ctl.sh
git commit -m "Wire up input validation in infra-ctl.sh

- Validate repo URL via gh on init (warning only)
- Validate container port in add-app (re-prompt on failure)
- Validate image repository format and registry in add-app and enable-kargo
- Validate repo URLs in add-project and edit-project (warning only)
- Add require_gh to cmd_init"
```

---

### Task 8: Wire up validation in `secret-ctl.sh`

**Files:**
- Modify: `secret-ctl.sh:136-159` (cmd_add - secret key validation)

- [ ] **Step 1: Add secret key validation in `cmd_add`**

After line 143 (the empty check for key), add the validation call. The block currently reads:

```bash
        if [[ -z "$key" ]]; then
            break
        fi
```

Add after it:

```bash
        validate_secret_key "$key"
```

So the full block becomes:

```bash
        if [[ -z "$key" ]]; then
            break
        fi

        validate_secret_key "$key"
```

- [ ] **Step 2: Commit**

```bash
git add secret-ctl.sh
git commit -m "Wire up secret key name validation in secret-ctl.sh

- Warn when secret key names don't follow uppercase convention"
```

---

### Task 9: Update agent context documentation

**Files:**
- Modify: `AGENTS.md` (the agent context file referenced in the system prompt)

- [ ] **Step 1: Update the function inventory in AGENTS.md**

Add the new functions to the `lib/common.sh` function inventory section under the appropriate categories.

Under **Dependency checking:** add:
```
- `require_gh()` -- exits with an error if `gh` is not on PATH or not authenticated
```

Under **Input validation:** add:
```
- `validate_positive_integer(value, label)` -- validates a positive integer; returns 1 with error on failure
- `validate_port(value)` -- validates a TCP/UDP port number (1-65535); returns 1 with error on failure
- `validate_github_pat(pat, required_scopes...)` -- validates a GitHub PAT for authentication and required OAuth scopes; returns 1 on failure
- `validate_github_repo(url)` -- checks GitHub repo accessibility via `gh`; prints warning on failure but returns 0
- `validate_image_repo(ref)` -- validates OCI image reference format (returns 1) and checks registry (prints warning); must not contain a tag
- `validate_secret_key(key)` -- warns if key doesn't match uppercase env var convention; always returns 0
```

- [ ] **Step 2: Add `gh` to the "Why gum is required" section or add a new section**

Add a new subsection under "Key decisions":

```markdown
### Why gh is required

The `gh` CLI is a hard dependency for `cluster-ctl.sh` and `infra-ctl.sh`. It is used to verify GitHub repository URLs and validate GitHub PATs (authentication + scope checking). Both scripts check for it at startup via `require_gh()`, which also verifies the user is authenticated (`gh auth status`).
```

- [ ] **Step 3: Commit**

```bash
git add AGENTS.md
git commit -m "Update agent context with new validation functions and gh dependency"
```
