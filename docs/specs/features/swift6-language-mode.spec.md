# Feature Spec - Swift 6 Language Mode (strict concurrency)

> Part of [Claude Companion](../claude-companion-spec.md). Maintenance. Follows
> [dependency-modernization](dependency-modernization.spec.md). Status: **shipped v0.1.**

## Purpose

Finish the toolchain modernization by moving our own code from Swift 5 to **Swift 6 language
mode** (complete strict-concurrency checking), so data-race safety is enforced by the compiler.

## Background

[dependency-modernization](dependency-modernization.spec.md) raised `swift-tools-version` to 6.0
(to consume GRDB 7) but deliberately pinned every target to `swiftLanguageModes: [.v5]` to keep
that change a dependency bump, not a concurrency migration. The dependencies (GRDB 7, Yams 6)
already build in Swift 6. This spec flips our code to Swift 6 too.

## Measured scope (not a guess)

A build under `-strict-concurrency=complete` was run to size the work:

- **Library (`CompanionKit` package):** exactly **2** diagnostics, both in
  [`JSONLTailer.swift`](../../CompanionKit/Sources/CompanionKit/JSONLTailer.swift) - the `static`
  `ISO8601DateFormatter`s `isoFractional` and `isoPlain`, flagged as non-`Sendable` global mutable
  state. They are configured once and used **read-only** (`date(from:)`), which Foundation date
  formatters support concurrently. No actor-isolation, main-actor, or data-race diagnostics.
- **`CompanionCore` + `companion-hook`:** clean (no diagnostics).
- **App target (`ClaudeCompanion`):** `project.yml` currently sets `SWIFT_VERSION: "5"`. Moving it
  to `"6"` turns on strict concurrency for the SwiftUI `@main` shell + `PanelView`. `@Observable
  AppModel` already runs on the main actor via SwiftUI; expected stragglers are few, surfaced by
  the build (the implementation phase fixes whatever appears).

## Scope

In:
- `JSONLTailer.swift`: annotate the two formatters `nonisolated(unsafe) static let` (zero-cost
  assertion that read-only use is safe; keeps the create-once perf, avoids per-call allocation).
- `CompanionKit/Package.swift`: `swiftLanguageModes: [.v5]` -> `[.v6]`.
- `project.yml`: app target `SWIFT_VERSION: "5"` -> `"6"`; regenerate the Xcode project.
- Any app-target concurrency fixes the build surfaces.

Out:
- Re-architecting concurrency (introducing actors, restructuring the ingest/poll pipeline). This is
  about passing strict-concurrency checks with minimal, safe annotations - not a redesign.

## Acceptance criteria

- [ ] `CompanionKit/Package.swift` is `swiftLanguageModes: [.v6]`; `swift build` + `swift test`
      pass (54 tests) with no concurrency errors.
- [ ] `companion-hook` still cross-compiles to the static Linux SDK under Swift 6.
- [ ] App target `SWIFT_VERSION: "6"`; `xcodebuild` succeeds and the menu-bar app runs.
- [ ] No `nonisolated(unsafe)` is used except where the value is provably read-only/safe (only the
      two formatters); each such use is justified by a comment.
- [ ] CI green.

## Test plan

| Check | How | Expectation |
|---|---|---|
| Library strict-concurrency | `swift build` (mode .v6) | no errors |
| Unit suite | `swift test --package-path CompanionKit` | 54 pass |
| Linux hook | `swiftly run swift build --product companion-hook --swift-sdk x86_64-swift-linux-musl` | static ELF |
| App | `xcodebuild build -scheme ClaudeCompanion` | BUILD SUCCEEDED |
| Runtime smoke | launch the app, open popover | sessions/usage render, no crash |

## Risks + rollback

- The formatter fix is the only library change and is a one-line annotation each; safe because
  `ISO8601DateFormatter.date(from:)` is concurrency-safe for read-only use.
- App-target stragglers are the unknown; if a SwiftUI/AppKit interop issue is non-trivial, fix it
  narrowly or, worst case, keep the package on `.v6` and leave the app target on Swift 5 (partial
  adoption is valid). Rollback is reverting the two flags (`swiftLanguageModes`, `SWIFT_VERSION`).
