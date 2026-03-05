# CallRec — Build helpers
#
# Prerequisites:
#   brew install xcodegen
#   make setup      # Fetch dependencies
#   make project    # Generate Xcode project
#   make build      # Build debug
#   make install    # Install driver (requires sudo)

.PHONY: setup project build release clean install uninstall test

DRIVER_INSTALL_PATH = /Library/Audio/Plug-Ins/HAL/CallRec.driver

# Fetch and build dependencies
setup:
	@echo "==> Fetching libASPL..."
	@mkdir -p Dependencies
	@if [ ! -d Dependencies/libASPL ]; then \
		git clone --depth 1 https://github.com/gavv/libASPL.git Dependencies/libASPL; \
	fi
	@echo "==> Building libASPL..."
	@cd Dependencies/libASPL && \
		mkdir -p build && cd build && \
		cmake .. -DCMAKE_BUILD_TYPE=Release && \
		cmake --build . --config Release
	@echo "==> Dependencies ready."

# Generate Xcode project from project.yml
project:
	@echo "==> Generating Xcode project..."
	@xcodegen generate
	@echo "==> Opening CallRec.xcodeproj..."
	@open CallRec.xcodeproj

# Build debug
build:
	xcodebuild -project CallRec.xcodeproj \
		-scheme CallRec \
		-configuration Debug \
		build

# Build release
release:
	xcodebuild -project CallRec.xcodeproj \
		-scheme CallRec \
		-configuration Release \
		build

# Install driver (requires admin)
install:
	@echo "==> Installing CallRec audio driver..."
	@sudo rm -rf $(DRIVER_INSTALL_PATH)
	@sudo cp -R build/Release/CallRec.driver $(DRIVER_INSTALL_PATH)
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
	@cd Tests && cc -std=c11 -I../Common -o test_ring_buffer test_ring_buffer.c -lm && ./test_ring_buffer
	@echo ""

# Clean build artifacts
clean:
	@rm -rf build/
	@rm -rf DerivedData/
	@rm -f Tests/test_ring_buffer
	@echo "==> Clean."
