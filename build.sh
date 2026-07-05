#!/bin/bash
set -e

APP_NAME="ParaEQ"
BUNDLE=".build/${APP_NAME}.app"

echo "Building ${APP_NAME}..."
swift build -c release 2>&1

echo "Creating app bundle..."
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"

cp ".build/release/${APP_NAME}" "$BUNDLE/Contents/MacOS/"
cp Info.plist "$BUNDLE/Contents/"

# Prefer the stable local identity (keeps the system-audio TCC grant across
# rebuilds — ad-hoc signing changes the binary hash and re-prompts every time)
if security find-identity -v -p codesigning | grep -q "ParaEQ Dev Signing"; then
    codesign --force --deep --sign "ParaEQ Dev Signing" "$BUNDLE"
else
    codesign --force --deep --sign - "$BUNDLE"
fi

echo ""
echo "Built: $BUNDLE"
echo "Run:   open $BUNDLE"
