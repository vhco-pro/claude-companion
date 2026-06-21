# Feature Spec - Foundation (process model, storage, packaging)

> Part of [Claude Companion](../claude-companion-spec.md). Build order **1** (M0).
> Status: **shipped v0.1 (revised 2026-06-15 - daemon dropped, lean design).** Owns the shared
> contracts every other feature spec references.

## Purpose

Stand up the lean skeleton everything else plugs into: **one always-on menu-bar app**, **one
tiny `companion-hook` binary**, **file-based shared state** (no daemon, no socket, no IPC),
the SQLite store, the on-disk config layout, and the packaging/launch story.

## Why no daemon (design correction)

The original draft had a separate `companiond` + Unix-socket IPC so a hook could ask a live
server for a decision. Two later findings made that dead weight, and it's now removed:
- The hook **must never block** (a block-timeout *runs* the tool) - so there's nothing to keep
  a socket alive *for*; the decision must be computed locally and returned instantly.
- A **menu-bar app is always running** - "closed" means the popover is shut, not that the
  process exited - so there's no window where a separate daemon is needed.

Result: the permission gate is a **standalone hook that reads `rules.yaml` from disk** and
decides. The menu-bar app does all long-lived work (usage polling, JSONL tailing, blocklist
refresh, UI) **in-process**. They share **files**, not a socket. Bonus: the safety gate keeps
working even if you quit the app - the hook is independent of the UI.

## Scope

In:
- **`ClaudeCompanion.app`** - SwiftUI `MenuBarExtra`, always-on **login item** (`SMAppService`).
  Owns SQLite, usage poller, JSONL tailer, blocklist refresher, all UI. Writes config/rules.
- **`companion-hook`** - tiny executable invoked by Claude Code's `PreToolUse`/etc. hooks.
  Reads `rules.yaml` + cached blocklist, decides, prints, appends one audit line. No DB, no socket.
- SQLite store + schema + migrations (owned by the app).
- Config-file layout + typed loader with hot-reload.
- Packaging: a single signed `.app` bundle with `companion-hook` embedded; login-item registration.

Out (other specs): JSONL parsing, usage polling, the rule engine + blocklist, UI panels.

## Decisions

- **All Swift, "Go-like self-contained" packaging - mirrors [`vhco-pro/ssm-connect`](https://github.com/vhco-pro/ssm-connect)
  PR #5.** One **local Swift package `CompanionKit`** is the single source of truth for code +
  deps (the `go.mod`/`go.sum` analogue):
  - `.library(CompanionKit)` - all shared code (rule engine, models, DB, parsing, UI views).
  - `.executable(companion-hook)` - the hook client (self-contained binary). **Kept GRDB-free
    and minimal** - it's spawned on every tool call, so cold-start latency matters.
  - `Package.swift` declares the lone dep **GRDB.swift** (used by the app, not the hook);
    **`Package.resolved` committed** (the lockfile Dependabot reads).
- **Thin Xcode `@main` launcher `ClaudeCompanion`** - produces the signed menu-bar `.app`
  (`LSUIElement`, Info.plist, entitlements, embed/re-sign phases), depends on `CompanionKit`.
  **XcodeGen `project.yml`** generates the `.xcodeproj`.
- **Login item, not a LaunchAgent.** The app registers itself via `SMAppService` (same pattern
  as ssm-connect's `LoginItemService`) so it relaunches at login. No background daemon plist.
- **SQLite** via GRDB.swift, **owned exclusively by the app** (single writer). The hook never
  touches the DB - it appends NDJSON that the app ingests (see contracts).

## Contracts (referenced by all other specs)

### File layout - `~/.config/claude-companion/`
```
config.yaml          # user settings (UI prefs, poll interval, notify-on-deny)
rules.yaml           # permission blacklist + blocklist policy (permission-engine spec)
blocklist.db         # cached threat-feed domains (permission-engine spec; app refreshes)
audit.ndjson         # append-only decision log: hook appends, app ingests → SQLite
companion.db         # SQLite - sessions, tokens, cost, audit (app-owned)
companion.log        # app log
```
Per-project override `.claude-companion.yaml` may sit in a repo root (tighten-only).

### Shared-state model (replaces IPC)
- **App → hook:** the app writes `rules.yaml` + `blocklist.db`; the hook reads them on each
  invocation (cheap; both are small / memory-mapped). No notification needed - the hook always
  reads fresh.
- **Hook → app:** the hook appends one JSON line per decision to `audit.ndjson` (`O_APPEND` is
  atomic for small writes). The app tails `audit.ndjson` (FSEvents) and ingests rows into
  SQLite for the activity view. If the app is down, audit lines simply queue on disk until it
  ingests them later - the gate is unaffected.
- **In-process:** session monitor, usage poller, cost, and UI all run inside the app and share
  state directly (plain Swift observation) - no socket, no message protocol.

### SQLite schema (v1 - other specs extend via migrations)
```sql
sessions(    id TEXT PRIMARY KEY, project_path TEXT, model TEXT,
             started_at, last_seen_at, status TEXT );        -- session-monitor
tool_events( id INTEGER PK, session_id TEXT, ts, tool TEXT,
             bash_command TEXT, target_path TEXT );          -- session-monitor
token_usage( session_id TEXT, ts, input INT, output INT,
             cache_read INT, cache_write INT );              -- session-monitor
audit(       id INTEGER PK, ts, session_id, prompt_id,
             tool TEXT, command TEXT, decision TEXT,
             rule_matched TEXT );                            -- ingested from audit.ndjson
pricing(     model TEXT PRIMARY KEY, input_per_mtok REAL,
             output_per_mtok REAL, cache_read_per_mtok REAL,
             cache_write_per_mtok REAL );                    -- cost-breakdown
schema_meta( version INTEGER );                              -- migrations
```
Migrations forward-only, applied on app start; bump `schema_meta.version`.

### config.yaml (foundation-owned keys; features add their own)
```yaml
ui:
  status_format: "◆ {weekly}% · 5h {fivehour}%"
log_level: info
# permission-engine, usage-limits, approval-ux append their keys here
```
Config + rules are **hot-reloaded** by the app via `FSEventStream`, debounced ~500ms;
malformed files are rejected with last-good kept and an error surfaced in the UI.

## Packaging - self-contained, mirrors ssm-connect

### Repo layout
```
CompanionKit/
  Package.swift            # dep: GRDB; 2 products: .library + .executable(companion-hook)
  Package.resolved         # committed lockfile (Dependabot reads this)
  Sources/CompanionKit/    # shared library code (app + hook share what they can)
  Sources/companion-hook/  # hook client @main (minimal deps)
  Tests/CompanionKitTests/ # swift test
ClaudeCompanion/           # thin Xcode app shell
  App/ClaudeCompanionApp.swift   # @main MenuBarExtra launcher, depends on CompanionKit
  Info.plist               # LSUIElement = true (menu-bar only, no Dock icon)
  ClaudeCompanion.entitlements
project.yml                # XcodeGen
Makefile                   # wraps scripts/run.sh (run/rebuild/test/generate/clean)
scripts/run.sh             # xcodegen generate → xcodebuild → open;  --test → swift test
scripts/release.sh         # clean Release build → dist/ClaudeCompanion-<ver>.zip + .sha256
.github/dependabot.yml     # swift @ /CompanionKit + github-actions
.github/workflows/release.yml  # GitVersion → build signed .app → GitHub Release
.github/workflows/ci.yml   # PR gate: swift test
dist/
```

### Build & embed flow (XcodeGen `project.yml` build phases)
- **preBuildScript** - `swift build -c release --product companion-hook` from `CompanionKit`.
- **postBuildScript** - copy `companion-hook` into `ClaudeCompanion.app/Contents/Helpers/`,
  `chmod +x`. On **Release** only, re-sign (embedding after Xcode signs invalidates the seal):
  `codesign --force --sign "$IDENTITY"` the helper, then `--force --deep` the app, then
  `codesign --verify --deep --strict`. **Ad-hoc identity (`-`)** for now; Developer-ID +
  notarization is a drop-in later (just swap identity + add notarytool/staple).

### Install / lifecycle
- Ship one `ClaudeCompanion.app` with `Contents/Helpers/companion-hook` embedded.
- On first launch: write the default config dir; register hook entries in
  `~/.claude/settings.json` (merge-tagged) using the **absolute embedded hook path**
  `…/ClaudeCompanion.app/Contents/Helpers/companion-hook`; register the app as a login item
  (`SMAppService`).
- **Path stability:** shipped via Homebrew cask into a stable `/Applications/ClaudeCompanion.app`
  the embedded-path approach is fine; the app re-checks and **self-heals** the hook path in
  `settings.json` on each launch (rewrites it if the bundle moved). No daemon to keep alive.
- Clean uninstall: deregister login item, remove our hook entries, leave user data unless `--purge`.

### Release / CI (mirrors ssm-connect; will consume the reusable `swift-release` workflow)
- `release.yml`: GitVersion (conventional commits) → gate on bump → tag → xcodegen → newest
  Xcode → SwiftPM cache → stamp Info.plist → `release.sh` → publish GitHub Release.
- `ci.yml`: on PRs, `swift test --package-path CompanionKit` (the test gate, devops #3).
- Once green, the release job will be replaced by `uses: <owner>/swift-release-action@v1`
  (built in parallel).

## Acceptance criteria
- [ ] App launches as a menu-bar item, registers as a login item, opens `companion.db` at schema v1.
- [ ] `companion-hook` runs standalone (no app required): reads `rules.yaml`, returns a decision,
      appends an `audit.ndjson` line. **Quitting the app does not break the gate.**
- [ ] App tails `audit.ndjson` and ingests rows into SQLite for the activity view.
- [ ] Editing `config.yaml`/`rules.yaml` hot-reloads; malformed keeps last-good.
- [ ] `make run` builds + launches; `swift test --package-path CompanionKit` runs the suite.
- [ ] `./scripts/release.sh` produces a verifiable signed `dist/` zip with `companion-hook`
      embedded in `Contents/Helpers/`.
- [ ] `companion-hook` cold-start is fast (no GRDB/heavy deps linked) - measure p95.

## Defaults locked (2026-06-15)
- **App-sandbox: OFF (non-sandboxed).** Required to read the Claude Keychain item, write
  `~/.claude/settings.json`, and use `~/.config` - matches ssm-connect. (Revisit only if we
  ever ship via the Mac App Store, which we won't for v0.1.)
- **`blocklist.db` format: a flat, sorted, memory-mapped binary file** - fixed-width records
  of `<registrable-domain-hash><class-byte>` (or sorted text `domain\tclass`), binary-searched
  by the hook. **No SQLite linked into `companion-hook`** (keeps cold-start fast). The app
  writes it atomically (temp + rename) on each feed refresh.
- **`audit.ndjson` rotation:** the app compacts/rotates after ingesting into SQLite; cap the
  on-disk tail at ~10 MB, archive older to the DB only.

## Open questions
- None blocking. (Login-item path stability across cask updates handled by the launch-time
  self-heal of the hook path in `settings.json`.)
