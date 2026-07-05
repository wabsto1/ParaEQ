#!/bin/bash
set -e

APP_NAME="TapProto"
BUNDLE=".build/${APP_NAME}.app"

echo "Building ${APP_NAME}..."
swift build -c release --product TapProto 2>&1

echo "Creating app bundle..."
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"

cp ".build/release/${APP_NAME}" "$BUNDLE/Contents/MacOS/"
cp Prototypes/TapProto/Info.plist "$BUNDLE/Contents/"

# Ad-hoc signing with a stable identifier; if the system-audio TCC prompt
# never fires, a real signing identity is required instead.
codesign --force --identifier com.paraeq.tapproto --sign - "$BUNDLE"

echo ""
echo "Built: $BUNDLE"
echo "Run:   open $BUNDLE  (log: ~/Library/Logs/TapProto.log)"
