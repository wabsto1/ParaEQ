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

# Ad-hoc sign so macOS allows audio input
codesign --force --deep --sign - "$BUNDLE"

echo ""
echo "Built: $BUNDLE"
echo "Run:   open $BUNDLE"
