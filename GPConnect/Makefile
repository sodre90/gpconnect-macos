BUILD_DIR = .build
APP_DIR = $(BUILD_DIR)/app
APP_NAME = GPConnect.app
CLI_NAME = gpconnect
CLI_DIR = cli
INSTALL_DIR = /usr/local/bin
VERSION_FILE = ../VERSION
CLI_VERSION_SWIFT = $(CLI_DIR)/Sources/gpconnect-cli/Version.swift

.PHONY: all app cli clean install install-app install-cli run project version

all: app cli

# Build the menu bar app. Delegates to build.sh rather than xcodebuild, which
# is unavailable without a full Xcode install — see CLAUDE.md.
app:
	./build.sh

# Regenerate the CLI's version constant from the repo-root VERSION file.
# build.sh stamps the app's Info.plist from the same file.
version:
	@printf '// Generated from the repo-root VERSION file by `make version`. Do not edit by hand.\nlet version = "%s"\n' \
		"$$(tr -d '[:space:]' < $(VERSION_FILE))" > $(CLI_VERSION_SWIFT)
	@echo "Stamped $(CLI_VERSION_SWIFT) with $$(tr -d '[:space:]' < $(VERSION_FILE))"

# Build the CLI tool
cli: version
	swift build --package-path $(CLI_DIR) -c release
	@echo "CLI built at: $(CLI_DIR)/.build/release/$(CLI_NAME)"

# Install CLI to /usr/local/bin
install-cli: cli
	cp $(CLI_DIR)/.build/release/$(CLI_NAME) $(INSTALL_DIR)/$(CLI_NAME)
	@echo "Installed $(CLI_NAME) to $(INSTALL_DIR)"

# Install app to /Applications
install-app: app
	cp -R $(APP_DIR)/$(APP_NAME) /Applications/
	@echo "Installed $(APP_NAME) to /Applications"

# Install both
install: install-app install-cli

# Run the app
run: app
	open $(APP_DIR)/$(APP_NAME)

clean:
	rm -rf $(BUILD_DIR)
	rm -rf $(CLI_DIR)/.build

# Generate Xcode project (requires xcodegen: brew install xcodegen)
project:
	xcodegen generate
