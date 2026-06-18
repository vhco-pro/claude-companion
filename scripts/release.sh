#!/usr/bin/env zsh
# release.sh - build a signed Release ClaudeCompanion.app and package it as a dist zip.
# (Local parity with CI; the CI release goes through vhco-pro/swift-release-action.)
#
#   ./scripts/release.sh   # clean Release build → dist/ClaudeCompanion-<version>.zip + .sha256
#
# Ad-hoc signed, NOT notarized (until a Developer ID cert is available). The companion-hook
# helper is embedded + re-sealed by the project's "Embed & re-sign" build phase.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

PROJECT="ClaudeCompanion.xcodeproj"
SCHEME="ClaudeCompanion"
DERIVED=".build/DerivedData"
RELEASE_APP="$DERIVED/Build/Products/Release/ClaudeCompanion.app"
DIST="dist"

VERSION=$(plutil -extract CFBundleShortVersionString raw -o - ClaudeCompanion/Info.plist)
ZIP="$DIST/ClaudeCompanion-${VERSION}.zip"

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Clean Release build (signed + re-sealed by the Embed & re-sign phase)"
xcodebuild build \
  -project "$PROJECT" -scheme "$SCHEME" \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  -quiet

echo "==> Verifying signature"
codesign --verify --deep --strict "$RELEASE_APP"

echo "==> Packaging $ZIP (ditto preserves the bundle + signature)"
mkdir -p "$DIST"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --sequesterRsrc --keepParent "$RELEASE_APP" "$ZIP"

SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "$SHA  $(basename "$ZIP")" > "$ZIP.sha256"

echo ""
echo "==> Done.  version: $VERSION  zip: $ZIP  sha256: $SHA"
