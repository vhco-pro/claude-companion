# Plan - Foundation

> Implements [foundation.spec.md](../specs/features/foundation.spec.md). Build order **1**.
> No prerequisites. Everything else depends on the contracts this plan ships.
> **Revised 2026-06-15 - daemon dropped (lean: app + hook + files).**

## Outcome

A `ClaudeCompanion.app` menu-bar shell (always-on login item) plus a standalone
`companion-hook` binary, sharing state through files in `~/.config/claude-companion/`, with a
migrated SQLite DB (app-owned) and hot-reloaded config - no product features yet, **no daemon,
no socket**.

## Phases

### P0 - Workspace bootstrap (mirror ssm-connect's Go-like packaging)
- Create local package `CompanionKit/Package.swift` with **two products**:
  - `.library(CompanionKit)` - shared code (config, models, DB, rule engine, parsing, UI views).
  - `.executable(companion-hook)` - hook client @main, kept **GRDB-free / dependency-light**
    (spawned per tool call; cold-start latency matters).
  - dependency: **GRDB.swift** (used by the app/library, not the hook); commit `Package.resolved`.
- `project.yml` (XcodeGen) for the thin `ClaudeCompanion` app target (`LSUIElement`, Info.plist,
  entitlements) depending on the `CompanionKit` library product.
- `Makefile` + `scripts/run.sh`; `.github/dependabot.yml` (swift @ `/CompanionKit` + actions);
  `.github/workflows/ci.yml` (PR `swift test` gate).
- **Decide app-sandbox posture here** - non-sandboxed (must read the Claude Keychain item +
  write `~/.claude/settings.json` + `~/.config`), like ssm-connect.
- *Test:* `swift build -c release --product companion-hook` produces the binary; `make run`
  launches the menu-bar app; `make test` runs the suite.

### P1 - SQLite store (`CompanionKit`, app-owned)
- GRDB `DatabaseQueue` on `~/.config/claude-companion/companion.db`; WAL mode.
- Forward-only migration → **schema v1** (sessions, tool_events, token_usage, audit, pricing,
  schema_meta). Thin DAO/repository types.
- *Test:* migration to v1 on a fresh dir; idempotent re-run; round-trip insert/read.

### P2 - Shared-state plumbing (replaces IPC)
- Config layout + typed loader for `config.yaml`/`rules.yaml`; `FSEventStream` hot-reload
  (500ms debounce, reject-malformed-keep-last-good, surface error in UI).
- `audit.ndjson` contract: an append helper (atomic `O_APPEND` line write) used by the hook,
  and a tailer in the app that ingests new lines into the `audit` table.
- *Test:* editing `config.yaml` reloads; bad YAML keeps last-good; an appended `audit.ndjson`
  line gets ingested into SQLite exactly once (offset persisted).

### P3 - `companion-hook` skeleton (`companion-hook` exec)
- Reads the PreToolUse payload on stdin, loads `rules.yaml` (stub eval for now - real engine in
  plan 2), prints a `permissionDecision` JSON, appends one `audit.ndjson` line, exits.
- Fail-safe: unreadable rules / malformed payload → print `ask`. Never blocks.
- *Test:* piping a sample payload yields valid decision JSON + one audit line; runs with the
  app **not** running; cold-start time measured.

### P4 - Menu-bar app skeleton (`ClaudeCompanion`)
- `NSStatusItem`/`MenuBarExtra` with a placeholder title, rendered from in-process state.
- Register as a **login item** via `SMAppService`. Wire the hot-reload watcher + `audit.ndjson`
  tailer from P2.
- *Test:* app launches as a menu-bar item, registers the login item, shows placeholder fed by
  in-process state; quitting the app does not affect a `companion-hook` run.

### P5 - Packaging, signing & release (mirror ssm-connect)
- `project.yml` pre/post build phases: `swift build -c release --product companion-hook` → copy
  into `ClaudeCompanion.app/Contents/Helpers/` → `chmod +x` → (Release only) ad-hoc re-sign the
  helper then `--deep` re-sign the app, then `codesign --verify --deep --strict`.
- `scripts/release.sh`: clean Release build → `ditto -c -k --keepParent` →
  `dist/ClaudeCompanion-<ver>.zip` + `.sha256`.
- `.github/workflows/release.yml`: GitVersion → gate on bump → xcodegen → newest Xcode →
  SwiftPM cache → stamp `Info.plist` → `release.sh` → GitHub Release. *(Later: replace with
  `uses: <owner>/swift-release-action@v1` once that repo is green.)*
- Install: write hook entries into `settings.json` with the embedded `companion-hook` absolute
  path; **self-heal that path on each launch** if the bundle moved. Register login item.
- Uninstall: deregister login item, remove our hook entries, keep user data unless `--purge`.
- *Test:* `./scripts/release.sh` yields a verifiable signed zip with `companion-hook` embedded;
  fresh-install registers the login item + hook entries; uninstall is clean.

## Acceptance criteria (from spec)
- [ ] App launches as a menu-bar/login item; opens `companion.db` at schema v1.
- [ ] `companion-hook` runs standalone (no app) and appends `audit.ndjson`; quitting the app
      doesn't break it.
- [ ] App tails `audit.ndjson` → SQLite for the activity view.
- [ ] `config.yaml`/`rules.yaml` hot-reload; malformed keeps last-good.
- [ ] `make run` builds + launches; `swift test` runs; `release.sh` yields a signed embedded zip.

## Risks / decisions to confirm
- Sandbox posture (P0) - non-sandboxed assumed; confirm Keychain + settings.json access.
- Hook reading `blocklist.db` cheaply without linking SQLite (flat sorted file + binary search
  vs read-only SQLite) - decide when plan 2 adds the blocklist.
- Login-item + embedded-hook path stability across cask updates → self-heal on launch.
