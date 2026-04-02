SHELL_FILES := $(wildcard *.sh) $(wildcard lib/*.sh)

.PHONY: validate fmt fmt-check lint

# Run all checks (formatting + linting)
validate: fmt-check lint

# Format shell scripts in place
fmt:
	shfmt -w -i 4 -bn -ci $(SHELL_FILES)

# Check formatting without modifying files
fmt-check:
	shfmt -d -i 4 -bn -ci $(SHELL_FILES)

# Lint shell scripts (SC2153 is a false positive for our load_conf pattern)
lint:
	shellcheck -s bash -e SC2153 $(SHELL_FILES)
