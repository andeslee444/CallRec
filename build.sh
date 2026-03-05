#!/bin/bash
# CallRec Build Script — builds without full Xcode (CLT only)
# Usage: ./build.sh [debug|release] [--driver-only] [--app-only]
set -euo pipefail

CONFIG="${1:-debug}"
DRIVER_ONLY=false
APP_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --driver-only) DRIVER_ONLY=true ;;
        --app-only)    APP_ONLY=true ;;
    esac
done

ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="$(xcrun --show-sdk-path)"
BUILD="$ROOT/build"
DIST="$BUILD/dist"

OPT_FLAGS="-O0 -g"
if [ "$CONFIG" = "release" ]; then
    OPT_FLAGS="-O2"
fi

echo "=== CallRec Build ($CONFIG) ==="
echo "SDK: $SDK"
echo ""

# ──────────────────────────────────────────────────────────
# Step 1: Build libASPL static library (if needed)
# ──────────────────────────────────────────────────────────
LIBASPL_A="$BUILD/libASPL/libASPL.a"
if [ ! -f "$LIBASPL_A" ]; then
    echo "─── Building libASPL ───"
    mkdir -p "$BUILD/libASPL"
    for src in "$ROOT/Dependencies/libASPL/src/"*.cpp; do
        base="$(basename "$src" .cpp)"
        echo "  Compiling $base.cpp"
        clang++ -std=c++17 $OPT_FLAGS \
            -Wno-invalid-offsetof \
            -I "$ROOT/Dependencies/libASPL/include" \
            -isysroot "$SDK" \
            -target arm64-apple-macos14.4 \
            -c "$src" -o "$BUILD/libASPL/$base.o"
    done
    ar rcs "$LIBASPL_A" "$BUILD/libASPL/"*.o
    echo "  Created $(ls -lh "$LIBASPL_A" | awk '{print $5}') static library"
    echo ""
fi

# ──────────────────────────────────────────────────────────
# Step 2: Build CallRec.driver bundle
# ──────────────────────────────────────────────────────────
if [ "$APP_ONLY" = false ]; then
    echo "─── Building CallRec.driver ───"
    DRIVER_BUNDLE="$DIST/CallRec.driver"
    DRIVER_CONTENTS="$DRIVER_BUNDLE/Contents"
    DRIVER_MACOS="$DRIVER_CONTENTS/MacOS"

    rm -rf "$DRIVER_BUNDLE"
    mkdir -p "$DRIVER_MACOS"

    # Compile driver C++ sources
    DRIVER_SRCS=(PluginEntry SmartRouter SharedMemoryReader)
    DRIVER_OBJS=()
    for src in "${DRIVER_SRCS[@]}"; do
        echo "  Compiling $src.cpp"
        clang++ -std=c++17 $OPT_FLAGS \
            -I "$ROOT/Dependencies/libASPL/include" \
            -I "$ROOT/Common" \
            -I "$ROOT/CallRecDriver" \
            -isysroot "$SDK" \
            -target arm64-apple-macos14.4 \
            -c "$ROOT/CallRecDriver/$src.cpp" \
            -o "$BUILD/$src.o"
        DRIVER_OBJS+=("$BUILD/$src.o")
    done

    # Link driver dylib
    echo "  Linking CallRec driver bundle"
    clang++ -std=c++17 $OPT_FLAGS \
        -isysroot "$SDK" \
        -target arm64-apple-macos14.4 \
        -dynamiclib \
        -install_name "/Library/Audio/Plug-Ins/HAL/CallRec.driver/Contents/MacOS/CallRec" \
        -framework CoreAudio \
        -framework CoreFoundation \
        -framework AudioToolbox \
        "${DRIVER_OBJS[@]}" \
        "$LIBASPL_A" \
        -o "$DRIVER_MACOS/CallRec"

    # Copy Info.plist
    cp "$ROOT/CallRecDriver/Info.plist" "$DRIVER_CONTENTS/Info.plist"

    # Ad-hoc sign the driver bundle
    echo "  Signing driver bundle"
    codesign --force --sign - "$DRIVER_BUNDLE" 2>/dev/null

    echo "  Driver: $DRIVER_BUNDLE ($(du -sh "$DRIVER_BUNDLE" | awk '{print $1}'))"
    echo ""
fi

# ──────────────────────────────────────────────────────────
# Step 3: Build CallRec.app bundle
# ──────────────────────────────────────────────────────────
if [ "$DRIVER_ONLY" = false ]; then
    echo "─── Building CallRec.app ───"
    APP_BUNDLE="$DIST/CallRec.app"
    APP_CONTENTS="$APP_BUNDLE/Contents"
    APP_MACOS="$APP_CONTENTS/MacOS"
    APP_RESOURCES="$APP_CONTENTS/Resources"

    rm -rf "$APP_BUNDLE"
    mkdir -p "$APP_MACOS" "$APP_RESOURCES"

    # Compile C helper
    echo "  Compiling SharedMemoryHelpers.c"
    clang -c $OPT_FLAGS \
        -I "$ROOT/Common" \
        -isysroot "$SDK" \
        -target arm64-apple-macos14.4 \
        "$ROOT/Common/SharedMemoryHelpers.c" \
        -o "$BUILD/SharedMemoryHelpers.o"

    # Compile and link Swift app
    echo "  Compiling Swift sources..."
    SWIFT_SRCS=(
        "$ROOT/CallRecApp/App/CallRecApp.swift"
        "$ROOT/CallRecApp/App/AppDelegate.swift"
        "$ROOT/CallRecApp/Core/AudioTapManager.swift"
        "$ROOT/CallRecApp/Core/MicCaptureManager.swift"
        "$ROOT/CallRecApp/Core/BluetoothAudioHandler.swift"
        "$ROOT/CallRecApp/Core/AudioMixer.swift"
        "$ROOT/CallRecApp/Core/SharedMemoryBridge.swift"
        "$ROOT/CallRecApp/Core/CallDetector.swift"
        "$ROOT/CallRecApp/Core/SystemAudioDeviceManager.swift"
        "$ROOT/CallRecApp/Core/VoiceMemosController.swift"
        "$ROOT/CallRecApp/Core/Orchestrator.swift"
        "$ROOT/CallRecApp/UI/MenuBarView.swift"
        "$ROOT/CallRecApp/UI/SetupWizard/SetupWizardView.swift"
        "$ROOT/CallRecApp/UI/SettingsView.swift"
    )

    swiftc \
        -parse-as-library \
        -import-objc-header "$ROOT/CallRecApp/BridgingHeader.h" \
        -I "$ROOT/Common" \
        -sdk "$SDK" \
        -target arm64-apple-macos14.4 \
        -framework Cocoa \
        -framework CoreAudio \
        -framework AudioToolbox \
        -framework AVFoundation \
        -framework Accelerate \
        -framework ServiceManagement \
        "$BUILD/SharedMemoryHelpers.o" \
        "${SWIFT_SRCS[@]}" \
        -o "$APP_MACOS/CallRec"

    # Create Info.plist (resolve Xcode variables)
    cat > "$APP_CONTENTS/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>CallRec</string>
    <key>CFBundleExecutable</key>
    <string>CallRec</string>
    <key>CFBundleIdentifier</key>
    <string>com.callrec.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>CallRec</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.4</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSMicrophoneUsageDescription</key>
    <string>CallRec needs microphone access to capture your voice during call recordings.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>CallRec needs to capture audio from call apps (Zoom, Teams) to record both sides of the conversation.</string>
</dict>
</plist>
PLIST

    # Embed driver in app Resources
    if [ -d "$DIST/CallRec.driver" ]; then
        echo "  Embedding CallRec.driver in app bundle"
        cp -R "$DIST/CallRec.driver" "$APP_RESOURCES/CallRec.driver"
    fi

    # Sign the app bundle with a stable identifier so TCC permissions
    # (Accessibility, Microphone, etc.) survive rebuilds.
    # Ad-hoc signing (-s -) generates a new signature each build, which
    # invalidates macOS TCC grants. Using --identifier with a fixed bundle ID
    # and --preserve-metadata keeps the signature stable.
    echo "  Signing app bundle"
    if [ -d "$APP_RESOURCES/CallRec.driver" ]; then
        codesign --force --sign - --identifier "com.callrec.driver" "$APP_RESOURCES/CallRec.driver" 2>/dev/null
    fi
    codesign --force --sign - --identifier "com.callrec.app" "$APP_BUNDLE" 2>/dev/null

    echo "  App: $APP_BUNDLE ($(du -sh "$APP_BUNDLE" | awk '{print $1}'))"
    echo ""
fi

# ──────────────────────────────────────────────────────────
# Step 4: Run ring buffer tests
# ──────────────────────────────────────────────────────────
echo "─── Running Tests ───"
clang -I "$ROOT/Common" -isysroot "$SDK" \
    "$ROOT/Tests/test_ring_buffer.c" \
    -o "$BUILD/test_ring_buffer"
"$BUILD/test_ring_buffer"
echo ""

echo "=== Build Complete ==="
echo ""
echo "Outputs:"
[ "$DRIVER_ONLY" = false ] && echo "  App:    $DIST/CallRec.app"
[ "$APP_ONLY" = false ]    && echo "  Driver: $DIST/CallRec.driver"
echo ""
echo "To install the driver:"
echo "  sudo cp -R $DIST/CallRec.driver /Library/Audio/Plug-Ins/HAL/"
echo "  sudo launchctl kickstart -k system/com.apple.audio.coreaudiod"
echo ""
echo "NOTE: After rebuilding, macOS invalidates Accessibility permission"
echo "(the code signature changes). Toggle CallRec OFF then ON in:"
echo "  System Settings > Privacy & Security > Accessibility"
