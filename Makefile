# Makefile — AGmind task runner
# All targets are thin wrappers over existing scripts/tests (no new logic).
# GNU Make 4.3 / aarch64 (DGX OS). Run `make help` for the list.

SHELL := /bin/bash

.PHONY: help lint test test-unit test-integration compose-config \
        manifest-check image-check release-check

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*##"}{printf "  \033[36m%-18s\033[0m %s\n",$$1,$$2}'

lint: ## shellcheck -S warning lib/*.sh scripts/*.sh install.sh (CLAUDE.md §10)
	shellcheck -S warning lib/*.sh scripts/*.sh install.sh

test: ## Run full local regression suite (tests/run_all.sh)
	bash tests/run_all.sh

test-unit: ## Run only unit tests (tests/unit/test_*.sh)
	@rc=0; for t in tests/unit/test_*.sh; do \
	  echo "==> $$t"; bash "$$t" || { c=$$?; [[ $$c -eq 77 ]] && echo "  SKIP" || { echo "  FAIL($$c)"; rc=1; }; }; \
	done; exit $$rc

test-integration: ## Run only integration tests (tests/integration/test_*.sh)
	@rc=0; for t in tests/integration/test_*.sh; do \
	  echo "==> $$t"; bash "$$t" || { c=$$?; [[ $$c -eq 77 ]] && echo "  SKIP" || { echo "  FAIL($$c)"; rc=1; }; }; \
	done; exit $$rc

compose-config: ## Validate docker-compose YAML schema
	docker compose -f templates/docker-compose.yml config -q

manifest-check: ## Verify every image:tag has an arm64 manifest (CLAUDE.md §10)
	bash tests/compose/test_image_tags_exist.sh templates/docker-compose.yml

image-check: manifest-check ## Alias for manifest-check

release-check: ## Check VERSION/RELEASE/release-manifest.json consistency
	python3 scripts/check-manifest-versions.py
