#!/usr/bin/env zsh
# build-hook.sh - compile the companion-hook executable from the CompanionKit package.
# Invoked as the Xcode preBuildScript; output is copied into the .app by the postBuildScript.
set -euo pipefail
ROOT="${0:A:h:h}"
swift build -c release --product companion-hook --package-path "$ROOT/CompanionKit"
echo "==> built companion-hook → $ROOT/CompanionKit/.build/release/companion-hook"
