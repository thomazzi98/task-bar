APP      := dist/TaskBar.app
BINARY   := $(APP)/Contents/MacOS/TaskBar
INSTALL  := /Applications/TaskBar.app

.DEFAULT_GOAL := help
.PHONY: help test build app run install uninstall screenshots icon clean

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

test: ## Run the unit tests
	swift test

build: ## Compile a debug build
	swift build

app: ## Test, build and assemble dist/TaskBar.app
	scripts/build.sh

run: ## Build the app (skipping tests) and launch it
	scripts/build.sh --skip-tests --open

install: app ## Build and copy the app to /Applications
	@pkill -x TaskBar 2>/dev/null || true
	rm -rf "$(INSTALL)"
	cp -R "$(APP)" "$(INSTALL)"
	open "$(INSTALL)"

uninstall: ## Remove the app from /Applications (your data is kept)
	@pkill -x TaskBar 2>/dev/null || true
	rm -rf "$(INSTALL)"

screenshots: ## Re-render the README screenshots with sample data
	scripts/build.sh --skip-tests
	"$(BINARY)" --render-snapshots docs/screenshots

icon: ## Regenerate Resources/AppIcon.icns
	swift scripts/make-icon.swift Resources/AppIcon.icns

clean: ## Delete build products
	swift package clean
	rm -rf dist
