#!/usr/bin/env bash
set -euo pipefail

# Resolve paths relative to the script that sources this file.
# SCRIPT_DIR is where infra-ctl.sh or cluster-ctl.sh lives (tooling/).
# TEMPLATE_DIR is where templates live (tooling/templates/).
# TARGET_DIR is where the script operates (default: current working directory).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"
TARGET_DIR="${PWD}"

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

# --- Argument parsing ---

# Extracts --target-dir from arguments. Sets TARGET_DIR.
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
    done < "$conf_file"
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

    cat > "$conf_file" <<EOF
REPO_URL=${repo_url}
REPO_OWNER=${repo_owner}
EOF

    if [[ -n "$kargo_line" ]]; then
        echo "$kargo_line" >> "$conf_file"
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
    printf '%s\n' "$content" > "$output"
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
    printf '%s\n' "$content" > "$output"
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

# --- Kargo support ---

# Checks if Kargo is enabled in the project configuration.
# Returns 0 if KARGO_ENABLED=true in .infra-ctl.conf, 1 otherwise.
is_kargo_enabled() {
    local conf_file="${TARGET_DIR}/.infra-ctl.conf"
    [[ -f "$conf_file" ]] || return 1
    grep -q '^KARGO_ENABLED=true$' "$conf_file"
}

# Reads the Kargo promotion order into the PROMOTION_ORDER array.
# Fails if kargo/promotion-order.txt is missing.
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
        line="$(echo "$line" | xargs)"  # trim whitespace
        PROMOTION_ORDER+=("$line")
    done < "$order_file"

    if [[ ${#PROMOTION_ORDER[@]} -eq 0 ]]; then
        print_error "kargo/promotion-order.txt is empty."
        exit 1
    fi
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
