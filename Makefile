SH_FILES = bin/scrubmac bin/cleanmymac install.sh uninstall.sh completions/scrubmac.bash \
	$(wildcard lib/*.sh) $(wildcard scripts/*.sh) $(wildcard cleaners/*.sh)
BASH_HELPERS = $(wildcard tests/helpers/*.bash)
BATS_FILES = $(wildcard tests/*.bats)
# In .bats files: single-quoted $ is deliberate (it expands in generated
# scripts), and `run` subshells trip the subshell-assignment checks.
BATS_SC_EXCLUDES = SC2016,SC2030,SC2031

.PHONY: all lint fmt test docs-check bash32 demo install uninstall

all: lint test docs-check

lint:
	shellcheck $(SH_FILES) $(BASH_HELPERS)
	shellcheck -e $(BATS_SC_EXCLUDES) $(BATS_FILES)
	shfmt -d -i 2 -ci $(SH_FILES) $(BASH_HELPERS)
	@# bash 3.2 parses locale-dependent identifiers: an unbraced $$VAR directly
	@# followed by a non-ASCII char can swallow that char into the variable name.
	@perl -ne 'if (/\$$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]/) { print "unbraced expansion before non-ASCII (bash 3.2 hazard): $$ARGV:$$.: $$_"; $$found = 1 } END { exit($$found ? 1 : 0) }' $(SH_FILES) $(BASH_HELPERS)
	@# Bats ignores `! cmd`: errexit never fires on a negated command (SC2314).
	@! grep -nE '^[[:space:]]*! ' $(BATS_FILES) || { echo "use refute instead of '! cmd' in tests (see tests/helpers/setup.bash)"; exit 1; }

fmt:
	shfmt -w -i 2 -ci $(SH_FILES) $(BASH_HELPERS)

test:
	bats --print-output-on-failure tests

docs-check:
	./scripts/docs-check.sh

# The bash that ships with macOS must at least parse everything.
bash32:
	@for f in $(SH_FILES); do /bin/bash -n "$$f" || exit 1; done
	@/bin/bash --version | head -n 1

demo:
	./scripts/render-demo.sh

install:
	./install.sh

uninstall:
	./uninstall.sh
