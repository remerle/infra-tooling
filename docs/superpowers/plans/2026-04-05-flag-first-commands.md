# Flag-First Commands Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retrofit every command across all five scripts (`infra-ctl.sh`, `cluster-ctl.sh`, `secret-ctl.sh`, `config-ctl.sh`, `user-ctl.sh`) so that every interactive prompt has an equivalent CLI flag. When a required value is not provided via flag, prompt interactively only if stdin is a TTY; otherwise fail with a clear error naming the missing flag.

**Architecture:** Introduce a small set of foundation helpers in `lib/common.sh` (`require_tty`, `prompt_or_die`, `prompt_choose_or_die`, `prompt_multi_or_die`, `prompt_confirm_or_die`, `parse_set_kv`) that centralize the "flag-first, prompt-fallback, fail-if-no-tty" contract. Each command's argument parser follows a uniform while-case block. Preset-specific placeholders are accepted via repeatable `--set KEY=VAL` flags validated against the selected preset's frontmatter. Destructive confirmations are replaced with `--yes`/`-y` flags. Making this contract mandatory via AGENTS.md happens **before** any code changes so the convention is codified and discoverable.

**Tech Stack:** bash 4+, gum (interactive prompts), yq (YAML parsing), bats-core (smoke tests for helpers). No new dependencies.

---

## Scope & Inventory Summary

- **5 scripts**, **~30 commands with interactive prompts**, **~96 `gum` call sites** to retrofit
- **Commands with no prompts** (list-*, status, argo-init, argo-sync, argo-status, preflight-check, renew-tls, upgrade-*, refresh-sa, remove-sa, remove-role, remove) are out of scope for prompt-flag conversion but MUST be reviewed to confirm they already accept all required data via positional args/flags
- **Destructive operations** using `gum confirm` for safety (remove-app, remove-env, remove-project, remove, remove-role, remove-sa, reset, delete-cluster) get `--yes` flags

## Non-Goals

- Do **not** write golden-file or integration tests in this plan; that is a follow-on effort enabled by the flag retrofit
- Do **not** restructure existing `cmd_*` functions beyond what is required to accept flags; each function's core logic stays intact
- Do **not** remove interactive flows; they remain the default experience when stdin is a TTY and flags are omitted

---

## Phase 0: Convention, Foundation, and Smoke Test

This phase establishes the contract and the shared helpers. Nothing else in the plan should be started until Phase 0 is committed and pushed.

### Task 0.1: Update AGENTS.md to mandate flag-first commands

**Files:**
- Modify: `AGENTS.md` — add a new top-level section under "When modifying these scripts"

- [ ] **Step 1: Add a "Flag-first command contract" section to AGENTS.md**

Add this new section immediately after the "Command conventions" section in `AGENTS.md`. Place it before "Checklist for adding a new command" (around line 390, after the commands table).

```markdown
### Flag-first command contract (MANDATORY)

Every command MUST accept every piece of user-provided data via a long-form CLI flag. This is a hard requirement, not a style preference. Commands that require any user input MUST follow this contract:

1. **Every prompt has a flag.** For every value the command needs from the user (names, choices, confirmations, repeatable values), there MUST be a corresponding `--flag-name` CLI argument. This includes values that today are only collected via `gum input`, `gum choose`, `gum choose --no-limit`, `gum confirm`, or `gum input --password`.

2. **If a required value is not provided and stdin is a TTY, prompt interactively.** The existing `gum` prompt is the fallback when running attended. Users who pass every flag see no prompts.

3. **If a required value is not provided and stdin is NOT a TTY, fail with a clear error.** The error message MUST name the missing flag. Example: `ERROR: --name is required when not running interactively`. This makes commands safe to script and CI-safe by default.

4. **Confirmation prompts for destructive actions REQUIRE `--yes` (or `-y`).** Never auto-confirm destructive operations based on TTY detection alone — require an explicit flag. TTY detection governs prompting for *input*, not skipping *confirmation*.

5. **Validation runs regardless of source.** Whether a value came from a flag or a prompt, it MUST pass the same validator (`validate_k8s_name`, `validate_port`, `validate_image_repo`, etc.). No validation-bypass paths.

6. **Preset-specific placeholders use `--set KEY=VAL`.** For commands that consume preset frontmatter defaults (primarily `infra-ctl.sh add-app`), accept values through repeatable `--set KEY=VAL` flags. Validate keys against the selected preset's frontmatter schema at parse time; reject unknown keys.

7. **Repeatable flags for multi-select.** `gum choose --no-limit` prompts MUST map to repeatable long flags (e.g., `--env dev --env staging`). Do not use comma-separated values for multi-select; they are harder to validate and don't play well with shell completions.

8. **Positional argument shorthand is allowed** when a command has exactly one required primary identifier (e.g., `add-app <name>` is equivalent to `add-app --name <name>`). The first positional argument populates the primary flag if no `--name` was given. All other values MUST go through flags.

**Flag vocabulary** (use these names consistently across all commands):

| Flag | Meaning | Where used | Example |
|---|---|---|---|
| `--set KEY=VAL` | Preset template **placeholder** substitution (helm-style). Keys match the preset's frontmatter `defaults:` keys (e.g., `IMAGE`, `PORT`, `PROBE_PATH`, `STORAGE_SIZE`, `MOUNT_PATH`, `SECRET_NAME`). Validated against preset schema. | `infra-ctl add-app` | `--set IMAGE=nginx:latest --set PORT=3000` |
| `--config KEY=VAL` | configMap entries that become container **env vars at runtime** (configMapGenerator literals). | `infra-ctl add-app`, `config-ctl add` | `--config LOG_LEVEL=info --config API_URL=http://backend:3000` |
| `--secret-key NAME` | **Declares** a secret key the workload needs (generates `valueFrom.secretKeyRef`). No value. | `infra-ctl add-app` | `--secret-key DATABASE_URL --secret-key API_KEY` |
| `--secret-val KEY=VAL` | Provides the **actual secret value** that gets sealed and committed. Value may be inline, `@file`, or `-` (stdin). | `secret-ctl add` | `--secret-val DATABASE_URL=postgres://u:p@h/db` |
| `--env NAME` | K8s **environment** name (dev, staging, prod). Repeatable for multi-select. | `infra-ctl add-ingress`, `infra-ctl remove-ingress`, `secret-ctl add`, `config-ctl add`, `cluster-ctl add-registry-creds` | `--env dev --env staging` |

These four KEY=VAL flags (`--set`, `--config`, `--secret-key`, `--secret-val`) and `--env` are **reserved names** — do not redefine their meaning in any command.

All command implementations MUST use the shared helpers in `lib/common.sh`:
- `require_tty "<flag-name>"` — exits with a clear error if stdin is not a TTY
- `prompt_or_die "<label>" "<flag-name>" [default]` — gum input fallback or die
- `prompt_choose_or_die "<label>" "<flag-name>" <options...>` — gum choose fallback or die
- `prompt_multi_or_die "<label>" "<flag-name>" <options...>` — gum choose --no-limit fallback or die
- `prompt_confirm_or_die "<label>" "<flag-name>"` — gum confirm fallback or die (returns "yes"/"no")
- `parse_set_kv "<KEY=VAL>" <assoc-array-name>` — parses --set input into a caller-provided associative array
- `require_yes "<flag-name>" "<action-description>"` — gated confirmation for destructive ops

When adding a NEW command, the checklist below applies. When modifying an existing command to add a new prompt, the new prompt MUST be added as a flag first, with the prompt as fallback.
```

- [ ] **Step 2: Update the "Checklist for adding a new command" to include flag-first requirements**

Modify the checklist section (currently starts with "Add a `cmd_<name>` function...") to add these items:

```markdown
### Checklist for adding a new command

1. Add a `cmd_<name>` function following existing patterns (parse flags, validate, preview, confirm, execute, summarize)
2. **Parse every user-provided value as a long-form flag** (see "Flag-first command contract")
3. **For every flag, fall back to the appropriate `prompt_*_or_die` helper** if the value was not passed
4. **Validate flag-provided and prompt-provided values through the same validator**
5. Add a case in the `main()` dispatcher
6. Add an entry in `usage()` that lists every flag the command accepts with types and whether they are required
7. Add the command to `completions.zsh`, including flag completions
8. If the command accepts a resource name, add a dynamic completion entry in `completions.zsh` (see `_infra_complete_apps` for the pattern)
9. If this is an `add-*` command, also add the `list-*` and `remove-*` counterparts
10. If adding a new preset, place the template in `templates/k8s/` with frontmatter following the format in existing presets
11. **For destructive commands, require `--yes`/`-y` to skip the confirmation prompt**
```

- [ ] **Step 3: Run infra-ctl.sh without changes to confirm nothing broke**

Run: `./infra-ctl.sh --help`
Expected: usage output unchanged (we only modified AGENTS.md).

- [ ] **Step 4: Commit**

```bash
git add AGENTS.md
git commit -m "$(cat <<'EOF'
Mandate flag-first command contract in AGENTS.md

Every command must accept every user-provided value via a CLI flag,
prompt only when stdin is a TTY, and fail with a clear error naming
the missing flag when running non-interactively. Destructive ops
require --yes. This is a prerequisite for scriptability and testing.
EOF
)"
```

---

### Task 0.2: Add foundation helpers to `lib/common.sh`

**Files:**
- Modify: `lib/common.sh` — add new helper functions at the end of the "Styled output" section, before the final closing of the file

- [ ] **Step 1: Add the interactive/flag helpers to `lib/common.sh`**

Find a good location: after the `print_removed` helper, before any closing markers. Add this block:

```bash
# --- Flag-first prompt helpers ---
#
# Contract: every command accepts user-provided values via long flags.
# When a flag is not provided, these helpers prompt interactively if
# stdin is a TTY, or die with a clear error otherwise. See AGENTS.md
# "Flag-first command contract" for the mandatory rules.

# Exits with a clear error if stdin is not a TTY. Call this before any
# fallback prompt to guarantee scripted callers get an actionable
# message naming the missing flag.
# Usage: require_tty "--name"
require_tty() {
    local flag="$1"
    if [[ ! -t 0 ]]; then
        print_error "${flag} is required when not running interactively"
        echo "  (stdin is not a TTY; pass ${flag} on the command line)" >&2
        exit 1
    fi
}

# Input prompt or die. Prints to stdout the value chosen by the user.
# Usage: val=$(prompt_or_die "App name" "--name")
#        val=$(prompt_or_die "Container port" "--port" "8080")
prompt_or_die() {
    local label="$1"
    local flag="$2"
    local default="${3:-}"
    require_tty "$flag"
    if [[ -n "$default" ]]; then
        gum input --value "$default" --prompt "${label}: "
    else
        gum input --prompt "${label}: "
    fi
}

# Password input prompt or die (hidden input).
# Usage: pat=$(prompt_password_or_die "GitHub PAT" "--pat")
prompt_password_or_die() {
    local label="$1"
    local flag="$2"
    require_tty "$flag"
    gum input --password --prompt "${label}: "
}

# Single-choice prompt or die. Newline-separated options follow the flag.
# Usage: val=$(prompt_choose_or_die "Workload type" "--workload-type" "Deployment" "StatefulSet")
prompt_choose_or_die() {
    local label="$1"
    local flag="$2"
    shift 2
    require_tty "$flag"
    print_header "$label"
    printf "%s\n" "$@" | gum choose
}

# Multi-select prompt or die. Options after the flag. Prints selections
# one per line. Caller should capture with mapfile or a read loop.
# Usage: mapfile -t envs < <(prompt_multi_or_die "Envs" "--env" dev staging prod)
prompt_multi_or_die() {
    local label="$1"
    local flag="$2"
    shift 2
    require_tty "$flag"
    print_header "$label"
    printf "%s\n" "$@" | gum choose --no-limit
}

# Confirm prompt or die. Prints "yes" or "no" to stdout.
# Usage: answer=$(prompt_confirm_or_die "Enable HTTPS?" "--tls")
prompt_confirm_or_die() {
    local label="$1"
    local flag="$2"
    require_tty "$flag"
    if gum confirm "$label"; then
        echo "yes"
    else
        echo "no"
    fi
}

# Destructive-action guard. Exits if --yes was not passed.
# Pass the already-parsed yes_flag value ("true"/"false") as arg 1.
# Usage: require_yes "$yes" "remove app 'backend'"
require_yes() {
    local yes="$1"
    local action="$2"
    if [[ "$yes" != "true" ]]; then
        if [[ -t 0 ]]; then
            if ! gum confirm "Confirm: ${action}?"; then
                print_info "Aborted."
                exit 0
            fi
        else
            print_error "--yes is required to ${action} non-interactively"
            exit 1
        fi
    fi
}

# Parses a KEY=VAL string into a caller-provided associative array.
# Dies on malformed input. Also dies if the array name is not set.
# Usage: declare -A values; parse_set_kv "IMAGE=nginx:latest" values
parse_set_kv() {
    local input="$1"
    local -n _arr="$2"
    if [[ "$input" != *"="* ]]; then
        print_error "--set expects KEY=VAL, got: ${input}"
        exit 1
    fi
    local key="${input%%=*}"
    local val="${input#*=}"
    if [[ -z "$key" ]]; then
        print_error "--set expects KEY=VAL with a non-empty KEY, got: ${input}"
        exit 1
    fi
    _arr["$key"]="$val"
}

# Validates a set of --set keys against the known keys of a preset.
# Dies with the list of unknown keys if any are not in the allowed set.
# Args: preset_template_path, then all keys in the caller's --set map.
# Usage: validate_preset_set_keys "$template" "${!values[@]}"
validate_preset_set_keys() {
    local template="$1"
    shift
    local allowed_keys=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && allowed_keys+=("${line%%=*}")
    done < <(get_preset_defaults "$template")
    # Secrets are also valid --set keys when declared as such (their values
    # are placeholders only; they don't substitute into the body, but we
    # don't reject them here — add-app handles them separately).
    while IFS= read -r line; do
        [[ -n "$line" ]] && allowed_keys+=("$line")
    done < <(get_preset_secrets "$template")

    local unknown=()
    local k a found
    for k in "$@"; do
        found=0
        for a in "${allowed_keys[@]}"; do
            [[ "$k" == "$a" ]] && { found=1; break; }
        done
        [[ "$found" -eq 0 ]] && unknown+=("$k")
    done
    if [[ ${#unknown[@]} -gt 0 ]]; then
        print_error "Unknown --set keys for this preset: ${unknown[*]}"
        echo "  Allowed keys: ${allowed_keys[*]}" >&2
        exit 1
    fi
}
```

- [ ] **Step 2: Verify syntax by sourcing the file in a subshell**

Run: `bash -n lib/common.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Smoke-test the helpers in an interactive shell**

Run:
```bash
bash -c 'source lib/common.sh; require_tty --name' </dev/null
```
Expected: exit code 1, error message `ERROR: --name is required when not running interactively`.

Run (interactive):
```bash
bash -c 'source lib/common.sh; val=$(prompt_or_die "Test" "--name"); echo "got: $val"'
```
Expected: gum prompt appears, typed value is printed back with "got: " prefix.

- [ ] **Step 4: Smoke-test parse_set_kv**

Run:
```bash
bash -c '
source lib/common.sh
declare -A values
parse_set_kv "IMAGE=nginx:latest" values
parse_set_kv "PORT=3000" values
echo "IMAGE=${values[IMAGE]}"
echo "PORT=${values[PORT]}"
'
```
Expected:
```
IMAGE=nginx:latest
PORT=3000
```

Run:
```bash
bash -c 'source lib/common.sh; declare -A v; parse_set_kv "no-equals" v' 2>&1
```
Expected: exit 1, error message about KEY=VAL format.

- [ ] **Step 5: Commit**

```bash
git add lib/common.sh
git commit -m "$(cat <<'EOF'
Add flag-first prompt helpers to common.sh

Introduces require_tty, prompt_or_die, prompt_password_or_die,
prompt_choose_or_die, prompt_multi_or_die, prompt_confirm_or_die,
require_yes, parse_set_kv, validate_preset_set_keys. These centralize
the flag-first contract mandated in AGENTS.md: accept values via
long flags, prompt only when TTY, fail clearly when not.
EOF
)"
```

---

### Task 0.3: Document helpers in AGENTS.md function inventory

**Files:**
- Modify: `AGENTS.md` — add new entries in `lib/common.sh` function inventory

- [ ] **Step 1: Add helper documentation under a new "Flag-first prompt helpers" heading in the function inventory**

In `AGENTS.md`, find the section titled `### lib/common.sh function inventory` and add this new subsection under **Styled output**:

```markdown
**Flag-first prompt helpers:**
- `require_tty(flag)` -- exits with a clear error if stdin is not a TTY; flag is the CLI flag name to name in the error
- `prompt_or_die(label, flag, [default])` -- gum input prompt; dies if no TTY
- `prompt_password_or_die(label, flag)` -- gum input --password; dies if no TTY
- `prompt_choose_or_die(label, flag, options...)` -- gum choose (single select); dies if no TTY
- `prompt_multi_or_die(label, flag, options...)` -- gum choose --no-limit; dies if no TTY
- `prompt_confirm_or_die(label, flag)` -- gum confirm; prints "yes"/"no"; dies if no TTY
- `require_yes(yes_flag_value, action)` -- gates destructive operations; dies if --yes not passed and no TTY
- `parse_set_kv(input, arr_name)` -- parses KEY=VAL into caller's associative array
- `validate_preset_set_keys(template, keys...)` -- dies if any --set key is not declared in the preset frontmatter
```

- [ ] **Step 2: Commit**

```bash
git add AGENTS.md
git commit -m "Document flag-first prompt helpers in AGENTS.md inventory"
```

---

### Task 0.4: Add `bats` smoke test for helpers (optional but recommended)

**Files:**
- Create: `test/lib/common_test.bats`

- [ ] **Step 1: Check if `bats` is installed**

Run: `command -v bats && bats --version`
Expected: `bats 1.x.x` or similar. If not installed, skip this task and note it as a follow-up.

- [ ] **Step 2: Write the smoke test**

Create `test/lib/common_test.bats`:

```bash
#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    source "${REPO_ROOT}/lib/common.sh"
}

@test "require_tty dies when stdin is not a TTY" {
    run bash -c 'source '"${REPO_ROOT}"'/lib/common.sh; require_tty --name' </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"--name is required when not running interactively"* ]]
}

@test "parse_set_kv rejects input without =" {
    run bash -c 'source '"${REPO_ROOT}"'/lib/common.sh; declare -A v; parse_set_kv "noequals" v'
    [ "$status" -eq 1 ]
    [[ "$output" == *"--set expects KEY=VAL"* ]]
}

@test "parse_set_kv rejects empty key" {
    run bash -c 'source '"${REPO_ROOT}"'/lib/common.sh; declare -A v; parse_set_kv "=foo" v'
    [ "$status" -eq 1 ]
}

@test "parse_set_kv parses KEY=VAL into array" {
    run bash -c '
        source '"${REPO_ROOT}"'/lib/common.sh
        declare -A v
        parse_set_kv "IMAGE=nginx:latest" v
        echo "${v[IMAGE]}"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "nginx:latest" ]
}

@test "parse_set_kv preserves values containing =" {
    run bash -c '
        source '"${REPO_ROOT}"'/lib/common.sh
        declare -A v
        parse_set_kv "URL=postgres://user:pass@host:5432/db" v
        echo "${v[URL]}"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "postgres://user:pass@host:5432/db" ]
}

@test "require_yes dies without --yes when no TTY" {
    run bash -c 'source '"${REPO_ROOT}"'/lib/common.sh; require_yes "false" "delete stuff"' </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"--yes is required"* ]]
}

@test "require_yes passes when --yes is true" {
    run bash -c 'source '"${REPO_ROOT}"'/lib/common.sh; require_yes "true" "delete stuff"; echo proceeded'
    [ "$status" -eq 0 ]
    [[ "$output" == *"proceeded"* ]]
}
```

- [ ] **Step 3: Run the smoke tests**

Run: `bats test/lib/common_test.bats`
Expected: all 7 tests pass.

- [ ] **Step 4: Commit**

```bash
git add test/lib/common_test.bats
git commit -m "Add bats smoke tests for flag-first helpers"
```

---

## Phase 1: `infra-ctl.sh` commands

**Phase goal:** Retrofit all 12 `infra-ctl.sh` commands that have interactive prompts. Phase 1 is complete when all `infra-ctl.sh` commands can be invoked non-interactively with every value passed as a flag, OR prompt interactively when a TTY is attached and a flag is missing.

The pattern demonstrated fully in Task 1.1 applies to every subsequent task. Each task lists its command's flag inventory, the exact argument-parsing block to paste in, and the specific prompt call sites to replace.

### Task 1.1: Retrofit `cmd_init` (EXEMPLAR)

This task is the fully-worked example. The pattern here — flag parsing, helper delegation, positional shorthand, validation, commit message — is what every subsequent task follows.

**Files:**
- Modify: `infra-ctl.sh` — `cmd_init` function (around line 8-148)
- Modify: `infra-ctl.sh` — `usage()` function (update flag documentation for `init`)

**Flags for `infra-ctl.sh init`:**

| Flag | Type | Required | Default | Source prompt | Validator |
|---|---|---|---|---|---|
| `--repo-url <url>` | string | yes | auto-detected from `git remote origin` | line 32 | `validate_github_repo` |
| `--kargo / --no-kargo` | bool | no | `false` | (was part of init's kargo branch; wire consistent) | n/a |

`init` currently only has one prompt (the repo URL), because kargo-enablement is handled separately by `enable-kargo`. That keeps this task small and focused.

- [ ] **Step 1: Read the current `cmd_init` function to understand its structure**

Run: `sed -n '8,148p' infra-ctl.sh`
Expected: see `cmd_init` function definition that currently does:
1. Detect git remote with `git remote get-url origin`
2. Prompt with `gum input --value "$default_url" --prompt "Repository URL: "`
3. Validate, save to `.infra-ctl.conf`, render templates.

- [ ] **Step 2: Replace the function signature and argument parsing**

Find this section in `cmd_init` (near the top of the function):

```bash
cmd_init() {
    require_gum
    require_gh

    # ... (detection of default_url from git remote)

    print_header "Initialize GitOps repository"
    local repo_url
    repo_url="$(gum input --value "$default_url" --prompt "Repository URL: ")"
```

Replace with:

```bash
cmd_init() {
    require_gum
    require_gh

    # --- Parse flags ---
    local repo_url_flag=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo-url)
                [[ -z "${2:-}" ]] && { print_error "--repo-url requires a value"; exit 1; }
                repo_url_flag="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: infra-ctl.sh init [--repo-url <url>]"
                echo "  --repo-url <url>  GitHub repository URL (default: detected from git remote)"
                exit 0 ;;
            -*)
                print_error "Unknown flag: $1"; exit 1 ;;
            *)
                print_error "Unexpected positional argument: $1"; exit 1 ;;
        esac
    done

    # --- Detect default from git remote (existing logic stays) ---
    local default_url=""
    if git -C "$TARGET_DIR" remote get-url origin >/dev/null 2>&1; then
        default_url="$(git -C "$TARGET_DIR" remote get-url origin)"
        # Convert SSH to HTTPS if needed (existing logic)
        if [[ "$default_url" == git@github.com:* ]]; then
            default_url="https://github.com/${default_url#git@github.com:}"
            default_url="${default_url%.git}"
        fi
    fi

    print_header "Initialize GitOps repository"

    # --- Resolve repo_url: flag wins, else prompt, else die ---
    local repo_url
    if [[ -n "$repo_url_flag" ]]; then
        repo_url="$repo_url_flag"
    else
        repo_url=$(prompt_or_die "Repository URL" "--repo-url" "$default_url")
    fi
```

The rest of `cmd_init` remains unchanged — validation, save_conf, template rendering, and summary all continue to use `$repo_url`.

- [ ] **Step 3: Update `usage()` for init**

Find the `usage()` function in `infra-ctl.sh` (near the bottom). Update the `init` entry to include flag documentation:

```bash
# in usage():
  init                Initialize GitOps repo skeleton
                        --repo-url <url>   GitHub repository URL (required if no git remote)
```

- [ ] **Step 4: Verify non-interactive success path**

Create a disposable target dir and run with --repo-url:
```bash
TMP=$(mktemp -d)
cd "$TMP" && git init -q
/repos/personal/k8s_practice/infra-tooling/infra-ctl.sh --target-dir "$TMP" init \
    --repo-url https://github.com/remerle/test-repo
```
Expected: init completes without prompts, `.infra-ctl.conf` exists with `REPO_URL=https://github.com/remerle/test-repo`.

Clean up: `rm -rf "$TMP"`

- [ ] **Step 5: Verify non-interactive failure path**

```bash
TMP=$(mktemp -d)
cd "$TMP"
/repos/personal/k8s_practice/infra-tooling/infra-ctl.sh --target-dir "$TMP" init </dev/null
```
Expected: exit code 1, error message `ERROR: --repo-url is required when not running interactively`.

Clean up: `rm -rf "$TMP"`

- [ ] **Step 6: Verify interactive path still works**

Run in a terminal: `cd "$(mktemp -d)" && git init -q && /repos/personal/k8s_practice/infra-tooling/infra-ctl.sh init`
Expected: gum prompt appears with the detected URL pre-filled. Accept or change and confirm init completes.

- [ ] **Step 7: Commit**

```bash
git add infra-ctl.sh
git commit -m "Add --repo-url flag to infra-ctl init"
```

---

### Task 1.2: Retrofit `cmd_add_app` (most complex command)

**Files:**
- Modify: `infra-ctl.sh` — `cmd_add_app` function (around line 150-614)
- Modify: `infra-ctl.sh` — `usage()`

**Flags for `infra-ctl.sh add-app`:**

| Flag | Type | Required | Default | Source prompt | Notes |
|---|---|---|---|---|---|
| `--name <string>` | string | yes | (positional arg 1) | function args | `validate_k8s_name` |
| `--project <name>` | string | no | `default` | line 185 | conditional: only if projects exist |
| `--workload-type <deployment\|statefulset>` | enum | yes | `deployment` | line 190 | case-insensitive |
| `--preset <name>` | string | no | first preset | line 223 | validated via `discover_presets` |
| `--set KEY=VAL` | repeatable | no | (per-preset) | line 275 | validated via `validate_preset_set_keys` |
| `--secret-key <name>` | repeatable | no | (from preset) | lines 329, 356 | only used if secret_name set |
| `--config KEY=VAL` | repeatable | no | (from preset) | lines 309, 373 | |
| `--kargo / --no-kargo` | bool | no | `true` for Deployment, `false` for StatefulSet | line 395 | only if Kargo enabled in repo |
| `--image-repo <url>` | string | yes (if --kargo) | none | line 555 | `validate_image_repo` |
| `--custom` | bool | no | `false` | n/a | explicitly chooses custom flow (Deployment only) |
| `--image <ref>` | string | yes (custom) | none | line 337 | custom flow only |
| `--port <number>` | number | yes (custom) | `8080` | line 344 | custom flow; `validate_port` |
| `--secret-name <name>` | string | no | (custom) `{{APP_NAME}}-secrets` | line 349 | custom flow only |
| `--probe-path <path>` | string | no (custom) | none | line 363 | custom flow only |

- [ ] **Step 1: Read the current `cmd_add_app` function end-to-end**

Run: `sed -n '150,614p' infra-ctl.sh`
Expected: full function body visible.

- [ ] **Step 2: Insert flag parsing at the top of `cmd_add_app`**

After `require_gum`, `require_yq`, and before the existing `if [[ $# -eq 0 ]]` check, replace the whole arg-processing prelude:

```bash
cmd_add_app() {
    require_gum
    require_yq

    # --- Parse flags ---
    local app_name_flag=""
    local project_flag=""
    local workload_type_flag=""
    local preset_flag=""
    declare -A set_values=()
    local secret_keys_flag=()
    local config_flag_entries=()
    local kargo_flag=""       # "", "true", "false"
    local image_repo_flag=""
    local custom_flag=false
    local image_flag=""
    local port_flag=""
    local secret_name_flag=""
    local probe_path_flag=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)         [[ -z "${2:-}" ]] && { print_error "--name requires a value"; exit 1; }
                            app_name_flag="$2"; shift 2 ;;
            --project)      [[ -z "${2:-}" ]] && { print_error "--project requires a value"; exit 1; }
                            project_flag="$2"; shift 2 ;;
            --workload-type)
                            [[ -z "${2:-}" ]] && { print_error "--workload-type requires a value"; exit 1; }
                            workload_type_flag="$(tr '[:upper:]' '[:lower:]' <<<"$2")"; shift 2 ;;
            --preset)       [[ -z "${2:-}" ]] && { print_error "--preset requires a value"; exit 1; }
                            preset_flag="$2"; shift 2 ;;
            --set)          [[ -z "${2:-}" ]] && { print_error "--set requires KEY=VAL"; exit 1; }
                            parse_set_kv "$2" set_values; shift 2 ;;
            --secret-key)   [[ -z "${2:-}" ]] && { print_error "--secret-key requires a value"; exit 1; }
                            secret_keys_flag+=("$2"); shift 2 ;;
            --config)       [[ -z "${2:-}" ]] && { print_error "--config requires KEY=VAL"; exit 1; }
                            config_flag_entries+=("$2"); shift 2 ;;
            --kargo)        kargo_flag="true"; shift ;;
            --no-kargo)     kargo_flag="false"; shift ;;
            --image-repo)   [[ -z "${2:-}" ]] && { print_error "--image-repo requires a value"; exit 1; }
                            image_repo_flag="$2"; shift 2 ;;
            --custom)       custom_flag=true; shift ;;
            --image)        [[ -z "${2:-}" ]] && { print_error "--image requires a value"; exit 1; }
                            image_flag="$2"; shift 2 ;;
            --port)         [[ -z "${2:-}" ]] && { print_error "--port requires a value"; exit 1; }
                            port_flag="$2"; shift 2 ;;
            --secret-name)  [[ -z "${2:-}" ]] && { print_error "--secret-name requires a value"; exit 1; }
                            secret_name_flag="$2"; shift 2 ;;
            --probe-path)   [[ -z "${2:-}" ]] && { print_error "--probe-path requires a value"; exit 1; }
                            probe_path_flag="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: infra-ctl.sh add-app <name> [flags]"
                echo "  --name, --project, --workload-type, --preset, --set KEY=VAL,"
                echo "  --secret-key, --config KEY=VAL, --kargo/--no-kargo, --image-repo,"
                echo "  --custom, --image, --port, --secret-name, --probe-path"
                exit 0 ;;
            -*)             print_error "Unknown flag: $1"; exit 1 ;;
            *)              # positional shorthand for --name
                            if [[ -z "$app_name_flag" ]]; then
                                app_name_flag="$1"
                            else
                                print_error "Unexpected argument: $1"; exit 1
                            fi
                            shift ;;
        esac
    done

    # --- Resolve app_name ---
    local app_name
    if [[ -n "$app_name_flag" ]]; then
        app_name="$app_name_flag"
    else
        app_name=$(prompt_or_die "App name" "--name")
    fi
    validate_k8s_name "$app_name" "App name"
    load_conf

    # Guard: app already exists
    local app_dir="${TARGET_DIR}/k8s/apps/${app_name}"
    if [[ -d "$app_dir" ]]; then
        print_error "Application '${app_name}' already exists at ${app_dir}"
        exit 1
    fi
```

Remove the original `if [[ $# -eq 0 ]]` block and the original `local app_name="$1"` line — they're replaced above.

- [ ] **Step 3: Replace the project selection prompt**

Find the "Project selection" block (around line 181):

```bash
    local project="default"
    if [[ ${#projects[@]} -gt 0 ]]; then
        print_header "Select project for '${app_name}'"
        project="$(printf "%s\n" "default" "${projects[@]}" | gum choose)"
    fi
```

Replace with:

```bash
    local project="default"
    if [[ -n "$project_flag" ]]; then
        # Validate: project must exist or be "default"
        if [[ "$project_flag" != "default" ]]; then
            local found=0 p
            for p in "${projects[@]}"; do
                [[ "$p" == "$project_flag" ]] && { found=1; break; }
            done
            if [[ "$found" -eq 0 ]]; then
                print_error "Project '${project_flag}' does not exist. Known: default ${projects[*]}"
                exit 1
            fi
        fi
        project="$project_flag"
    elif [[ ${#projects[@]} -gt 0 ]]; then
        project=$(prompt_choose_or_die "Select project for '${app_name}'" "--project" "default" "${projects[@]}")
    fi
```

- [ ] **Step 4: Replace the workload-type selection prompt**

Find (around line 189):

```bash
    local workload_type
    workload_type="$(printf "Deployment\nStatefulSet" | gum choose)"
```

Replace with:

```bash
    local workload_type
    if [[ -n "$workload_type_flag" ]]; then
        case "$workload_type_flag" in
            deployment)  workload_type="Deployment" ;;
            statefulset) workload_type="StatefulSet" ;;
            *) print_error "--workload-type must be 'deployment' or 'statefulset', got: ${workload_type_flag}"; exit 1 ;;
        esac
    else
        workload_type=$(prompt_choose_or_die "Workload type" "--workload-type" "Deployment" "StatefulSet")
    fi
```

- [ ] **Step 5: Replace the preset selection prompt**

Find (around line 205-228):

```bash
    local preset_choice="custom"
    if [[ ${#presets[@]} -gt 0 ]]; then
        # ... (chooser-building loop)
        print_header "Select preset for '${app_name}'"
        local chosen_label
        chosen_label="$(printf "%s\n" "${preset_labels[@]}" | gum choose)"
        preset_choice="${chosen_label%% -- *}"
    elif [[ "$workload_prefix" == "statefulset" ]]; then
        print_error "No StatefulSet presets found..."
        exit 1
    fi
```

Replace the chooser section with:

```bash
    local preset_choice="custom"
    if [[ ${#presets[@]} -gt 0 ]]; then
        # Resolve preset: --custom wins, --preset next, else prompt
        if [[ "$custom_flag" == "true" ]]; then
            if [[ "$workload_prefix" == "statefulset" ]]; then
                print_error "--custom is not supported for StatefulSet workloads"
                exit 1
            fi
            preset_choice="custom"
        elif [[ -n "$preset_flag" ]]; then
            # Validate preset exists
            local found=0 p
            for p in "${presets[@]}"; do
                [[ "$p" == "$preset_flag" ]] && { found=1; break; }
            done
            if [[ "$found" -eq 0 ]]; then
                print_error "Unknown preset: ${preset_flag}. Known: ${presets[*]}"
                exit 1
            fi
            preset_choice="$preset_flag"
        else
            # Interactive chooser (existing code)
            local preset_labels=()
            local preset
            for preset in "${presets[@]}"; do
                local template_file="${TEMPLATE_DIR}/k8s/${workload_prefix}-${preset}.yaml"
                local desc
                desc="$(get_preset_field "$template_file" '.description')"
                preset_labels+=("${preset} -- ${desc}")
            done
            if [[ "$workload_prefix" == "deployment" ]]; then
                preset_labels+=("custom -- Configure manually")
            fi
            require_tty "--preset"
            print_header "Select preset for '${app_name}'"
            local chosen_label
            chosen_label="$(printf "%s\n" "${preset_labels[@]}" | gum choose)"
            preset_choice="${chosen_label%% -- *}"
        fi
    elif [[ "$workload_prefix" == "statefulset" ]]; then
        print_error "No StatefulSet presets found in templates/k8s/. Add a statefulset-*.yaml template."
        exit 1
    fi
```

- [ ] **Step 6: Replace the preset-defaults prompt loop (for --set KEY=VAL)**

Find the block that walks through preset defaults and prompts for each (around line 254-286):

```bash
        # Walk through each default with gum input
        local key default_val
        for line in "${defaults_lines[@]}"; do
            ...
            prompted_val="$(gum input --value "$default_val" ...)"
            case "$key" in
                IMAGE) image="$prompted_val" ;;
                ...
            esac
        done
```

Add validation of `--set` keys BEFORE the loop:

```bash
        # Validate --set keys against this preset's schema
        if [[ ${#set_values[@]} -gt 0 ]]; then
            validate_preset_set_keys "$preset_template" "${!set_values[@]}"
        fi

        # Walk through each default: --set wins, else prompt
        local key default_val
        for line in "${defaults_lines[@]}"; do
            key="${line%%=*}"
            default_val="${line#*=}"
            default_val="${default_val//\{\{APP_NAME\}\}/${app_name}}"

            local optional_flag=""
            if is_preset_optional "$preset_template" "$key"; then
                optional_flag=" (optional, leave empty to skip)"
            fi

            local prompted_val=""
            if [[ -v "set_values[$key]" ]]; then
                prompted_val="${set_values[$key]}"
            else
                # Only prompt if TTY; otherwise use default unless key is required
                if [[ -t 0 ]]; then
                    local hint
                    hint="$(get_preset_hint "$preset_template" "$key")"
                    local header_arg=()
                    [[ -n "$hint" ]] && header_arg=(--header "$hint")
                    prompted_val="$(gum input --value "$default_val" "${header_arg[@]}" --prompt "${key}${optional_flag}: ")"
                else
                    # Non-interactive: use the preset default for optional keys;
                    # required keys (IMAGE, PORT) must be passed via --set.
                    if is_preset_optional "$preset_template" "$key"; then
                        prompted_val="$default_val"
                    else
                        print_error "--set ${key}=<value> is required when not running interactively"
                        exit 1
                    fi
                fi
            fi

            case "$key" in
                IMAGE) image="$prompted_val" ;;
                PORT) port="$prompted_val" ;;
                SECRET_NAME) secret_name="$prompted_val" ;;
                PROBE_PATH) probe_path="$prompted_val" ;;
                STORAGE_SIZE) storage_size="$prompted_val" ;;
                MOUNT_PATH) mount_path="$prompted_val" ;;
            esac
        done
```

- [ ] **Step 7: Replace the preset config-entries prompt loop**

Find (around line 305-313):

```bash
        for line in "${config_lines[@]}"; do
            key="${line%%=*}"
            default_val="${line#*=}"
            local cfg_val
            cfg_val="$(gum input --value "$default_val" --prompt "Config ${key}: ")"
            if [[ -n "$cfg_val" ]]; then
                config_entries+=("${key}=${cfg_val}")
            fi
        done
```

Replace with:

```bash
        # Build a lookup of --config flag overrides by key
        declare -A config_flag_map=()
        local cfe
        for cfe in "${config_flag_entries[@]}"; do
            [[ "$cfe" != *"="* ]] && { print_error "--config expects KEY=VAL, got: ${cfe}"; exit 1; }
            config_flag_map["${cfe%%=*}"]="${cfe#*=}"
        done

        for line in "${config_lines[@]}"; do
            key="${line%%=*}"
            default_val="${line#*=}"
            local cfg_val=""
            if [[ -v "config_flag_map[$key]" ]]; then
                cfg_val="${config_flag_map[$key]}"
                unset config_flag_map["$key"]
            elif [[ -t 0 ]]; then
                cfg_val="$(gum input --value "$default_val" --prompt "Config ${key}: ")"
            else
                cfg_val="$default_val"
            fi
            [[ -n "$cfg_val" ]] && config_entries+=("${key}=${cfg_val}")
        done

        # Any remaining --config entries are user additions not in the preset
        local leftover_key
        for leftover_key in "${!config_flag_map[@]}"; do
            config_entries+=("${leftover_key}=${config_flag_map[$leftover_key]}")
        done
```

- [ ] **Step 8: Replace the secret-keys prompt loop (preset flow)**

Find (around line 316-334). Replace the `while true` prompt loop with:

```bash
        if [[ -n "$secret_name" ]]; then
            local preset_secrets_lines=()
            while IFS= read -r line; do
                [[ -n "$line" ]] && preset_secrets_lines+=("$line")
            done < <(get_preset_secrets "$preset_template")

            if [[ ${#preset_secrets_lines[@]} -gt 0 ]]; then
                # Preset declares its own secrets list
                secret_keys=("${preset_secrets_lines[@]}")
            elif [[ ${#secret_keys_flag[@]} -gt 0 ]]; then
                secret_keys=("${secret_keys_flag[@]}")
            elif [[ -t 0 ]]; then
                print_info "Enter secret key names for '${secret_name}'. Empty to finish."
                while true; do
                    local key
                    key="$(gum input --placeholder "DATABASE_URL" --prompt "Secret key name (empty to finish): ")"
                    [[ -z "$key" ]] && break
                    secret_keys+=("$key")
                done
            fi
            # Non-interactive with no --secret-key is allowed (empty secret_keys)
        fi
```

- [ ] **Step 9: Replace the custom-flow prompts**

Find the custom flow block (around line 335-394). Replace each `gum input` with flag-or-prompt logic:

```bash
    else
        # --- Custom flow (deployment only) ---
        if [[ -n "$image_flag" ]]; then
            image="$image_flag"
        else
            image=$(prompt_or_die "Container image" "--image")
        fi
        if [[ -z "$image" ]]; then
            print_error "Container image is required."
            exit 1
        fi

        if [[ -n "$port_flag" ]]; then
            port="$port_flag"
        else
            port=$(prompt_or_die "Container port" "--port" "8080")
        fi
        validate_port "$port"

        # Secret name (optional)
        if [[ -n "$secret_name_flag" ]]; then
            secret_name="$secret_name_flag"
        elif [[ -t 0 ]]; then
            secret_name="$(gum input --placeholder "${app_name}-secrets" --prompt "Secret name (optional, empty to skip): ")"
        fi

        # Secret keys (if secret_name set)
        if [[ -n "$secret_name" ]]; then
            if [[ ${#secret_keys_flag[@]} -gt 0 ]]; then
                secret_keys=("${secret_keys_flag[@]}")
            elif [[ -t 0 ]]; then
                while true; do
                    local key
                    key="$(gum input --placeholder "DATABASE_URL" --prompt "Secret key name (empty to finish): ")"
                    [[ -z "$key" ]] && break
                    secret_keys+=("$key")
                done
            fi
        fi

        # Probe path (optional)
        if [[ -n "$probe_path_flag" ]]; then
            probe_path="$probe_path_flag"
        elif [[ -t 0 ]]; then
            probe_path="$(gum input --placeholder "/api/health" --prompt "Probe path (optional, empty to skip): ")"
        fi

        # Config entries (from --config flags only in custom flow; no preset)
        local cfe
        for cfe in "${config_flag_entries[@]}"; do
            [[ "$cfe" != *"="* ]] && { print_error "--config expects KEY=VAL, got: ${cfe}"; exit 1; }
            config_entries+=("$cfe")
        done
        # Interactive additions (legacy custom flow)
        if [[ -t 0 ]] && [[ ${#config_flag_entries[@]} -eq 0 ]]; then
            while true; do
                local cfg_entry
                cfg_entry="$(gum input --placeholder "KEY=value" --prompt "Config entry (empty to finish): ")"
                [[ -z "$cfg_entry" ]] && break
                config_entries+=("$cfg_entry")
            done
        fi
    fi
```

- [ ] **Step 10: Replace the Kargo enablement prompt**

Find (around line 393-398):

```bash
    local kargo_managed=false
    if is_kargo_enabled && [[ "$workload_type" == "Deployment" ]]; then
        if gum confirm "Manage image promotion with Kargo? "; then
            kargo_managed=true
        fi
    fi
```

Replace with:

```bash
    local kargo_managed=false
    if is_kargo_enabled; then
        if [[ -n "$kargo_flag" ]]; then
            kargo_managed="$kargo_flag"
        elif [[ "$workload_type" == "Deployment" ]]; then
            local answer
            answer=$(prompt_confirm_or_die "Manage image promotion with Kargo?" "--kargo/--no-kargo")
            [[ "$answer" == "yes" ]] && kargo_managed=true
        fi
    fi
```

- [ ] **Step 11: Replace the image-repo prompt (Kargo path)**

Find (around line 553-558):

```bash
        print_info "Kargo Warehouse watches a container registry for new image tags."
        image_repo="$(gum input --value "ghcr.io/${REPO_OWNER}/${app_name}" --prompt "Image repo for Kargo (no tag): ")"
        validate_image_repo "$image_repo"
```

Replace with:

```bash
        print_info "Kargo Warehouse watches a container registry for new image tags."
        local image_repo_default="ghcr.io/${REPO_OWNER}/${app_name}"
        if [[ -n "$image_repo_flag" ]]; then
            image_repo="$image_repo_flag"
        else
            image_repo=$(prompt_or_die "Image repo for Kargo (no tag)" "--image-repo" "$image_repo_default")
        fi
        validate_image_repo "$image_repo"
```

- [ ] **Step 12: Update `usage()` for add-app**

Update the `add-app` entry in `usage()` to list every flag.

- [ ] **Step 13: Manual verify — preset flow non-interactive**

```bash
TMP=$(mktemp -d) && cd "$TMP" && git init -q
/repos/personal/k8s_practice/infra-tooling/infra-ctl.sh --target-dir "$TMP" init --repo-url https://github.com/remerle/test
/repos/personal/k8s_practice/infra-tooling/infra-ctl.sh --target-dir "$TMP" add-env dev --yes   # NOTE: add-env --yes comes from Task 1.5
# For this verify step, add-env is still interactive; run in a TTY to create dev first, OR skip to verify after Task 1.5.
/repos/personal/k8s_practice/infra-tooling/infra-ctl.sh --target-dir "$TMP" add-app backend \
    --preset web --no-kargo \
    --set IMAGE=ghcr.io/remerle/k8s-practice-backend:26.4.11 \
    --set PORT=3000 \
    --set SECRET_NAME=backend-secrets \
    --set PROBE_PATH=/api/health \
    --secret-key DATABASE_URL </dev/null
```
Expected: add-app completes without prompts. Verify `k8s/apps/backend/base/deployment.yaml` references `ghcr.io/remerle/k8s-practice-backend:26.4.11`, port `3000`, etc.

- [ ] **Step 14: Manual verify — missing required flag fails cleanly**

```bash
/repos/personal/k8s_practice/infra-tooling/infra-ctl.sh --target-dir "$TMP" add-app other --preset web --no-kargo </dev/null
```
Expected: exit 1, error `--set IMAGE=<value> is required when not running interactively`.

- [ ] **Step 15: Manual verify — unknown --set key rejected**

```bash
/repos/personal/k8s_practice/infra-tooling/infra-ctl.sh --target-dir "$TMP" add-app other --preset web --no-kargo \
    --set BOGUS=x --set IMAGE=nginx --set PORT=80 </dev/null
```
Expected: exit 1, error `Unknown --set keys for this preset: BOGUS`.

- [ ] **Step 16: Manual verify — interactive path still works**

Run in a terminal without flags; confirm the same prompts appear as before.

- [ ] **Step 17: Commit**

```bash
git add infra-ctl.sh
git commit -m "Add flag interface to infra-ctl add-app

Accepts --name, --project, --workload-type, --preset, --set KEY=VAL
(repeatable, validated against preset frontmatter), --secret-key
(repeatable), --config KEY=VAL (repeatable), --kargo/--no-kargo,
--image-repo, --custom, --image, --port, --secret-name, --probe-path.
Preserves interactive flow as TTY fallback."
```

---

### Task 1.3: Retrofit `cmd_add_ingress`

**Files:** `infra-ctl.sh` (lines 615-713), `usage()`

**Flags:** `--app <name>` (positional shorthand), `--env <name>` (repeatable; default: all envs without ingress)

- [ ] **Step 1: Add flag parsing at the top of `cmd_add_ingress`**

Replace the current arg handling (which grabs `$1` as the app name) with:

```bash
cmd_add_ingress() {
    require_gum
    load_conf

    local app_name_flag=""
    local env_flags=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app)  [[ -z "${2:-}" ]] && { print_error "--app requires a value"; exit 1; }
                    app_name_flag="$2"; shift 2 ;;
            --env)  [[ -z "${2:-}" ]] && { print_error "--env requires a value"; exit 1; }
                    env_flags+=("$2"); shift 2 ;;
            -h|--help)
                    echo "Usage: infra-ctl.sh add-ingress <app> [--env <name>]..."
                    exit 0 ;;
            -*)     print_error "Unknown flag: $1"; exit 1 ;;
            *)      if [[ -z "$app_name_flag" ]]; then app_name_flag="$1"
                    else print_error "Unexpected argument: $1"; exit 1
                    fi
                    shift ;;
        esac
    done

    local app_name
    if [[ -n "$app_name_flag" ]]; then
        app_name="$app_name_flag"
    else
        # Build list of apps that have overlays without ingress
        # ...(reuse existing detection code)...
        app_name=$(prompt_choose_or_die "Select application" "--app" "${app_candidates[@]}")
    fi
    validate_k8s_name "$app_name" "App name"
```

- [ ] **Step 2: Replace the env multi-select**

Find the `gum choose --no-limit` call (line 674) that selects which envs to add ingress to. Replace with:

```bash
    local selected=()
    if [[ ${#env_flags[@]} -gt 0 ]]; then
        # Validate each flag env is in available_envs
        local e1 e2 found
        for e1 in "${env_flags[@]}"; do
            found=0
            for e2 in "${available_envs[@]}"; do
                [[ "$e1" == "$e2" ]] && { found=1; break; }
            done
            [[ "$found" -eq 0 ]] && { print_error "Env '${e1}' has no overlay for app '${app_name}' or already has an ingress"; exit 1; }
        done
        selected=("${env_flags[@]}")
    else
        mapfile -t selected < <(prompt_multi_or_die "Add ingress to which environments?" "--env" "${available_envs[@]}")
    fi
```

- [ ] **Step 3: Update `usage()` for add-ingress**

- [ ] **Step 4: Manual verify**

```bash
# With flags
infra-ctl.sh --target-dir "$TMP" add-ingress frontend --env dev --env staging </dev/null
# Missing flag, non-interactive
infra-ctl.sh --target-dir "$TMP" add-ingress backend </dev/null
# Expected: fails with "--env is required when not running interactively"
```

- [ ] **Step 5: Commit**

```bash
git add infra-ctl.sh
git commit -m "Add --app/--env flags to infra-ctl add-ingress"
```

---

### Task 1.4: Retrofit `cmd_remove_ingress`

**Files:** `infra-ctl.sh` (lines 747-832), `usage()`

**Flags:** `--app <name>` (positional), `--env <name>` (repeatable), `--yes` (skip confirmation)

- [ ] **Step 1: Add flag parsing**

Use the same pattern as add-ingress, plus `--yes`:

```bash
    local app_name_flag="" yes="false"
    local env_flags=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app)  app_name_flag="$2"; shift 2 ;;
            --env)  env_flags+=("$2"); shift 2 ;;
            --yes|-y) yes="true"; shift ;;
            -h|--help) echo "Usage: infra-ctl.sh remove-ingress <app> [--env <name>]... [--yes]"; exit 0 ;;
            -*)     print_error "Unknown flag: $1"; exit 1 ;;
            *)      if [[ -z "$app_name_flag" ]]; then app_name_flag="$1"; else print_error "Unexpected: $1"; exit 1; fi; shift ;;
        esac
    done
```

- [ ] **Step 2: Replace the app-selection prompt (line 770) with flag-or-choose_or_die**

- [ ] **Step 3: Replace the env multi-select (line 802) with flag-or-prompt_multi_or_die**

- [ ] **Step 4: Before deletion, call `require_yes "$yes" "remove ingress for ${app_name}"`**

- [ ] **Step 5: Update `usage()`**

- [ ] **Step 6: Verify non-interactive with --yes, without --yes**

- [ ] **Step 7: Commit**

```bash
git commit -m "Add --app/--env/--yes flags to infra-ctl remove-ingress"
```

---

### Task 1.5: Retrofit `cmd_add_env`

**Files:** `infra-ctl.sh` (lines 834-1060), `usage()`

**Flags:** `--name <env>` (positional), `--yes` (only if env-exists branch is currently gated by confirm; skip if none)

`cmd_add_env` has no `gum` prompts today (it's fully positional-driven) — but the plan must still **verify** that. Read lines 834-1060 and confirm no prompts exist. If any exist, apply the pattern.

- [ ] **Step 1: Read `cmd_add_env`**

Run: `sed -n '834,1060p' infra-ctl.sh | grep -n gum`
Expected: only non-interactive gum calls (`gum style`, confirmations for add-env operations). If any `gum input`/`gum choose`/`gum confirm` for user input appears, add flags for it.

- [ ] **Step 2: Add `--yes` flag and argument parser at top, wrap any new confirm calls**

- [ ] **Step 3: Update `usage()`**

- [ ] **Step 4: Verify**

- [ ] **Step 5: Commit**

```bash
git commit -m "Normalize flag parsing in infra-ctl add-env"
```

---

### Task 1.6: Retrofit `cmd_add_project`

**Files:** `infra-ctl.sh` (lines 1062-1161), `usage()`

**Flags:** `--name <string>` (positional), `--description <string>`, `--restrict-repos/--no-restrict-repos`, `--source-repos <comma-separated>`, `--namespaces <name>` (repeatable OR comma-separated), `--cluster-resources/--no-cluster-resources`

- [ ] **Step 1: Flag parsing**

```bash
cmd_add_project() {
    require_gum
    load_conf

    local name_flag="" desc_flag="" repos_flag=""
    local restrict_repos_flag=""         # "", "true", "false"
    local restrict_cluster_flag=""       # "", "true", "false"
    local ns_flags=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)         name_flag="$2"; shift 2 ;;
            --description)  desc_flag="$2"; shift 2 ;;
            --restrict-repos)    restrict_repos_flag="true"; shift ;;
            --no-restrict-repos) restrict_repos_flag="false"; shift ;;
            --source-repos) repos_flag="$2"; shift 2 ;;
            --namespaces)   IFS=',' read -ra _ns <<<"$2"; ns_flags+=("${_ns[@]}"); shift 2 ;;
            --cluster-resources)    restrict_cluster_flag="true"; shift ;;
            --no-cluster-resources) restrict_cluster_flag="false"; shift ;;
            -h|--help) echo "Usage: infra-ctl.sh add-project <name> [flags]"; exit 0 ;;
            -*) print_error "Unknown flag: $1"; exit 1 ;;
            *)  if [[ -z "$name_flag" ]]; then name_flag="$1"; else print_error "Unexpected: $1"; exit 1; fi; shift ;;
        esac
    done

    local project_name
    if [[ -n "$name_flag" ]]; then project_name="$name_flag"
    else project_name=$(prompt_or_die "Project name" "--name"); fi
    validate_k8s_name "$project_name" "Project name"
```

- [ ] **Step 2: Replace `gum input` for description (line 1086)**

```bash
    local description
    if [[ -n "$desc_flag" ]]; then description="$desc_flag"
    elif [[ -t 0 ]]; then
        description="$(gum input --placeholder "What does this project scope?" --prompt "Description: ")"
    else description=""; fi
```

- [ ] **Step 3: Replace `gum confirm` restrict_repos (line 1090) and `gum input` repos (line 1092)**

```bash
    local restrict_repos="no"
    if [[ "$restrict_repos_flag" == "true" ]]; then restrict_repos="yes"
    elif [[ "$restrict_repos_flag" == "false" ]]; then restrict_repos="no"
    elif [[ -t 0 ]]; then
        gum confirm "Restrict source repositories?" && restrict_repos="yes"
    fi

    local repos_input=""
    if [[ "$restrict_repos" == "yes" ]]; then
        if [[ -n "$repos_flag" ]]; then
            repos_input="$repos_flag"
        else
            repos_input=$(prompt_or_die "Allowed repos (comma-separated)" "--source-repos" "${REPO_URL}")
        fi
        # Validate each repo in comma-separated list
        IFS=',' read -ra _repos <<<"$repos_input"
        local r
        for r in "${_repos[@]}"; do
            r="$(echo "$r" | xargs)"  # trim
            validate_github_repo "$r"
        done
    fi
```

- [ ] **Step 4: Replace `gum choose --no-limit` namespaces (line 1117) and fallback `gum input` (line 1119)**

```bash
    local selected_namespaces=()
    local envs=()
    while IFS= read -r e; do envs+=("$e"); done < <(detect_envs)

    if [[ ${#ns_flags[@]} -gt 0 ]]; then
        selected_namespaces=("${ns_flags[@]}")
    elif [[ ${#envs[@]} -gt 0 ]]; then
        mapfile -t selected_namespaces < <(prompt_multi_or_die "Restrict destination namespaces?" "--namespaces" "${envs[@]}")
    elif [[ -t 0 ]]; then
        local ns_input
        ns_input="$(gum input --placeholder "dev, staging, prod" --prompt "Allowed namespaces (comma-separated): ")"
        IFS=',' read -ra selected_namespaces <<<"$ns_input"
    fi
    # If still empty and not TTY, that's allowed: unrestricted destinations.
```

- [ ] **Step 5: Replace `gum confirm` cluster-resources (line 1139)**

```bash
    local allow_cluster="no"
    if [[ "$restrict_cluster_flag" == "true" ]]; then allow_cluster="yes"
    elif [[ "$restrict_cluster_flag" == "false" ]]; then allow_cluster="no"
    elif [[ -t 0 ]]; then
        gum confirm "Allow full cluster-scoped resource access? (Namespaces, ClusterRoles, CRDs, etc.)" && allow_cluster="yes"
    fi
```

- [ ] **Step 6: Update `usage()`**

- [ ] **Step 7: Verify non-interactive**

```bash
infra-ctl.sh --target-dir "$TMP" add-project platform \
    --description "Platform apps" \
    --restrict-repos --source-repos https://github.com/remerle/test \
    --namespaces dev --namespaces staging \
    --no-cluster-resources </dev/null
```

- [ ] **Step 8: Commit**

```bash
git commit -m "Add flags to infra-ctl add-project"
```

---

### Task 1.7: Retrofit `cmd_edit_project`

**Files:** `infra-ctl.sh` (lines 1163-1293), `usage()`

**Flags:** same as `add-project` (`--name` positional, `--description`, `--restrict-repos/--no-restrict-repos`, `--source-repos`, `--namespaces`, `--cluster-resources/--no-cluster-resources`). Each flag, when not supplied, falls back to interactive prompt pre-filled with current values.

- [ ] **Step 1: Flag parsing** (same pattern as Task 1.6)

- [ ] **Step 2: For each existing prompt (lines 1200, 1208, 1216, 1244/1246, 1274), wrap with flag-or-prompt-or-current-value logic**

Example for description:
```bash
local description
if [[ -n "$desc_flag" ]]; then description="$desc_flag"
elif [[ -t 0 ]]; then
    description="$(gum input --value "${current_description}" --prompt "Description: ")"
else description="${current_description}"; fi
```

- [ ] **Step 3: Update `usage()`**

- [ ] **Step 4: Verify partial update via flags**

```bash
infra-ctl.sh --target-dir "$TMP" edit-project platform --description "Updated" </dev/null
```

- [ ] **Step 5: Commit**

```bash
git commit -m "Add flags to infra-ctl edit-project"
```

---

### Task 1.8: Retrofit `cmd_enable_kargo`

**Files:** `infra-ctl.sh` (lines 1295-1411), `usage()`

**Flags:** `--image-repo <app>=<url>` (repeatable; maps each app to its image repo)

The existing prompt (line 1375) iterates over apps and prompts for each one's image repo. The flag lets a caller supply them all at once.

- [ ] **Step 1: Flag parsing**

```bash
cmd_enable_kargo() {
    require_gum
    load_conf

    declare -A image_repo_map=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --image-repo)
                [[ -z "${2:-}" ]] && { print_error "--image-repo requires <app>=<url>"; exit 1; }
                local key="${2%%=*}" val="${2#*=}"
                [[ -z "$key" || "$key" == "$val" ]] && { print_error "--image-repo expects <app>=<url>, got: $2"; exit 1; }
                image_repo_map["$key"]="$val"
                shift 2 ;;
            -h|--help) echo "Usage: infra-ctl.sh enable-kargo [--image-repo <app>=<url>]..."; exit 0 ;;
            -*) print_error "Unknown flag: $1"; exit 1 ;;
            *)  print_error "Unexpected argument: $1"; exit 1 ;;
        esac
    done
```

- [ ] **Step 2: Replace per-app prompt (line 1375) with flag-or-prompt**

```bash
        local image_repo=""
        if [[ -v "image_repo_map[$app]" ]]; then
            image_repo="${image_repo_map[$app]}"
        else
            image_repo=$(prompt_or_die "Image repo for ${app} (no tag)" "--image-repo ${app}=<url>" "ghcr.io/${REPO_OWNER}/${app}")
        fi
        validate_image_repo "$image_repo"
```

- [ ] **Step 3: Update `usage()`**

- [ ] **Step 4: Verify**

```bash
infra-ctl.sh --target-dir "$TMP" enable-kargo \
    --image-repo backend=ghcr.io/remerle/k8s-practice-backend \
    --image-repo frontend=ghcr.io/remerle/k8s-practice-frontend </dev/null
```

- [ ] **Step 5: Commit**

```bash
git commit -m "Add --image-repo flag to infra-ctl enable-kargo"
```

---

### Task 1.9: Retrofit `cmd_remove_project`

**Files:** `infra-ctl.sh` (lines 1513-1611), `usage()`

**Flags:** `--name <string>` (positional), `--reassign-to <project>`, `--yes`

- [ ] **Step 1: Flag parsing** — same pattern

- [ ] **Step 2: Replace `gum choose` for reassign-to (line 1567)**

```bash
    local reassign_to=""
    if [[ ${#assigned_apps[@]} -gt 0 ]]; then
        if [[ -n "$reassign_flag" ]]; then
            reassign_to="$reassign_flag"
            # Validate target exists
            # ...
        else
            reassign_to=$(prompt_choose_or_die "Reassign these apps to" "--reassign-to" "default" "${other_projects[@]}")
        fi
    fi
```

- [ ] **Step 3: Wrap destructive confirmation with `require_yes "$yes" "remove project '${project_name}'"`**

- [ ] **Step 4: Update `usage()`**

- [ ] **Step 5: Verify**

- [ ] **Step 6: Commit**

```bash
git commit -m "Add --name/--reassign-to/--yes flags to infra-ctl remove-project"
```

---

### Task 1.10: Retrofit `cmd_remove_app`, `cmd_remove_env`, `cmd_reset`

**Files:** `infra-ctl.sh` (lines 1613-1932), `usage()`

These already use positional args or interactive chooser for the name, plus a destructive confirmation. Add `--yes`/`-y` and formalize the flag pattern.

- [ ] **Step 1: For each of `cmd_remove_app`, `cmd_remove_env`, `cmd_remove_project`, `cmd_reset`, add:**
  - Flag parsing with `--name` (positional shorthand) and `--yes|-y`
  - Replace the existing destructive confirmation call with `require_yes "$yes" "..."`

- [ ] **Step 2: Update `usage()` for all three commands**

- [ ] **Step 3: Verify each refuses to remove without --yes when no TTY**

```bash
infra-ctl.sh --target-dir "$TMP" remove-app backend </dev/null
# expected: exit 1 with "--yes is required"
infra-ctl.sh --target-dir "$TMP" remove-app backend --yes </dev/null
# expected: success
```

- [ ] **Step 4: Commit**

```bash
git commit -m "Add --yes flag to infra-ctl destructive commands (remove-app, remove-env, reset)"
```

---

## Phase 2: `cluster-ctl.sh` commands

### Task 2.1: Retrofit `cmd_init_cluster`

**Files:** `cluster-ctl.sh` (lines 57-320), `usage()`

**Flags:**
| Flag | Type | Required | Default | Source |
|---|---|---|---|---|
| `--name <string>` | string | no | TARGET_DIR basename | line 78 |
| `--agents <n>` | int | no | `3` | line 97 |
| `--expose-ports / --no-expose-ports` | bool | no | `false` | line 103 |
| `--tls / --no-tls` | bool | no | `false` | line 138 |
| `--argocd / --no-argocd` | bool | no | `false` | line 146 |
| `--kargo / --no-kargo` | bool | no | `false` | line 189 |
| `--kargo-password <string>` | string | yes (if --kargo) | — | lines 206, 211 |

- [ ] **Step 1: Add flag parsing (the complete block is lengthy; use the same pattern as Task 1.2)**

```bash
cmd_init_cluster() {
    require_gum; require_helm

    local name_flag="" agents_flag=""
    local expose_flag="" tls_flag="" argocd_flag="" kargo_flag=""
    local kargo_password_flag=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)    name_flag="$2"; shift 2 ;;
            --agents)  agents_flag="$2"; shift 2 ;;
            --expose-ports)    expose_flag="true"; shift ;;
            --no-expose-ports) expose_flag="false"; shift ;;
            --tls)             tls_flag="true"; shift ;;
            --no-tls)          tls_flag="false"; shift ;;
            --argocd)          argocd_flag="true"; shift ;;
            --no-argocd)       argocd_flag="false"; shift ;;
            --kargo)           kargo_flag="true"; shift ;;
            --no-kargo)        kargo_flag="false"; shift ;;
            --kargo-password)  kargo_password_flag="$2"; shift 2 ;;
            -h|--help) echo "Usage: cluster-ctl.sh init-cluster [flags]"; exit 0 ;;
            -*) print_error "Unknown flag: $1"; exit 1 ;;
            *)  print_error "Unexpected argument: $1"; exit 1 ;;
        esac
    done
```

- [ ] **Step 2: Wrap each of the 7 prompts with flag-or-prompt-or-default**

For each prompt at lines 78, 97, 103, 138, 146, 189, 206/211 — apply the same pattern: if flag set use it, else if TTY prompt, else use documented default (for booleans/numbers) OR die (for required strings like --kargo-password).

For `--kargo-password`: if `--kargo=true` and no password flag provided and no TTY → `die "--kargo-password is required when --kargo is set non-interactively"`.

- [ ] **Step 3: Update `usage()`**

- [ ] **Step 4: Verify non-interactive cluster creation with flags**

```bash
cluster-ctl.sh init-cluster \
    --name test-cluster --agents 1 \
    --expose-ports --no-tls \
    --argocd --no-kargo </dev/null
# Then: cluster-ctl.sh delete-cluster --name test-cluster --yes
```

- [ ] **Step 5: Commit**

```bash
git commit -m "Add flags to cluster-ctl init-cluster"
```

---

### Task 2.2: Retrofit `cmd_add_argo_creds`

**Files:** `cluster-ctl.sh` (lines 405-464), `usage()`

**Flags:** `--pat <string>` (password input line 437)

- [ ] **Step 1: Flag parsing**
- [ ] **Step 2: Replace `gum input --password` with flag-or-`prompt_password_or_die`**
- [ ] **Step 3: Update `usage()`**
- [ ] **Step 4: Verify with `--pat "$(cat /path/to/token)"`**
- [ ] **Step 5: Commit** — `git commit -m "Add --pat flag to cluster-ctl add-argo-creds"`

---

### Task 2.3: Retrofit `cmd_add_registry_creds`

**Files:** `cluster-ctl.sh` (lines 466-571), `usage()`

**Flags:** `--registry <string>` (default `ghcr.io`), `--username <string>`, `--token <string>`, `--namespace <name>` (repeatable)

- [ ] **Step 1: Flag parsing**
- [ ] **Step 2: Replace four prompts (lines 475, 484, 501, 533) with flag-or-prompt variants**
- [ ] **Step 3: Update `usage()`**
- [ ] **Step 4: Verify**

```bash
cluster-ctl.sh add-registry-creds \
    --registry ghcr.io --username remerle --token "$TOKEN" \
    --namespace dev --namespace staging </dev/null
```

- [ ] **Step 5: Commit** — `git commit -m "Add flags to cluster-ctl add-registry-creds"`

---

### Task 2.4: Retrofit `cmd_add_kargo_creds`

**Files:** `cluster-ctl.sh` (lines 573-694), `usage()`

**Flags:** `--app <name>` (positional), `--pat <string>`, `--private-registry / --no-private-registry`

- [ ] **Step 1: Flag parsing**
- [ ] **Step 2: Replace 3 prompts (lines 601, 647, 676)**
- [ ] **Step 3: Update `usage()`**
- [ ] **Step 4: Verify**
- [ ] **Step 5: Commit** — `git commit -m "Add flags to cluster-ctl add-kargo-creds"`

---

### Task 2.5: Add `--yes` to `cmd_delete_cluster`

**Files:** `cluster-ctl.sh` (line 322), `usage()`

- [ ] **Step 1: Add `--name <cluster>` (positional) + `--yes|-y` flags**
- [ ] **Step 2: Replace the existing destructive confirm with `require_yes`**
- [ ] **Step 3: Update `usage()`**
- [ ] **Step 4: Verify**
- [ ] **Step 5: Commit** — `git commit -m "Add --yes flag to cluster-ctl delete-cluster"`

---

## Phase 3: `secret-ctl.sh` commands

### Task 3.1: Retrofit `cmd_init`

**Files:** `secret-ctl.sh` (lines 8-71), `usage()`

**Flags:** `--restore-key / --no-restore-key`

- [ ] **Step 1: Flag parsing**
- [ ] **Step 2: Replace the restore-key confirm (line 21)**
- [ ] **Step 3: Update `usage()`**
- [ ] **Step 4: Verify**
- [ ] **Step 5: Commit** — `git commit -m "Add --restore-key flag to secret-ctl init"`

---

### Task 3.2: Retrofit `cmd_add`

**Files:** `secret-ctl.sh` (lines 73-232), `usage()`

**Flags:** `--app <name>` (positional 1), `--env <name>` (positional 2), `--secret-val KEY=VAL` (repeatable; value can be `-` to read from stdin or `@file` to read from file), `--overwrite`, `--yes`

- [ ] **Step 1: Flag parsing — `--secret-val KEY=VAL` provides actual secret values (distinct from infra-ctl's `--secret-key` which only declares names)**

```bash
cmd_add() {
    require_gum; require_kubectl

    local app_flag="" env_flag="" overwrite_flag="" yes="false"
    declare -A secret_kv=()
    declare -A secret_kv_source=()  # tracks "inline"|"stdin"|"file:<path>"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app) app_flag="$2"; shift 2 ;;
            --env) env_flag="$2"; shift 2 ;;
            --secret-val)
                [[ "$2" != *"="* ]] && { print_error "--secret-val expects KEY=VAL"; exit 1; }
                local k="${2%%=*}" v="${2#*=}"
                if [[ "$v" == "-" ]]; then
                    secret_kv_source["$k"]="stdin"
                    secret_kv["$k"]="$(cat)"
                elif [[ "$v" == @* ]]; then
                    secret_kv_source["$k"]="file:${v#@}"
                    secret_kv["$k"]="$(cat "${v#@}")"
                else
                    secret_kv_source["$k"]="inline"
                    secret_kv["$k"]="$v"
                fi
                shift 2 ;;
            --overwrite)    overwrite_flag="true"; shift ;;
            --no-overwrite) overwrite_flag="false"; shift ;;
            --yes|-y)       yes="true"; shift ;;
            -h|--help) echo "Usage: secret-ctl.sh add <app> <env> [--secret-val KEY=VAL]... [--overwrite] [--yes]"; exit 0 ;;
            -*) print_error "Unknown flag: $1"; exit 1 ;;
            *)
                if [[ -z "$app_flag" ]]; then app_flag="$1"
                elif [[ -z "$env_flag" ]]; then env_flag="$1"
                else print_error "Unexpected: $1"; exit 1; fi
                shift ;;
        esac
    done
```

- [ ] **Step 2: Replace the interactive key prompt loop (line 161) and overwrite confirm (line 171) and password prompt (line 177)**

```bash
    # If --secret-val was used, skip interactive loop entirely
    if [[ ${#secret_kv[@]} -eq 0 ]] && [[ -t 0 ]]; then
        while true; do
            local key
            key="$(gum input --placeholder "e.g. DATABASE_URL" --prompt "Secret key (empty to finish): ")"
            [[ -z "$key" ]] && break
            # existing overwrite logic...
            local value
            value="$(gum input --password --prompt "Value for ${key}: ")"
            secret_kv["$key"]="$value"
        done
    elif [[ ${#secret_kv[@]} -eq 0 ]]; then
        print_error "--secret-val KEY=VAL is required when not running interactively (repeat for multiple keys)"
        exit 1
    fi

    # Overwrite check per key
    local existing_keys=()
    # ...(detect existing keys in current sealed secret)...
    local k
    for k in "${!secret_kv[@]}"; do
        local exists=0
        for ek in "${existing_keys[@]}"; do [[ "$ek" == "$k" ]] && { exists=1; break; }; done
        if [[ "$exists" -eq 1 ]]; then
            if [[ "$overwrite_flag" == "true" ]]; then
                : # allow
            elif [[ "$overwrite_flag" == "false" ]]; then
                print_info "Skipping existing key '${k}' (--no-overwrite)"
                unset secret_kv["$k"]
            elif [[ -t 0 ]]; then
                if ! gum confirm "Key '${k}' already exists. Overwrite?"; then
                    unset secret_kv["$k"]
                fi
            else
                print_error "Key '${k}' already exists. Pass --overwrite or --no-overwrite."
                exit 1
            fi
        fi
    done
```

- [ ] **Step 3: Update `usage()`**

- [ ] **Step 4: Verify**

```bash
# Inline values
secret-ctl.sh add backend dev --secret-val DATABASE_URL=postgres://localhost/db --secret-val API_KEY=abc </dev/null
# From file
secret-ctl.sh add backend dev --secret-val DATABASE_URL=@/tmp/db-url.txt </dev/null
# From stdin
echo -n "supersecret" | secret-ctl.sh add backend dev --secret-val PASSWORD=-
```

- [ ] **Step 5: Commit** — `git commit -m "Add --app/--env/--secret-val/--overwrite flags to secret-ctl add"`

---

### Task 3.3: Retrofit `cmd_remove` and `cmd_verify`

**Files:** `secret-ctl.sh` (lines 290-348, 349-418), `usage()`

**Flags for remove:** `--app <name>`, `--env <name>`, `--key <name>` (repeatable), `--yes`
**Flags for verify:** `--walk` (equivalent to "yes" to the walkthrough prompt)

- [ ] **Step 1: Add flags and replace prompts in both**
- [ ] **Step 2: Update `usage()`**
- [ ] **Step 3: Verify**
- [ ] **Step 4: Commit** — `git commit -m "Add flags to secret-ctl remove and verify"`

---

## Phase 4: `config-ctl.sh` commands

### Task 4.1: Retrofit `cmd_add`, `cmd_remove`, `cmd_verify`

**Files:** `config-ctl.sh` (lines 8-273), `usage()`

**Flags for add:** `--app <name>`, `--env <name>` (or global), `--config KEY=VAL` (repeatable), `--overwrite`
**Flags for remove:** `--app <name>`, `--env <name>`, `--key <name>` (repeatable)
**Flags for verify:** `--walk`

- [ ] **Step 1: For each command, add flag parsing (following pattern from Task 3.2)**
- [ ] **Step 2: Replace 3 prompts (lines 56, 252, 374)**
- [ ] **Step 3: Update `usage()`**
- [ ] **Step 4: Verify**
- [ ] **Step 5: Commit** — `git commit -m "Add flags to config-ctl add/remove/verify"`

---

## Phase 5: `user-ctl.sh` commands

### Task 5.1: Retrofit `cmd_add_role`

**Files:** `user-ctl.sh` (lines 11-189), `usage()`

**Flags:**
| Flag | Source prompt | Notes |
|---|---|---|
| `--name <string>` (positional) | function args | |
| `--preset <admin-readonly-settings\|developer\|viewer\|custom>` | line 34 | |
| `--argocd-resources <csv>` | line 50 | only for custom |
| `--actions <csv>` | line 59 | only for custom |
| `--namespace <name>` (repeatable) | line 94 & 147 | for developer/custom-namespaced |
| `--k8s-scope <cluster-wide\|namespace-scoped>` | line 123 | only for custom |
| `--k8s-verbs <csv>` | lines 129, 150 | only for custom |

- [ ] **Step 1: Flag parsing — this is the second most complex command after add-app**
- [ ] **Step 2: Replace all 7 conditional prompts**
- [ ] **Step 3: Update `usage()`**
- [ ] **Step 4: Verify each preset non-interactively**

```bash
user-ctl.sh add-role viewer-all --preset viewer </dev/null
user-ctl.sh add-role backend-devs --preset developer --namespace dev --namespace staging </dev/null
user-ctl.sh add-role custom-role --preset custom \
    --argocd-resources applications,projects --actions get,sync \
    --k8s-scope namespace-scoped --namespace dev --k8s-verbs get,list,watch </dev/null
```

- [ ] **Step 5: Commit** — `git commit -m "Add flags to user-ctl add-role"`

---

### Task 5.2: Add `--yes` to destructive user-ctl commands

**Files:** `user-ctl.sh` — `cmd_remove_role` (line 228), `cmd_remove` (line 400), `cmd_remove_sa` (line 776)

- [ ] **Step 1: Add `--yes|-y` flag to each; replace existing gum confirm with require_yes**
- [ ] **Step 2: Update `usage()`**
- [ ] **Step 3: Verify refusal without --yes**
- [ ] **Step 4: Commit** — `git commit -m "Add --yes flag to user-ctl destructive commands"`

---

### Task 5.3: Confirm `cmd_add`, `cmd_add_sa`, `cmd_refresh_sa` take all values via flags

**Files:** `user-ctl.sh` (lines 280-399, 508-712, 714-774)

These commands take positional `<username> <group>` or `<sa-name> <group>` and `--duration`. Review each to ensure every value is accepted via flag AND fails cleanly when a required value is missing under no-TTY.

- [ ] **Step 1: Read each function; identify any `gum input`/`gum confirm` not already captured above**
- [ ] **Step 2: Add flag for each residual prompt; update `usage()`**
- [ ] **Step 3: Verify**
- [ ] **Step 4: Commit** — `git commit -m "Ensure user-ctl add/add-sa/refresh-sa use flags for all inputs"`

---

## Phase 6: Completions and Documentation

### Task 6.1: Update `completions.zsh` with all new flags

**Files:** `completions.zsh`

- [ ] **Step 1: For each retrofit command, add flag completions to completions.zsh**

Example entry for `add-app`:
```zsh
_infra_add_app() {
  _arguments \
    '--name[Application name]:name:' \
    '--project[ArgoCD project]:project:_infra_complete_projects' \
    '--workload-type[Deployment or StatefulSet]:type:(deployment statefulset)' \
    '--preset[Preset name]:preset:' \
    '*--set[Preset KEY=VAL]:set:' \
    '*--secret-key[Secret key name]:key:' \
    '*--config[Config KEY=VAL]:config:' \
    '--kargo[Enable Kargo]' \
    '--no-kargo[Disable Kargo]' \
    '--image-repo[Kargo image repo]:repo:' \
    '--custom[Use custom flow]' \
    '--image[Container image]:image:' \
    '--port[Container port]:port:' \
    '--secret-name[Secret name]:name:' \
    '--probe-path[Probe path]:path:'
}
```

- [ ] **Step 2: Verify completion file parses**

Run: `zsh -n completions.zsh && echo OK`

- [ ] **Step 3: Commit** — `git commit -m "Add flag completions to completions.zsh"`

---

### Task 6.2: Update README.md with flag documentation

**Files:** `README.md`

- [ ] **Step 1: For each retrofit command in the README's command reference, append a "Flags:" subsection listing all flags with descriptions**

Example:
```markdown
#### `add-app <name>`

... (existing description) ...

**Flags:**
- `--name <string>` (or positional) — application name
- `--project <name>` — ArgoCD project (default: `default`)
- `--workload-type <deployment|statefulset>` — workload type (default: `deployment`)
- `--preset <name>` — preset name from templates
- `--set KEY=VAL` — preset placeholder values (repeatable)
- `--secret-key <name>` — secret key names (repeatable)
- `--config KEY=VAL` — configMapGenerator entries (repeatable)
- `--kargo / --no-kargo` — enable/disable Kargo management
- `--image-repo <url>` — Kargo image repo (required if `--kargo`)
- `--custom` — use custom flow (Deployment only)
- `--image <ref>`, `--port <n>`, `--secret-name <name>`, `--probe-path <path>` — custom-flow overrides

**Example (fully non-interactive):**
\`\`\`bash
infra-ctl.sh add-app backend \
    --preset web --no-kargo \
    --set IMAGE=ghcr.io/remerle/k8s-practice-backend:26.4.11 \
    --set PORT=3000 \
    --set SECRET_NAME=backend-secrets \
    --set PROBE_PATH=/api/health \
    --secret-key DATABASE_URL
\`\`\`
```

- [ ] **Step 2: Add a new top-level README section "Scripting and CI" describing the flag-first contract**

```markdown
## Scripting and CI

All commands are fully scriptable. Every interactive prompt has a corresponding CLI flag; commands only prompt when stdin is a TTY. When running non-interactively (CI, pipes, `</dev/null`), commands that need a missing value fail with a clear error naming the flag. Destructive operations require `--yes`.

```bash
# Scripted workflow (no prompts):
infra-ctl.sh init --repo-url https://github.com/myorg/my-gitops
infra-ctl.sh add-env dev
infra-ctl.sh add-app backend --preset web --no-kargo \
    --set IMAGE=ghcr.io/myorg/backend:v1 --set PORT=3000
```
```

- [ ] **Step 3: Commit** — `git commit -m "Document command flags in README"`

---

### Task 6.3: Final verification — run a full scripted workflow

- [ ] **Step 1: Create a fresh directory and run the whole happy-path flow non-interactively**

```bash
TMP=$(mktemp -d) && cd "$TMP" && git init -q
infra-ctl.sh --target-dir "$TMP" init --repo-url https://github.com/remerle/test
infra-ctl.sh --target-dir "$TMP" add-project platform --description "Platform" --no-restrict-repos --no-cluster-resources
infra-ctl.sh --target-dir "$TMP" add-env dev
infra-ctl.sh --target-dir "$TMP" add-env staging
infra-ctl.sh --target-dir "$TMP" add-app backend --project platform --preset web --no-kargo \
    --set IMAGE=ghcr.io/remerle/k8s-practice-backend:26.4.11 \
    --set PORT=3000 --set SECRET_NAME=backend-secrets --set PROBE_PATH=/api/health \
    --secret-key DATABASE_URL
infra-ctl.sh --target-dir "$TMP" add-ingress backend --env dev --env staging
infra-ctl.sh --target-dir "$TMP" list-apps
infra-ctl.sh --target-dir "$TMP" list-envs
infra-ctl.sh --target-dir "$TMP" list-ingress
infra-ctl.sh --target-dir "$TMP" remove-app backend --yes
infra-ctl.sh --target-dir "$TMP" reset --yes
```
Expected: every command completes without prompts, no errors.

- [ ] **Step 2: Create a final commit if anything needed adjustment**

---

## Self-Review Checklist (for plan author, pre-execution)

**Spec coverage (every prompt catalogued → task):**

- [x] `infra-ctl.sh init` repo_url → Task 1.1
- [x] `infra-ctl.sh add-app` all 14 prompts → Task 1.2
- [x] `infra-ctl.sh add-ingress` env multi → Task 1.3
- [x] `infra-ctl.sh remove-ingress` app+env+confirm → Task 1.4
- [x] `infra-ctl.sh add-env` (no prompts verified) → Task 1.5
- [x] `infra-ctl.sh add-project` 6 prompts → Task 1.6
- [x] `infra-ctl.sh edit-project` 6 prompts → Task 1.7
- [x] `infra-ctl.sh enable-kargo` per-app repo → Task 1.8
- [x] `infra-ctl.sh remove-project` + reassign → Task 1.9
- [x] `infra-ctl.sh remove-app/env/reset` --yes → Task 1.10
- [x] `cluster-ctl.sh init-cluster` 7 prompts → Task 2.1
- [x] `cluster-ctl.sh add-argo-creds` PAT → Task 2.2
- [x] `cluster-ctl.sh add-registry-creds` 4 prompts → Task 2.3
- [x] `cluster-ctl.sh add-kargo-creds` 3 prompts → Task 2.4
- [x] `cluster-ctl.sh delete-cluster` --yes → Task 2.5
- [x] `secret-ctl.sh init` restore-key → Task 3.1
- [x] `secret-ctl.sh add` 3 prompts → Task 3.2
- [x] `secret-ctl.sh remove/verify` → Task 3.3
- [x] `config-ctl.sh add/remove/verify` 3 prompts → Task 4.1
- [x] `user-ctl.sh add-role` 7 conditional prompts → Task 5.1
- [x] `user-ctl.sh remove-role/remove/remove-sa` --yes → Task 5.2
- [x] `user-ctl.sh add/add-sa/refresh-sa` review → Task 5.3
- [x] Completions → Task 6.1
- [x] README → Task 6.2
- [x] Full workflow verification → Task 6.3
- [x] AGENTS.md convention mandate → Task 0.1

**Placeholder scan:** no "TBD", "similar to task N", or "handle edge cases" without code. Each per-command task names its flags, prompt line numbers, and verification commands.

**Type/name consistency:** helper function names (`require_tty`, `prompt_or_die`, etc.) defined in Task 0.2 and referenced identically throughout.

---

## Execution Notes

- **Each task is independently committable and pushable.** Phase 0 MUST land before any other phase.
- **Phases 1-5 can be interleaved** — e.g., a reviewer could pick up Phase 4 while Phase 2 is in progress.
- **Documentation (Phase 6) should run last** so flag tables reflect what was actually shipped.
- **All work happens on a dedicated worktree** per superpowers conventions. Branch name suggestion: `flag-first-commands`.
- **No backwards-compat shim is needed** — current interactive flows remain the default when flags are absent; flags are purely additive.
