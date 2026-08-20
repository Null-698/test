#!/usr/bin/env bash
set -euo pipefail

echo "Swift:"
swift --version
echo

echo "Installed Swift SDK IDs:"
swift sdk list || true
echo

echo "Darwin iPhoneOS SDK directories:"
find "$HOME/.swiftpm/swift-sdks" \
  -type d -name 'iPhoneOS*.sdk' 2>/dev/null | sort || true
echo

echo "This project intentionally targets iOS 26 and uses iOS 26-only SwiftUI APIs."
echo "If the build says '.glass', '.tabBarMinimizeBehavior', or iOS 26 is unavailable,"
echo "regenerate xtool's Darwin SDK from an Xcode 26.x .xip."
