# Claude Companion

A macOS menu-bar companion for Claude Code: it monitors running sessions, surfaces usage
limits + cost, and - the headline - **auto-approves tool calls except a shared blacklist**,
killing the endless "type 1 to continue" loop. Anything not on the blacklist runs without a
prompt; catastrophic commands are hard-blocked, risky ones defer to Claude Code's native prompt.

> Status: **v0.1.0 released.** Specs + plans live in [`docs/`](docs/).

## Install

```sh
brew install --cask vhco-pro/tap/claude-companion
```

The app is ad-hoc signed (not notarized), so approve it once on first launch:
`xattr -dr com.apple.quarantine "/Applications/ClaudeCompanion.app"` (or right-click in Finder
and choose Open). Then click **Install hook into Claude Code** in the popover and reload your
editor window to activate the auto-approve gate.

## Architecture (lean, daemon-free)

```
ClaudeCompanion.app   (always-on menu-bar login item)
  • SQLite store, usage poller, JSONL session tailer, cost, UI
  • writes rules.yaml / config; compiles rules + threat-feed blocklist for the hook
  • tails audit.ndjson → SQLite for the activity view

companion-hook        (tiny binary Claude Code runs per tool call)
  • reads compiled rules + blocklist → decides allow/deny/ask → appends audit.ndjson
  • standalone: no daemon, no socket, no network. The gate works even if the app is quit.

shared files in ~/.config/claude-companion/   (rules, blocklist, config, audit.ndjson, companion.db)
```

The headline auto-approve uses Claude Code's `PreToolUse` hook (confirmed working in both the
CLI and the VSCode extension on 2.1.177). See [`docs/specs/`](docs/specs/).

## Layout

```
CompanionKit/            local Swift package - single source of truth (go.mod-style)
  Sources/CompanionCore/   pure, dependency-free: hook contract, RuleEngine, audit
  Sources/CompanionKit/    app library: SQLite (GRDB), usage, sessions, cost, view models
  Sources/companion-hook/  the per-tool-call executable (depends on CompanionCore only)
  Tests/CompanionKitTests/
ClaudeCompanion/         thin Xcode @main shell (menu-bar .app bundling/signing)
project.yml              XcodeGen project definition
scripts/                 run.sh · release.sh · build-hook.sh
.github/workflows/       ci.yml (PR tests) · release.yml (→ vhco-pro/swift-release-action)
```

## Develop

```sh
make run      # xcodegen generate → build → launch (menu-bar icon, top-right)
make test     # swift test (CompanionKit)
make rebuild  # clean + rebuild + launch
```

Requires Xcode 16+ (Swift 6 language mode) and `xcodegen` (`brew install xcodegen`).

## License

Apache-2.0.
