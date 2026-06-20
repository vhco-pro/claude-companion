# Plan 8 - Dependency Modernization (GRDB 7, Yams 6, CI on Xcode 26)

> Implements [dependency-modernization.spec.md](../specs/features/dependency-modernization.spec.md).
> Small, mechanical, well-bounded. Build order: maintenance (any time).

## Phases

### Phase 1 - Manifest bump (CompanionKit/Package.swift)
1. Raise the manifest: `// swift-tools-version: 6.0`.
2. Pin language mode so the tools bump does NOT flip our code to Swift 6 strict concurrency: add
   `swiftSettings: [.swiftLanguageMode(.v5)]` to every target (CompanionCore, CompanionKit,
   companion-hook, the test target).
3. Bump dependencies:
   - GRDB.swift `from: "6.29.3"` -> `from: "7.0.0"`.
   - Yams `from: "5.1.0"` -> `from: "6.0.0"`.
4. Resolve: `swift package resolve` (updates Package.resolved to GRDB 7.x + Yams 6.x).

### Phase 2 - CI runner (.github/workflows/ci.yml)
1. `runs-on: macos-14` -> `runs-on: macos-26` (match release.yml; gives Xcode 26 / Swift 6.x so
   SwiftPM can resolve GRDB 7's `swift-tools-version: 6.0`).
2. Keep the "Select the newest installed Xcode" step (harmless, future-proof).

### Phase 3 - Build + verify locally
1. `swift test --package-path CompanionKit` -> 54 pass.
2. `xcodebuild build ... -scheme ClaudeCompanion` -> BUILD SUCCEEDED.
3. Cross-compile guard: `swiftly run swift build --product companion-hook --swift-sdk
   x86_64-swift-linux-musl -c release` (uses the 6.2.3 toolchain/SDK from the remote-ssh spike) ->
   static ELF still builds (the hook only depends on CompanionCore; this proves the manifest bump
   did not break it).
4. Fix only what the build surfaces. Expectation per the spec analysis: no code changes needed.

### Phase 4 - Land it (SDD review gate)
1. Commit signed (now that pinentry-mac is wired): `build: upgrade GRDB 7 + Yams 6, CI on macos-26`.
2. Push; confirm the CI workflow goes green on macos-26.
3. Confirm the Release workflow still succeeds/skips as expected (no behavior change).
4. Confirm the commit shows "Verified" on GitHub.

## Acceptance criteria (from the spec)

- [ ] Package.swift: tools 6.0, GRDB 7.x, Yams 6.x, all targets pinned to Swift 5 language mode.
- [ ] `swift test` 54 pass; `xcodebuild` succeeds; Linux hook still cross-compiles.
- [ ] ci.yml on macos-26; CI green.
- [ ] Dependabot's failing grouped bump is satisfied (no longer reopened).
- [ ] Migration commit is signed + Verified.

## Notes
- If GRDB 7 surfaces unavoidable Swift-6-only friction even under `.v5`, fall back: keep Yams 6,
  pin GRDB to `6.x`, and record GRDB 7 as blocked-on a real concurrency migration. (Spec rollback.)
