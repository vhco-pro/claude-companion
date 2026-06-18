#!/usr/bin/env zsh
# run.sh - regenerate the Xcode project, build, and launch Claude Companion.
#
#   ./scripts/run.sh           # incremental build, then launch
#   ./scripts/run.sh --clean   # wipe build products first (full rebuild)
#   ./scripts/run.sh --test    # run the unit tests instead of launching
#
# Menu-bar only (LSUIElement) - look for the diamond icon in the top-right menu bar; no Dock icon.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

PROJECT="ClaudeCompanion.xcodeproj"
SCHEME="ClaudeCompanion"
DERIVED=".build/DerivedData"
APP="$DERIVED/Build/Products/Debug/ClaudeCompanion.app"
DESTINATION='platform=macOS,arch=arm64'

mode="run"; clean=0
for arg in "$@"; do
  case "$arg" in
    --clean) clean=1 ;;
    --test)  mode="test" ;;
    --run)   mode="run" ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

pkill -f "ClaudeCompanion.app/Contents/MacOS/ClaudeCompanion" 2>/dev/null || true

if (( clean )); then
  echo "==> Cleaning build products"
  rm -rf "$DERIVED/Build/Products" "$DERIVED/Build/Intermediates.noindex"
fi

if [[ "$mode" == "test" ]]; then
  echo "==> Running tests (swift test in CompanionKit)"
  exec swift test --package-path CompanionKit
fi

echo "==> Generating Xcode project from project.yml"
xcodegen generate

echo "==> Building (first build compiles GRDB - be patient)"
xcodebuild build \
  -project "$PROJECT" -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation \
  -quiet

echo "==> Launching $APP"
open "$APP"
echo "==> Launched. Look for the diamond icon in the menu bar (top-right)."
