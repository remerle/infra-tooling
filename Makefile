SHELL_FILES := $(wildcard *.sh) $(wildcard lib/*.sh)

.PHONY: validate fmt fmt-check lint lint-contracts test

# Run all checks (formatting + linting)
validate: fmt-check lint lint-contracts test

# Format shell scripts in place
fmt:
	shfmt -w -i 4 -bn -ci $(SHELL_FILES)

# Check formatting without modifying files
fmt-check:
	shfmt -d -i 4 -bn -ci $(SHELL_FILES)

# Lint shell scripts (SC2153 is a false positive for our load_conf pattern)
lint:
	shellcheck -s bash -e SC2153 $(SHELL_FILES)

# Enforce the flag-first command contract mechanically. These grep checks
# catch regressions of patterns the branch already removed; add new checks
# here as new contract rules are introduced.
lint-contracts:
	@set -e; \
	fail=0; \
	if grep -nE '\[\[ -z "\$$\{2:-\}" \]\]' $(SHELL_FILES) | grep -v 'lint-ok'; then \
		echo "ERROR: inline flag-value check found -- use require_flag_value \"--flag\" \"\$$\{2:-\}\" instead"; \
		fail=1; \
	fi; \
	if grep -nE 'run_cmd_sh[^#]*\$$\{[a-z_][a-z0-9_]*\}' $(SHELL_FILES) | grep -v 'lint-ok'; then \
		echo "ERROR: run_cmd_sh with interpolated variable found -- convert to argv run_cmd, or validate the value first and audit this check"; \
		fail=1; \
	fi; \
	if grep -nE '^\s*if \[\[ "\$$\{?yes\}?" != "true" \]\] && \[\[ -t 0 \]\]' $(SHELL_FILES) | grep -v 'lint-ok'; then \
		echo "ERROR: TTY-gated confirm without require_yes -- use require_yes \"\$$yes\" \"<action>\" instead"; \
		fail=1; \
	fi; \
	[ $$fail -eq 0 ]

# Run the common.sh smoke tests
test:
	bash test/lib/common_test.sh
