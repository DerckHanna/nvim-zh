NVIM_BIN ?= nvim
PYTHON ?= python3

.PHONY: check-syntax check-translations check-adapters check-native build build-adapters build-native build-resources check-resources check-reproducible test-unit test-contract test-tools test-integration test-e2e test-upstream test release-check sync sync-fetch sync-native audit-native

# Suites share generated catalogs. Keep aggregate readers/writers sequential.
.NOTPARALLEL: test build-resources release-check

test: test-unit test-contract test-tools test-integration test-e2e

check-syntax:
	NVIM_BIN=$(NVIM_BIN) PYTHON=$(PYTHON) ./tests/run/syntax.sh

check-translations:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tools/catalog_tool.py check
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tools/toolchain_catalog.py check

check-native:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tools/native_catalog.py check

build-adapters:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tools/adapter_tool.py build

check-adapters:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tools/adapter_tool.py check

build: build-adapters
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tools/catalog_tool.py build

build-native: check-native
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tools/native_catalog.py sync
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tools/native_catalog.py build --expect-sha pinned

build-resources: build build-native
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tools/resource_bundle.py build

check-resources: check-adapters
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tools/resource_bundle.py check

check-reproducible:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tools/check_reproducible.py

test-unit: build
	NVIM_BIN=$(NVIM_BIN) PYTHON=$(PYTHON) ./tests/run/unit.sh

test-contract: build
	NVIM_BIN=$(NVIM_BIN) PYTHON=$(PYTHON) ./tests/run/contract.sh

test-tools: check-translations
	NVIM_BIN=$(NVIM_BIN) PYTHON=$(PYTHON) ./tests/run/tools.sh

test-integration: check-resources
	NVIM_BIN=$(NVIM_BIN) PYTHON=$(PYTHON) ./tests/run/integration.sh

test-e2e: check-resources
	NVIM_BIN=$(NVIM_BIN) PYTHON=$(PYTHON) ./tests/run/e2e.sh

test-upstream: check-resources
	NVIM_BIN=$(NVIM_BIN) PYTHON=$(PYTHON) ./tests/run/upstream.sh

release-check: check-reproducible check-resources
	@set -e; \
	package_tmp=$$(mktemp -d "$${TMPDIR:-/tmp}/nvim-zh-package-XXXXXX"); \
	trap 'rm -rf -- "$$package_tmp"' EXIT; \
	mkdir "$$package_tmp/candidate"; \
	set -- --exclude='./.git'; \
	for metadata in .agents .codex .aws; do \
		if test -n "$$(find "$$metadata" -maxdepth 0 -type d -empty 2>/dev/null)"; then \
			set -- "$$@" --exclude="./$$metadata"; \
		fi; \
	done; \
	tar -C "$(CURDIR)" "$$@" -cf "$$package_tmp/candidate.tar" .; \
	tar -C "$$package_tmp/candidate" -xf "$$package_tmp/candidate.tar"; \
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tools/catalog_tool.py release-check --package-dir "$$package_tmp/candidate"

sync:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tools/catalog_tool.py sync

sync-fetch:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tools/catalog_tool.py sync --fetch

sync-native:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tools/native_catalog.py sync --fetch

audit-native:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tools/native_catalog.py audit --binary $(NVIM_BIN)
