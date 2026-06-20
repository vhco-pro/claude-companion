# Plan 9 - Swift 6 Language Mode

> Implements [swift6-language-mode.spec.md](../specs/features/swift6-language-mode.spec.md).
> Small, measured (2 library diagnostics + an app-target flag). Build order: maintenance.

## Phases

### Phase 1 - Library
1. `JSONLTailer.swift`: change the two `static let` formatters to `nonisolated(unsafe) static let`,
   with a one-line comment noting they are configured once and used read-only.
2. `CompanionKit/Package.swift`: `swiftLanguageModes: [.v5]` -> `[.v6]`.
3. `swift build` + `swift test` -> no concurrency errors, 54 tests pass.
4. Cross-compile guard: `swiftly run swift build --product companion-hook --swift-sdk
   x86_64-swift-linux-musl -c release` -> static ELF (Swift 6 mode does not break the hook).

### Phase 2 - App target
1. `project.yml`: app target `SWIFT_VERSION: "5"` -> `"6"`.
2. `xcodegen generate` (or rely on the build's xcodegen step).
3. `xcodebuild build -scheme ClaudeCompanion` -> fix whatever strict concurrency surfaces
   (expected: few, in the SwiftUI shell / PanelView). Prefer minimal, justified annotations over
   restructuring.
4. Launch the app, open the popover -> smoke test (sessions/usage render).

### Phase 3 - Land it
1. Commit signed: `build: adopt Swift 6 language mode`.
2. Push; CI green; commit Verified.

## Acceptance (from spec)
- [ ] Package on `.v6`; `swift test` 54 pass; hook cross-compiles under Swift 6.
- [ ] App target `SWIFT_VERSION: "6"`; `xcodebuild` succeeds; app runs.
- [ ] Only the two formatters use `nonisolated(unsafe)`, each justified.
- [ ] CI green; commit Verified.

## Notes
- If the app target throws up something gnarly, partial adoption (package `.v6`, app on `5`) is an
  acceptable fallback per the spec - record it rather than forcing a risky change.
