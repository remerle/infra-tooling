#!/usr/bin/env bash
set -euo pipefail

# Resolve paths relative to the script that sources this file.
# SCRIPT_DIR is where infra-ctl.sh or cluster-ctl.sh lives (tooling/).
# TEMPLATE_DIR is where templates live (tooling/templates/).
# TARGET_DIR is where the script operates (default: current working directory).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"
TARGET_DIR="${PWD}"

# --- Command visibility ---

# When SHOW_ME=1 (or --show-me flag), print commands before running them
# instead of hiding them behind a gum spinner.
: "${SHOW_ME:=0}"

# When EXPLAIN=1 (or --explain flag), also print explanations for each command.
# Implies SHOW_ME=1.
: "${EXPLAIN:=0}"
if [[ "$EXPLAIN" == "1" ]]; then
    SHOW_ME=1
fi

# When DEBUG=1 (or --debug flag), show full command output in SHOW_ME mode.
# Without this, SHOW_ME/EXPLAIN mode suppresses output (shown only on failure).
: "${DEBUG:=0}"

# Runs a command with a gum spinner, or prints and runs it directly if SHOW_ME=1.
# Usage: run_cmd "Installing ArgoCD..." helm install argocd ...
#   First arg is the human-readable description (used as spinner title).
#   Remaining args are the command to execute.
run_cmd() {
    local title="$1"
    shift

    local explanation=""
    if [[ "${1:-}" == "--explain" ]]; then
        explanation="$2"
        shift 2
    fi

    if [[ "$SHOW_ME" == "1" ]]; then
        print_info "${title}"
        if [[ "$EXPLAIN" == "1" && -n "$explanation" ]]; then
            gum style --faint --italic "    ${explanation}"
        fi
        print_info "  \$ $*"
        if [[ "$DEBUG" == "1" ]]; then
            "$@"
        else
            local _log
            _log="$(mktemp)"
            if ! "$@" >"$_log" 2>&1; then
                cat "$_log" >&2
                rm -f "$_log"
                return 1
            fi
            rm -f "$_log"
        fi
    else
        gum spin --title "$title" -- "$@"
    fi
}

# Same as run_cmd but passes the command through bash -c (for pipes, heredocs, etc).
# Usage: run_cmd_sh "Configuring TLS..." 'kubectl create secret tls ... && kubectl apply ...'
run_cmd_sh() {
    local title="$1"
    shift

    local explanation=""
    if [[ "${1:-}" == "--explain" ]]; then
        explanation="$2"
        shift 2
    fi

    local script="$1"

    if [[ "$SHOW_ME" == "1" ]]; then
        print_info "${title}"
        if [[ "$EXPLAIN" == "1" && -n "$explanation" ]]; then
            gum style --faint --italic "    ${explanation}"
        fi
        print_info "  \$ ${script}"
        if [[ "$DEBUG" == "1" ]]; then
            bash -c "$script"
        else
            local _log
            _log="$(mktemp)"
            if ! bash -c "$script" >"$_log" 2>&1; then
                cat "$_log" >&2
                rm -f "$_log"
                return 1
            fi
            rm -f "$_log"
        fi
    else
        gum spin --title "$title" -- bash -c "$script"
    fi
}

# --- Dependency checking ---

require_cmd() {
    local cmd="$1"
    local install_hint="${2:-}"
    if ! command -v "$cmd" &>/dev/null; then
        gum_available=false
        if command -v gum &>/dev/null; then
            gum_available=true
        fi

        if [[ "$gum_available" == true ]]; then
            print_error "'$cmd' is required but not installed."
        else
            echo "ERROR: '$cmd' is required but not installed." >&2
        fi

        if [[ -n "$install_hint" ]]; then
            echo "  Install: $install_hint" >&2
        fi
        exit 1
    fi
}

require_gum() {
    if ! command -v gum &>/dev/null; then
        echo "ERROR: 'gum' is required but not installed." >&2
        echo "  Install: brew install gum" >&2
        echo "  Or visit: https://github.com/charmbracelet/gum#installation" >&2
        exit 1
    fi
}

require_yq() {
    if ! command -v yq &>/dev/null; then
        echo "ERROR: 'yq' (Go version by mikefarah) is required but not installed." >&2
        echo "  Install: brew install yq" >&2
        echo "  Or visit: https://github.com/mikefarah/yq#install" >&2
        exit 1
    fi
}

require_helm() {
    if ! command -v helm &>/dev/null; then
        echo "ERROR: 'helm' is required but not installed." >&2
        echo "  Install: brew install helm" >&2
        echo "  Or visit: https://helm.sh/docs/intro/install/" >&2
        exit 1
    fi
}

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

# Checks a list of required tools and reports all missing ones at once.
# Usage: preflight_check "cmd1:hint1" "cmd2:hint2" ...
#   Each argument is "command:install_hint". The hint is optional.
#   Returns 0 if all tools are present, 1 if any are missing.
preflight_check() {
    local missing=0
    local total=0
    local tool hint

    for entry in "$@"; do
        tool="${entry%%:*}"
        hint="${entry#*:}"
        [[ "$hint" == "$tool" ]] && hint=""
        total=$((total + 1))

        if command -v "$tool" &>/dev/null; then
            local version=""
            case "$tool" in
                gum) version="$(gum --version 2>/dev/null || true)" ;;
                kubectl) version="$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' 2>/dev/null || true)" ;;
                helm) version="$(helm version --short 2>/dev/null || true)" ;;
                jq) version="$(jq --version 2>/dev/null || true)" ;;
                yq) version="$(yq --version 2>/dev/null | awk '{print $NF}' || true)" ;;
                k3d) version="$(k3d version 2>/dev/null | head -1 | awk '{print $NF}' || true)" ;;
                kubeseal) version="$(kubeseal --version 2>/dev/null | awk '{print $NF}' || true)" ;;
                docker) version="$(docker --version 2>/dev/null | sed 's/Docker version //' | cut -d, -f1 || true)" ;;
                openssl) version="$(openssl version 2>/dev/null | awk '{print $2}' || true)" ;;
                *) version="$(command -v "$tool")" ;;
            esac
            printf "  ✓ %-12s %s\n" "$tool" "${version:-found}"
        else
            printf "  ✗ %-12s MISSING" "$tool"
            [[ -n "$hint" ]] && printf "  (install: %s)" "$hint"
            printf "\n"
            missing=$((missing + 1))
        fi
    done

    echo ""
    if [[ $missing -gt 0 ]]; then
        echo "  ${missing} of ${total} required tools missing."
        return 1
    else
        echo "  All ${total} required tools found."
        return 0
    fi
}

# --- Input validation ---

# Validates a name for use as a Kubernetes resource name and filesystem path.
# Must match RFC 1123 subdomain: lowercase alphanumeric, hyphens, dots; max 253 chars.
# Usage: validate_k8s_name <name> <label>
#   label: human-readable label for error messages (e.g. "app name", "environment")
validate_k8s_name() {
    local name="$1"
    local label="${2:-name}"

    if [[ -z "$name" ]]; then
        print_error "${label} cannot be empty."
        exit 1
    fi

    if [[ ${#name} -gt 253 ]]; then
        print_error "${label} '${name}' exceeds 253 characters."
        exit 1
    fi

    if ! [[ "$name" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]] && ! [[ "$name" =~ ^[a-z0-9]$ ]]; then
        print_error "${label} '${name}' is not a valid Kubernetes resource name."
        echo "  Must match RFC 1123: lowercase alphanumeric, hyphens, or dots." >&2
        echo "  Must start and end with an alphanumeric character." >&2
        exit 1
    fi
}

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

# --- Argument parsing ---

# Extracts global flags from arguments. Sets TARGET_DIR, SHOW_ME.
# Remaining args are stored in REMAINING_ARGS array.
parse_global_args() {
    REMAINING_ARGS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target-dir)
                if [[ -z "${2:-}" ]]; then
                    # Use echo here because gum may not be installed yet
                    echo "ERROR: --target-dir requires a path argument" >&2
                    exit 1
                fi
                if [[ ! -d "$2" ]]; then
                    echo "ERROR: --target-dir path does not exist: $2" >&2
                    exit 1
                fi
                TARGET_DIR="$(cd "$2" && pwd)"
                shift 2
                ;;
            --show-me)
                SHOW_ME=1
                shift
                ;;
            --explain)
                EXPLAIN=1
                SHOW_ME=1
                shift
                ;;
            --debug)
                DEBUG=1
                SHOW_ME=1
                shift
                ;;
            *)
                REMAINING_ARGS+=("$1")
                shift
                ;;
        esac
    done
}

# --- Configuration ---

load_conf() {
    local conf_file="${TARGET_DIR}/.infra-ctl.conf"
    if [[ ! -f "$conf_file" ]]; then
        print_error "No .infra-ctl.conf found in ${TARGET_DIR}"
        echo "  Run 'infra-ctl.sh init' first to initialize the repository." >&2
        exit 1
    fi

    # Parse KEY=value lines safely instead of sourcing as executable bash
    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Only accept lines matching KEY=value (no spaces in key, no shell metacharacters)
        if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            declare -g "$key=$value"
        else
            print_error "Malformed line in ${conf_file}: ${line}"
            exit 1
        fi
    done <"$conf_file"
}

save_conf() {
    local repo_url="$1"
    local repo_owner="$2"
    local conf_file="${TARGET_DIR}/.infra-ctl.conf"

    # Preserve KARGO_ENABLED if it exists in the current conf
    local kargo_line=""
    if [[ -f "$conf_file" ]] && grep -q '^KARGO_ENABLED=' "$conf_file"; then
        kargo_line="$(grep '^KARGO_ENABLED=' "$conf_file")"
    fi

    cat >"$conf_file" <<EOF
REPO_URL=${repo_url}
REPO_OWNER=${repo_owner}
EOF

    if [[ -n "$kargo_line" ]]; then
        echo "$kargo_line" >>"$conf_file"
    fi
}

# --- Template rendering ---

# Renders a template file to an output path, replacing {{KEY}} with values.
# Usage: render_template <template_path> <output_path> KEY1=value1 KEY2=value2 ...
render_template() {
    local template="$1"
    local output="$2"
    shift 2

    if [[ ! -f "$template" ]]; then
        print_error "Template not found: $template"
        exit 1
    fi

    local content
    content="$(<"$template")"

    # Use bash parameter expansion instead of sed.
    # sed's s command cannot handle multi-line replacement values (e.g.,
    # {{SOURCE_REPOS}} in appproject.yaml), but bash expansion can.
    local pair key value
    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        content="${content//\{\{${key}\}\}/${value}}"
    done

    mkdir -p "$(dirname "$output")"
    printf '%s\n' "$content" >"$output"
}

# Writes content to a file only if the file does not already exist.
# Returns 0 if written, 1 if skipped.
safe_write() {
    local output="$1"
    local content="$2"

    if [[ -f "$output" ]]; then
        print_warning "Skipping existing file: $output"
        return 1
    fi

    mkdir -p "$(dirname "$output")"
    printf '%s\n' "$content" >"$output"
    return 0
}

# Renders a template to an output path, but only if the output does not exist.
# Returns 0 if written, 1 if skipped.
safe_render_template() {
    local template="$1"
    local output="$2"
    shift 2

    if [[ -f "$output" ]]; then
        print_warning "Skipping existing file: $output"
        return 1
    fi

    render_template "$template" "$output" "$@"
    return 0
}

# --- Detection ---

# Prints detected environment names (one per line).
# Scans k8s/namespaces/*.yaml in TARGET_DIR.
detect_envs() {
    local ns_dir="${TARGET_DIR}/k8s/namespaces"
    if [[ ! -d "$ns_dir" ]]; then
        return
    fi
    local f
    for f in "$ns_dir"/*.yaml; do
        [[ -f "$f" ]] || continue
        basename "$f" .yaml
    done
}

# Prints detected application names (one per line).
# Scans directories under k8s/apps/ in TARGET_DIR.
detect_apps() {
    local apps_dir="${TARGET_DIR}/k8s/apps"
    if [[ ! -d "$apps_dir" ]]; then
        return
    fi
    local d
    for d in "$apps_dir"/*/; do
        [[ -d "$d" ]] || continue
        basename "$d"
    done
}

# Prints detected project names (one per line).
# Scans argocd/projects/*.yaml in TARGET_DIR.
detect_projects() {
    local projects_dir="${TARGET_DIR}/argocd/projects"
    if [[ ! -d "$projects_dir" ]]; then
        return
    fi
    local f
    for f in "$projects_dir"/*.yaml; do
        [[ -f "$f" ]] || continue
        basename "$f" .yaml
    done
}

# Detects the project assigned to an app by parsing an existing ArgoCD Application manifest.
# Usage: detect_app_project <app_name>
# Prints the project name, or "default" if not found.
detect_app_project() {
    local app_name="$1"
    local apps_dir="${TARGET_DIR}/argocd/apps"
    local manifest project_line

    # Find any existing manifest for this app (any env).
    # We check that the filename matches <app_name>-<env>.yaml exactly by
    # verifying the detected env exists as a namespace, avoiding over-matches
    # like "postgres" matching "postgres-ha-dev.yaml".
    local envs=()
    while IFS= read -r env; do
        envs+=("$env")
    done < <(detect_envs)

    local env
    for env in "${envs[@]}"; do
        manifest="${apps_dir}/${app_name}-${env}.yaml"
        [[ -f "$manifest" ]] || continue
        project_line="$(grep '^\s*project:' "$manifest" | head -1 | sed 's/.*project:\s*//')"
        if [[ -n "$project_line" ]]; then
            echo "$project_line"
            return
        fi
    done

    echo "default"
}

# --- Interactive helpers ---

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

# --- Kargo support ---

# Well-known environment names in conventional promotion order.
# Environments not in this list sort alphabetically after all known ones.
KNOWN_ENV_ORDER=(
    dev develop development local
    qa qat
    test testing
    int integration
    stage staging stg
    preprod pre-prod preproduction pre-production
    uat
    perf performance load loadtest
    prod production prd
)

# Sorts environment names by conventional promotion order.
# Known names (dev, qa, staging, production, etc.) are sorted by their
# position in KNOWN_ENV_ORDER. Unknown names sort alphabetically after.
# Usage: sort_envs_by_convention env1 env2 env3 ...
#   Prints sorted names, one per line.
sort_envs_by_convention() {
    local -A rank=()
    local i
    for i in "${!KNOWN_ENV_ORDER[@]}"; do
        rank["${KNOWN_ENV_ORDER[$i]}"]=$i
    done

    local known=()
    local unknown=()
    local env
    for env in "$@"; do
        if [[ -n "${rank[$env]+x}" ]]; then
            known+=("${rank[$env]}:${env}")
        else
            unknown+=("$env")
        fi
    done

    # Sort known by rank, unknown alphabetically
    if [[ ${#known[@]} -gt 0 ]]; then
        printf '%s\n' "${known[@]}" | sort -t: -k1 -n | cut -d: -f2
    fi
    if [[ ${#unknown[@]} -gt 0 ]]; then
        printf '%s\n' "${unknown[@]}" | sort
    fi
}

# Rebuilds promotion-order.txt from the given list of env names, sorted
# by convention. Creates the file if it doesn't exist.
# Usage: rebuild_promotion_order env1 env2 env3 ...
rebuild_promotion_order() {
    local promo_file="${TARGET_DIR}/kargo/promotion-order.txt"
    mkdir -p "${TARGET_DIR}/kargo"
    sort_envs_by_convention "$@" >"$promo_file"
}

# Checks if Kargo is enabled in the project configuration.
# Returns 0 if KARGO_ENABLED=true in .infra-ctl.conf, 1 otherwise.
is_kargo_enabled() {
    local conf_file="${TARGET_DIR}/.infra-ctl.conf"
    [[ -f "$conf_file" ]] || return 1
    grep -q '^KARGO_ENABLED=true$' "$conf_file"
}

# Reads the Kargo promotion order into the PROMOTION_ORDER array.
# Fails if kargo/promotion-order.txt is missing.
# Sets PROMOTION_ORDER to an empty array if the file is empty.
# Usage: read_promotion_order
#   Sets global array: PROMOTION_ORDER
read_promotion_order() {
    local order_file="${TARGET_DIR}/kargo/promotion-order.txt"
    if [[ ! -f "$order_file" ]]; then
        print_error "kargo/promotion-order.txt not found."
        echo "  Run 'infra-ctl.sh init' or create the file manually." >&2
        exit 1
    fi

    PROMOTION_ORDER=()
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        line="$(echo "$line" | xargs)" # trim whitespace
        PROMOTION_ORDER+=("$line")
    done <"$order_file"
}

# Generates Kargo Stage resources for a single app across all existing environments
# in the promotion order. First environment gets a direct-from-Warehouse stage;
# subsequent environments get promoted-from-previous stages.
#
# Usage: generate_kargo_stages <app_name> <image_repo> <kargo_app_dir> <envs_csv>
#   envs_csv: comma-separated list of existing environment names
#   Prints paths of created files, one per line (caller appends to created_files).
#   Requires PROMOTION_ORDER to be set (call read_promotion_order first).
generate_kargo_stages() {
    local app_name="$1"
    local image_repo="$2"
    local kargo_app_dir="$3"
    local envs_csv="$4"

    # Convert csv to associative array for O(1) lookup
    local -A env_set=()
    local env_item
    IFS=',' read -ra env_arr <<<"$envs_csv"
    for env_item in "${env_arr[@]}"; do
        env_set["$env_item"]=1
    done

    local prev_stage=""
    local promo_env
    for promo_env in "${PROMOTION_ORDER[@]}"; do
        [[ -n "${env_set[$promo_env]+x}" ]] || continue

        local stage_file="${kargo_app_dir}/${promo_env}-stage.yaml"
        if [[ -z "$prev_stage" ]]; then
            if safe_render_template \
                "${TEMPLATE_DIR}/kargo/stage-direct.yaml" \
                "$stage_file" \
                "APP_NAME=${app_name}" \
                "ENV=${promo_env}" \
                "IMAGE_REPO=${image_repo}" \
                "REPO_URL=${REPO_URL}"; then
                echo "$stage_file"
            fi
        else
            if safe_render_template \
                "${TEMPLATE_DIR}/kargo/stage-promoted.yaml" \
                "$stage_file" \
                "APP_NAME=${app_name}" \
                "ENV=${promo_env}" \
                "IMAGE_REPO=${image_repo}" \
                "UPSTREAM_STAGE=${app_name}-${prev_stage}" \
                "REPO_URL=${REPO_URL}"; then
                echo "$stage_file"
            fi
        fi
        prev_stage="$promo_env"
    done
}

# --- Repo URL parsing ---

# Extracts the owner from a GitHub repo URL.
# Supports https://github.com/owner/repo and git@github.com:owner/repo.git
extract_repo_owner() {
    local url="$1"

    if [[ "$url" =~ github\.com[:/]([^/]+)/ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        print_error "Could not extract owner from repo URL: $url"
        echo "  Expected format: https://github.com/<owner>/<repo>" >&2
        exit 1
    fi
}

# --- Styled output (gum wrappers with fallback) ---

print_header() {
    if command -v gum &>/dev/null; then
        gum style --bold --foreground 212 "$1"
    else
        echo "=== $1 ==="
    fi
}

print_success() {
    if command -v gum &>/dev/null; then
        gum style --foreground 78 "  ✓ $1"
    else
        echo "  OK: $1"
    fi
}

print_warning() {
    if command -v gum &>/dev/null; then
        gum style --foreground 214 "  ⚠ $1"
    else
        echo "  WARN: $1" >&2
    fi
}

print_error() {
    if command -v gum &>/dev/null; then
        gum style --bold --foreground 196 "  ✗ $1"
    else
        echo "  ERROR: $1" >&2
    fi
}

print_info() {
    if command -v gum &>/dev/null; then
        gum style --foreground 75 "  $1"
    else
        echo "  $1"
    fi
}

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

# Prints a summary of created files.
# Usage: print_summary "${created_files[@]}"
print_summary() {
    local files=("$@")
    if [[ ${#files[@]} -eq 0 ]]; then
        print_warning "No files were created."
        return
    fi
    echo ""
    print_header "Created:"
    local f
    for f in "${files[@]}"; do
        print_success "$f"
    done
    echo ""
}

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
