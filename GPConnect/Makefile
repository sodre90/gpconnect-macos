SCHEME = GPConnect
BUILD_DIR = .build
APP_NAME = GPConnect.app
CLI_NAME = gpconnect
INSTALL_DIR = /usr/local/bin

.PHONY: all app cli clean install-cli run

all: app cli

# Build the menu bar app
app:
	xcodebuild -project GPConnect.xcodeproj \
		-scheme $(SCHEME) \
		-configuration Release \
		-derivedDataPath $(BUILD_DIR) \
		build
	@echo "App built at: $(BUILD_DIR)/Build/Products/Release/$(APP_NAME)"

# Build the CLI tool
cli:
	cd $(CURDIR) && swift build -c release
	@echo "CLI built at: .build/release/$(CLI_NAME)"

# Install CLI to /usr/local/bin
install-cli: cli
	cp .build/release/$(CLI_NAME) $(INSTALL_DIR)/$(CLI_NAME)
	@echo "Installed $(CLI_NAME) to $(INSTALL_DIR)"

# Install app to /Applications
install-app: app
	cp -R $(BUILD_DIR)/Build/Products/Release/$(APP_NAME) /Applications/
	@echo "Installed $(APP_NAME) to /Applications"

# Install both
install: install-app install-cli

# Run the app
run: app
	open $(BUILD_DIR)/Build/Products/Release/$(APP_NAME)

clean:
	rm -rf $(BUILD_DIR)
	rm -rf .build

# Generate Xcode project (requires xcodegen: brew install xcodegen)
project:
	xcodegen generate
