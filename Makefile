# CallRec — Build helpers
#
# Usage:
#   make setup      # Fetch & build dependencies
#   make build      # Build debug (no Xcode required)
#   make release    # Build release
#   make install    # Install driver (requires sudo)
#   make test       # Run ring buffer tests
#   make project    # Generate Xcode project (optional)

.PHONY: setup build release clean install uninstall test project

DRIVER_INSTALL_PATH = /Library/Audio/Plug-Ins/HAL/CallRec.driver
BUILD_SCRIPT = ./build.sh

# Fetch and build dependencies
setup:
	@echo "==> Fetching libASPL..."
	@mkdir -p Dependencies
	@if [ ! -d Dependencies/libASPL/.git ]; then \
		rm -rf Dependencies/libASPL; \
		git clone --depth 1 https://github.com/gavv/libASPL.git Dependencies/libASPL; \
	fi
	@echo "==> Dependencies ready. Run 'make build' to build."

# Build debug (uses build.sh, no Xcode IDE required)
build:
	@$(BUILD_SCRIPT) debug

# Build release
release:
	@$(BUILD_SCRIPT) release

# Build driver only
driver:
	@$(BUILD_SCRIPT) debug --driver-only

# Build app only
app:
	@$(BUILD_SCRIPT) debug --app-only

# Install driver (requires admin)
install:
	@echo "==> Installing CallRec audio driver..."
	@sudo rm -rf $(DRIVER_INSTALL_PATH)
	@sudo cp -R build/dist/CallRec.driver $(DRIVER_INSTALL_PATH)
	@sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
	@echo "==> Driver installed. coreaudiod restarted."

# Uninstall driver
uninstall:
	@echo "==> Removing CallRec audio driver..."
	@sudo rm -rf $(DRIVER_INSTALL_PATH)
	@sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
	@echo "==> Driver removed."

# Run ring buffer tests
test:
	@echo "==> Running ring buffer tests..."
	@SDK="$$(xcrun --show-sdk-path)" && \
		clang -I Common -isysroot "$$SDK" Tests/test_ring_buffer.c -o build/test_ring_buffer && \
		build/test_ring_buffer

# Generate Xcode project (optional — for IDE users)
project:
	@echo "==> Generating Xcode project..."
	@if [ -f /tmp/xcodegen/bin/xcodegen ]; then \
		/tmp/xcodegen/bin/xcodegen generate; \
	elif command -v xcodegen >/dev/null 2>&1; then \
		xcodegen generate; \
	else \
		echo "xcodegen not found. Download: curl -sL https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip -o /tmp/xcodegen.zip && unzip -o /tmp/xcodegen.zip -d /tmp"; \
		exit 1; \
	fi

# Clean build artifacts
clean:
	@rm -rf build/
	@rm -rf DerivedData/
	@echo "==> Clean."
