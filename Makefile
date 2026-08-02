SH_FILES = bin/cleanmymac lib/common.sh lib/wizard.sh install.sh uninstall.sh scripts/docs-check.sh $(wildcard cleaners/*.sh)
BASH_HELPERS = $(wildcard tests/helpers/*.bash)

.PHONY: all lint fmt test docs-check install uninstall

all: lint test docs-check

lint:
	shellcheck $(SH_FILES) $(BASH_HELPERS)
	shfmt -d -i 2 -ci $(SH_FILES)

fmt:
	shfmt -w -i 2 -ci $(SH_FILES)

test:
	bats tests

docs-check:
	./scripts/docs-check.sh

install:
	./install.sh

uninstall:
	./uninstall.sh
