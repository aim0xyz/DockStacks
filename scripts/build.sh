#!/bin/zsh
# Builds DockStacks.app into ./build. With --install it also replaces /Applications/DockStacks.app and starts it.
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="$ROOT/build"
APP="$BUILD/DockStacks.app"
VERSION="1.0"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
INSTALL=false
[[ "${1:-}" == "--install" ]] && INSTALL=true

# Prefer a stable signing identity so the Accessibility permission survives rebuilds.
IDENTITY="${DOCKSTACKS_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')}"
[[ -z "$IDENTITY" ]] && IDENTITY="-"

cd "$ROOT"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DockStacks" "$APP/Contents/MacOS/DockStacks"

# --- Stack app template (copied once per stack at runtime) ---
STUB="$APP/Contents/Resources/StackStub.app"
mkdir -p "$STUB/Contents/MacOS"
cp "$BIN/StackStub" "$STUB/Contents/MacOS/StackStub"
TEMPLATE_VERSION="$(shasum -a 256 "$BIN/StackStub" | cut -c1-16)"
cat > "$STUB/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>de</string>
    <key>CFBundleExecutable</key><string>StackStub</string>
    <key>CFBundleIdentifier</key><string>local.dockstacks.stack.template</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Stapel</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>DSTemplateVersion</key><string>$TEMPLATE_VERSION</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>App</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>com.apple.application-bundle</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST
codesign --force --sign - --timestamp=none "$STUB"

# --- App icon ---
ICONSET="$BUILD/AppIcon.iconset"
rm -rf "$ICONSET"
"$APP/Contents/MacOS/DockStacks" --export-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>de</string>
    <key>CFBundleDisplayName</key><string>DockStacks</string>
    <key>CFBundleExecutable</key><string>DockStacks</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>local.dockstacks.app</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>DockStacks</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Stapel für das macOS-Dock</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>DockStacks</string>
            <key>CFBundleURLSchemes</key><array><string>dockstacks</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP (signed with ${IDENTITY:0:10}…, stub template $TEMPLATE_VERSION)"

if $INSTALL; then
    osascript -e 'tell application id "local.dockstacks.app" to quit' >/dev/null 2>&1 || true
    pkill -x DockStacks >/dev/null 2>&1 || true
    sleep 0.5
    rm -rf /Applications/DockStacks.app
    cp -R "$APP" /Applications/DockStacks.app
    open /Applications/DockStacks.app
    echo "Installed to /Applications/DockStacks.app"
fi
