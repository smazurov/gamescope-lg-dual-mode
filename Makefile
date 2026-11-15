LUACHECK ?= luacheck

.PHONY: check test lint check-install install upgrade uninstall

check: test lint

test:
	luajit -E tests/test_single_file.lua gamescope-lg-dual-mode.lua
	bash tests/test_install.sh

lint:
	$(LUACHECK) --config .luacheckrc gamescope-lg-dual-mode.lua tests/test_single_file.lua
	bash -n install.sh tests/test_install.sh
	shellcheck install.sh tests/test_install.sh

# All installation targets affect only the current user's configuration.
check-install:
	bash install.sh --check

install:
	bash install.sh

upgrade:
	bash install.sh --upgrade

uninstall:
	bash install.sh --uninstall
