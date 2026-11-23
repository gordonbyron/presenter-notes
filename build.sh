#!/bin/bash
# Builds "Presenter Notes.app" into ./build. Needs the Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Presenter Notes.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 Sources/main.swift -o "$APP/Contents/MacOS/PresenterNotes"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Presenter Notes</string>
    <key>CFBundleDisplayName</key><string>Presenter Notes</string>
    <key>CFBundleIdentifier</key><string>com.gbyron.presenter-notes</string>
    <key>CFBundleExecutable</key><string>PresenterNotes</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>Presenter Notes asks your browser which Google Slides slide is showing, so it can display the note for that slide.</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Sign with a real identity when there is one, so macOS keeps the app's permissions
# (Screen Recording, Automation, Accessibility) from one build to the next.
IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
if [ -n "$IDENTITY" ] && codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1; then
    echo "Signed as $IDENTITY"
else
    codesign --force --sign - "$APP" >/dev/null 2>&1
    echo "Signed ad hoc. macOS will ask for permissions again after each build."
fi
echo "Built $APP"
