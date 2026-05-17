# Makefile — AGmind task runner
# All targets are thin wrappers over existing scripts/tests (no new logic).
# GNU Make 4.3 / aarch64 (DGX OS). Run `make help` for the list.

SHELL := /bin/bash

.PHONY: help lint test test-unit test-integration compose-config \
        manifest-check image-check release-check \
        registry-codegen registry-verify \
        golden-test golden-update golden-update-all \
        landmines-check landmines-sync

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*##"}{printf "  \033[36m%-18s\033[0m %s\n",$$1,$$2}'

lint: ## shellcheck -S warning lib/*.sh scripts/*.sh install.sh (repo Definition of Done gate)
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

manifest-check: ## Verify every image:tag has an arm64 manifest (repo Definition of Done gate)
	bash tests/compose/test_image_tags_exist.sh templates/docker-compose.yml

image-check: manifest-check ## Alias for manifest-check

release-check: ## Check VERSION/RELEASE/release-manifest.json consistency
	python3 scripts/check-manifest-versions.py

registry-codegen: ## Regenerate lib/_registry.indexed.sh from templates/services/registry.yaml
	bash scripts/codegen/registry-to-indexed.sh

registry-verify: ## CI gate — run codegen, fail if generated artifact has drift
	bash tests/integration/test_registry_codegen_drift.sh

golden-test: ## Run all 5 golden scenarios (hermetic — no docker daemon needed)
	bash tests/golden/run.sh --all

golden-update: ## Interactive golden snapshot update for one scenario (usage: make golden-update SCENARIO=<name>)
	@if [[ -z "$$SCENARIO" ]]; then \
	  echo "Usage: make golden-update SCENARIO=<name>"; \
	  echo "Available scenarios: $$(awk -F'\t' 'NR>0 && $$1!="" && !/^#/ {print $$1}' tests/golden/scenarios.list | tr '\n' ' ')"; \
	  exit 2; \
	fi; \
	AGMIND_GOLDEN_ACCEPT=$${AGMIND_GOLDEN_ACCEPT:-1} bash tests/golden/run.sh --update "$$SCENARIO"; \
	python3 scripts/golden-diff-summary.py tests/golden/.last-update.diff || true

golden-update-all: ## Bulk update all golden scenarios (requires AGMIND_GOLDEN_ACCEPT=1)
	AGMIND_GOLDEN_ACCEPT=1 bash tests/golden/run.sh --update --update-all

landmines-check: ## Run landmine enforcer against tests/golden/expected/
	bash tests/unit/test_golden_no_known_landmines.sh

landmines-sync: ## Regenerate tests/lint/LANDMINES.tsv from LANDMINES.md
	bash scripts/landmines-sync.sh
