# Feature Spec - Dependency Modernization (GRDB 7, Yams 6, CI on Xcode 26)

> Part of [Claude Companion](../claude-companion-spec.md). Maintenance. Depends on
> [foundation](foundation.spec.md). Status: **shipped v0.1.**

## Purpose

Bring the two third-party Swift dependencies to their current majors and align the toolchain so
the project builds on the same Xcode it ships with. This unblocks Dependabot (which keeps
proposing the upgrade and failing CI) and removes a year of dependency drift.

## Background (why now)

Dependabot PR #2 (grouped bump GRDB 6.29.3 -> 7.x, Yams 5.1.0 -> 6.x) failed CI in 21s with:

```
error: Dependencies could not be resolved because 'grdb.swift' >= 7.9.0 contains incompatible
tools version (6.1.0) and root depends on 'grdb.swift' 7.11.0..<8.0.0.
```

Root cause: **GRDB 7 declares `swift-tools-version: 6.0`** (Swift 6 / Xcode 16+), while the CI
runner (`ci.yml`) was pinned to **macos-14**, whose default Xcode is older. The release pipeline
already runs on **macos-26** (Xcode 26); CI lagged. We are on Xcode 26 / Swift 6.3 locally and on
the release runner, so the toolchain is available - CI just needs to use it.

## Scope

In:
- `CompanionKit/Package.swift`: raise `swift-tools-version` to 6.0; bump GRDB to 7.x and Yams to
  6.x; **pin each target's language mode to Swift 5** so the bump does not drag in a full
  strict-concurrency migration.
- `.github/workflows/ci.yml`: raise the runner from `macos-14` to `macos-26` (match `release.yml`).
- `Package.resolved` updates from the bump.

Out (explicit non-goals):
- **Adopting Swift 6 language mode / strict concurrency** across our own code. Raising
  `swift-tools-version` to 6.0 would otherwise flip our targets to Swift 6 mode and cascade
  Sendable/actor errors through `AppModel` (@Observable), the ingestors, etc. We pin language mode
  to `.v5` to keep that out of scope; a deliberate Swift 6 concurrency migration is a separate
  future spec.
- GRDB feature adoption (async observation, etc.). This is a version bump, not a rewrite.

## Migration analysis (grounded in our actual usage)

Our GRDB surface (surveyed): `DatabaseQueue`, `DatabaseMigrator`, `FetchableRecord` /
`PersistableRecord` / `MutablePersistableRecord`, `didInsert(_:InsertionSuccess)`, raw
`execute(sql:arguments:)`, `Row.fetchAll/fetchOne`, `String.fetchAll`, `Int.fetchOne`, `Column`.
Our Yams surface: `YAMLDecoder().decode(_:from:)` only (3 sites).

Against the GRDB 7 + Yams 6 release notes / migration guides:

| GRDB 7 breaking change | Do we use it? | Action |
|---|---|---|
| Coding strategies become per-column `static func` (Date/Data/UUID) | No (no custom strategies) | none |
| Writes use IMMEDIATE transactions by default; `defaultTransactionKind` removed | No (no custom config; simple read/write) | none (behavior is safe for our single-writer use) |
| `DatabasePool.concurrentRead` -> `asyncConcurrentRead` | No (we use `DatabaseQueue`) | none |
| `CSQLite` module renamed `GRDBSQLite`, C symbols not re-exported | No (no raw C SQLite) | none |
| `ValueObservation` defaults to MainActor scheduling | No (we poll/tail, no ValueObservation) | none |
| insert/save/upsert ergonomics changed | No (we insert via raw `execute(sql:)`) | none |
| New `Sendable` conformances (Swift 6 mode) | Indirect | mitigated by pinning our language mode to v5 |
| Min platform macOS 10.15+ | We target macOS 14 | already satisfied |

| Yams 6 breaking change | Do we use it? | Action |
|---|---|---|
| `YamlError.duplicatedKeysInMapping` associated values now Sendable | No | none |
| `YAMLDecoder().decode` / `YAMLEncoder().encode` signatures | unchanged | none |

**Conclusion:** expected code changes = **none** beyond the manifest. The bump is a manifest +
CI-runner change; risk is concentrated in (a) the `swift-tools-version: 6.0` language-mode flip
(mitigated by `.v5` pin) and (b) any incidental new Sendable warnings, caught by the build.

## Acceptance criteria

- [ ] `Package.swift` is `swift-tools-version: 6.0`, depends on GRDB `7.x` + Yams `6.x`, and pins
      every target to Swift 5 language mode.
- [ ] `swift build` + `swift test` pass locally (all 54 tests) with the bumped deps.
- [ ] The `companion-hook` still cross-compiles to the static Linux SDK (it depends only on
      `CompanionCore`, which has no GRDB/Yams - guards against the manifest change breaking the hook).
- [ ] `ci.yml` runs on `macos-26`; the CI job resolves GRDB 7 and passes.
- [ ] The app target still builds (`xcodebuild`), and the menu-bar app runs.
- [ ] Dependabot no longer reopens the failing grouped bump (it is now satisfied).

## Test plan

| Check | How | Expectation |
|---|---|---|
| Unit suite | `swift test --package-path CompanionKit` | 54 pass |
| App build | `xcodebuild build ... ClaudeCompanion` | BUILD SUCCEEDED |
| Linux hook | `swiftly run swift build --product companion-hook --swift-sdk x86_64-swift-linux-musl` | static ELF builds |
| CI | push -> CI workflow on macos-26 | green |
| Release unaffected | next release run | builds on macos-26 as before |

## Risks + rollback

- **Language-mode flip** is the main risk; pinning `.swiftLanguageMode(.v5)` per target keeps our
  code semantics unchanged. If the build surfaces unavoidable Swift 6 issues, that is signal to
  either fix narrowly or revert the GRDB bump (pin GRDB to `6.x`) and keep only Yams 6.
- **GRDB 7 immediate-write transactions**: our DB has a single writer (ingest) and short reads, so
  the IMMEDIATE default does not change observed behavior. No migration of `Configuration` needed.
- Rollback is a one-commit revert of `Package.swift` + `Package.resolved` + `ci.yml`.
