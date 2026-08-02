SH_FILES = bin/cleanmymac lib/common.sh lib/wizard.sh install.sh uninstall.sh scripts/docs-check.sh $(wildcard cleaners/*.sh)
BASH_HELPERS = $(wildcard tests/helpers/*.bash)

.PHONY: all lint fmt test docs-check install uninstall

all: lint test docs-check

lint:
	shellcheck $(SH_FILES) $(BASH_HELPERS)
	shfmt -d -i 2 -ci $(SH_FILES)
	@# bash 3.2 parses locale-dependent identifiers: an unbraced $$VAR directly
	@# followed by a non-ASCII char can swallow that char into the variable name.
	@perl -ne 'if (/\$$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]/) { print "unbraced expansion before non-ASCII (bash 3.2 hazard): $$ARGV:$$.: $$_"; $$found = 1 } END { exit($$found ? 1 : 0) }' $(SH_FILES) $(BASH_HELPERS)

fmt:
	shfmt -w -i 2 -ci $(SH_FILES)

test:
	bats --print-output-on-failure tests

docs-check:
	./scripts/docs-check.sh

install:
	./install.sh

uninstall:
	./uninstall.sh
