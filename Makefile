# Claude Companion — developer task runner. Thin wrapper around scripts/.
.DEFAULT_GOAL := help
DERIVED := .build/DerivedData

.PHONY: help run rebuild test generate clean

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

run: ## Regenerate project, build, and launch the app
	./scripts/run.sh

rebuild: ## Wipe build products, then full rebuild + launch
	./scripts/run.sh --clean

test: ## Run the unit test suite (swift test)
	swift test --package-path CompanionKit

generate: ## Regenerate ClaudeCompanion.xcodeproj from project.yml
	xcodegen generate

clean: ## Remove build products (no rebuild)
	rm -rf "$(DERIVED)/Build/Products" "$(DERIVED)/Build/Intermediates.noindex" CompanionKit/.build/release
