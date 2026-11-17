NVIM_BIN ?= nvim
PYTHON ?= python3

.PHONY: test test-foundation test-phase0 test-phase1 test-phase2 test-phase3 test-phase4 test-phase5 test-phase6 test-phase7 test-phase8 test-phase9 check-translations check-native build build-native audit-native sync sync-fetch sync-native check-reproducible release-check

# The aggregate suite shares generated catalogs and release checks. Do not let
# `make -j test` run those readers/writers concurrently; individual phase targets
# remain independently runnable.
.NOTPARALLEL: test

test: test-phase0 test-phase1 test-phase2 test-phase3 test-phase4 test-phase5 test-phase6 test-phase7 test-phase8 test-phase9

test-phase0:
	NVIM_BIN=$(NVIM_BIN) ./tests/phase0/run.sh

test-phase1:
	NVIM_BIN=$(NVIM_BIN) ./tests/phase1/run.sh

test-phase2: build
	NVIM_BIN=$(NVIM_BIN) ./tests/phase2/run.sh
	PYTHONDONTWRITEBYTECODE=1 NVIM_ZH_ROOT=$(CURDIR) $(PYTHON) tests/phase2/test_catalog_tool.py

check-translations:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tools/catalog_tool.py check

check-native:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tools/native_catalog.py check

# The pinned upstream catalog lives in build/upstream/; fetch it explicitly the
# first time (network), verify it every time (sha256), then build offline.
build-native: check-native
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tools/native_catalog.py sync
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tools/native_catalog.py build --expect-sha pinned

sync-native:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tools/native_catalog.py sync --fetch

# `make sync --fetch` is not valid: --fetch belongs to the tool, not to make.
# This target is the explicit read-only network entry point for the UI catalog.
sync-fetch:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tools/catalog_tool.py sync --fetch

audit-native:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tools/native_catalog.py audit --binary $(NVIM_BIN)

build:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tools/catalog_tool.py build

test-phase3: build
	NVIM_BIN=$(NVIM_BIN) ./tests/phase3/run.sh

test-phase4: build
	NVIM_BIN=$(NVIM_BIN) ./tests/phase4/run.sh

test-phase5: build
	NVIM_BIN=$(NVIM_BIN) ./tests/phase5/run.sh

sync:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tools/catalog_tool.py sync

# `set -e` is load-bearing: without it the recipe's exit status is the last
# command's (`echo`), so a failing `diff` still printed REPRODUCIBLE_BUILD=PASS
# and this gate could never fail. release-check depends on it, so an inert gate
# also disabled the release-blocking reproducibility check.
check-reproducible:
	@set -e; \
	tmp=$$(mktemp -d "$${TMPDIR:-/tmp}/dsh-nvim-zh-repro-$$(date +%Y%m%dT%H%M%S)-XXXXXX"); \
	trap 'rm -rf "$$tmp"' EXIT; \
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tools/catalog_tool.py build --output "$$tmp"; \
	diff -ru lua/nvim-zh/catalogs/generated "$$tmp"; \
	echo REPRODUCIBLE_BUILD=PASS

release-check: check-reproducible
	@set -e; \
	package_tmp=$$(mktemp -d "$${TMPDIR:-/tmp}/dsh-nvim-zh-package-XXXXXX"); \
	trap 'rm -rf -- "$$package_tmp"' EXIT; \
	mkdir "$$package_tmp/candidate"; \
	tar -C "$(CURDIR)" --exclude='./.git' -cf "$$package_tmp/candidate.tar" .; \
	tar -C "$$package_tmp/candidate" -xf "$$package_tmp/candidate.tar"; \
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tools/catalog_tool.py release-check --package-dir "$$package_tmp/candidate"

test-phase6: check-translations
	PYTHONDONTWRITEBYTECODE=1 NVIM_ZH_ROOT=$(CURDIR) NVIM_BIN=$(NVIM_BIN) $(PYTHON) tests/phase6/test_maintenance.py
	PYTHONDONTWRITEBYTECODE=1 NVIM_ZH_ROOT=$(CURDIR) NVIM_BIN=$(NVIM_BIN) $(PYTHON) tests/phase6/test_help_relay.py
	PYTHONDONTWRITEBYTECODE=1 NVIM_ZH_ROOT=$(CURDIR) NVIM_BIN=$(NVIM_BIN) $(PYTHON) tests/phase6/test_catalog_safety.py
	$(MAKE) sync
	$(MAKE) release-check

test-phase7: build
	NVIM_BIN=$(NVIM_BIN) PYTHON=$(PYTHON) ./tests/phase7/run.sh

test-phase8: build
	NVIM_BIN=$(NVIM_BIN) PYTHON=$(PYTHON) ./tests/phase8/run.sh

test-phase9:
	NVIM_BIN=$(NVIM_BIN) PYTHON=$(PYTHON) ./tests/phase9/run.sh

test-foundation: check-translations test-phase2
	NVIM_BIN=$(NVIM_BIN) ./tests/phase7/foundation.sh
