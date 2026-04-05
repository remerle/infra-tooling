#!/usr/bin/env bash
# Smoke tests for flag-first prompt helpers in lib/common.sh.
#
# Plain bash instead of bats to keep this runnable in environments
# without a test framework installed. Replace with bats if/when
# dependency is added.
#
# Usage: test/lib/common_test.sh

set -uo pipefail

# Resolve repo root from this script's location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "$REPO_ROOT"

PASSED=0
FAILED=0
FAILURES=()

# Helper: run a sub-test, capture output and exit code, assert expectations.
# Usage: run_test "name" "expected_exit" "expected_substring" -- <cmd...>
run_test() {
    local name="$1" expected_exit="$2" expected_out="$3"
    shift 3
    [[ "$1" == "--" ]] && shift

    local out exit_code
    out="$("$@" 2>&1)" || exit_code=$?
    exit_code="${exit_code:-0}"

    local ok=1
    if [[ "$exit_code" != "$expected_exit" ]]; then
        ok=0
        FAILURES+=("${name}: expected exit ${expected_exit}, got ${exit_code}")
    fi
    if [[ -n "$expected_out" ]] && [[ "$out" != *"$expected_out"* ]]; then
        ok=0
        FAILURES+=("${name}: expected output to contain '${expected_out}', got: ${out}")
    fi

    if [[ "$ok" == 1 ]]; then
        printf "  ok: %s\n" "$name"
        PASSED=$((PASSED + 1))
    else
        printf "  FAIL: %s\n" "$name"
        FAILED=$((FAILED + 1))
    fi
}

# Write a helper-invoker script to a temp file so `source lib/common.sh`
# works correctly (common.sh uses BASH_SOURCE[1] which breaks inside bash -c).
make_runner() {
    local runner="$1"
    shift
    cat >"$runner" <<EOF
#!/usr/bin/env bash
source lib/common.sh
$@
EOF
    chmod +x "$runner"
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Running flag-first helper smoke tests..."
echo ""

# --- require_tty ---
make_runner "$TMP/tty1.sh" 'require_tty "--name"'
run_test "require_tty dies without TTY" 1 "--name is required when not running interactively" \
    -- bash -c "'$TMP/tty1.sh' </dev/null"

# --- parse_set_kv ---
make_runner "$TMP/parse1.sh" '
declare -A values
parse_set_kv "IMAGE=nginx:latest" values
echo "${values[IMAGE]}"
'
run_test "parse_set_kv parses simple KEY=VAL" 0 "nginx:latest" \
    -- "$TMP/parse1.sh"

make_runner "$TMP/parse2.sh" '
declare -A v
parse_set_kv "URL=postgres://user:pass@host:5432/db" v
echo "${v[URL]}"
'
run_test "parse_set_kv preserves values containing =" 0 "postgres://user:pass@host:5432/db" \
    -- "$TMP/parse2.sh"

make_runner "$TMP/parse3.sh" '
declare -A v
parse_set_kv "noequals" v
'
run_test "parse_set_kv rejects input without =" 1 "--set expects KEY=VAL" \
    -- "$TMP/parse3.sh"

make_runner "$TMP/parse4.sh" '
declare -A v
parse_set_kv "=foo" v
'
run_test "parse_set_kv rejects empty KEY" 1 "non-empty KEY" \
    -- "$TMP/parse4.sh"

# --- require_yes ---
make_runner "$TMP/yes1.sh" 'require_yes "false" "delete stuff"'
run_test "require_yes dies without --yes when no TTY" 1 "--yes is required" \
    -- bash -c "'$TMP/yes1.sh' </dev/null"

make_runner "$TMP/yes2.sh" '
require_yes "true" "delete stuff"
echo proceeded
'
run_test "require_yes passes when yes=true" 0 "proceeded" \
    -- "$TMP/yes2.sh"

echo ""
echo "Passed: $PASSED"
echo "Failed: $FAILED"
if [[ $FAILED -gt 0 ]]; then
    echo ""
    echo "Failures:"
    printf "  %s\n" "${FAILURES[@]}"
    exit 1
fi
