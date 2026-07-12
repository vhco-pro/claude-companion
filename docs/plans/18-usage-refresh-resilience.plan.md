# Plan - Usage refresh resilience (no more silent freeze)

> Implements [usage-refresh-resilience.spec.md](../specs/features/usage-refresh-resilience.spec.md).
> Build order **18**. Hardens [usage-limits](5-usage-limits.plan.md). **Branch:**
> `fix/usage-refresh-resilience`.

## Outcome

The 5-hour / weekly bars can no longer freeze silently. A wedged fetch self-heals within 30s, usage
re-fetches on wake and network recovery (not just the 120s timer), and when the last good fetch ages
past ~4 min the UI shows `updated Nm ago ⚠️ stale` instead of serving stale numbers as if fresh. No
change to endpoint, auth, decoded shape, or the bars when data is fresh.

## Phases

### P1 - Bounded, self-healing fetch (`UsageClient`) ✅
- Per-call `URLSessionConfiguration.ephemeral`: `timeoutIntervalForRequest = 20`,
  `timeoutIntervalForResource = 30`, `waitsForConnectivity = false`,
  `reloadIgnoringLocalCacheData`; `finishTasksAndInvalidate()` in `defer`. Replaces
  `URLSession.shared`.

### P2 - Live-shape regression test (`UsageTests`) ✅
- `testDecodesCurrentLiveShape2026_07`: decode the full 2026-07-12 payload (with `limits`, `spend`,
  `extra_usage`, null codename buckets) and assert five_hour=4 / seven_day=31 still parse.

### P3 - Staleness tracking + surfacing (`AppModel` + `UsageSection`)
- `public static let usageRefreshInterval: TimeInterval = 120`; use it for the timer interval.
- `public private(set) var usageUpdatedAt: Date?` - set `= Date()` on `.success` in
  `refreshUsageNow`; seed from `fileModified(usagePath)` right after `usage = loadUsage()` at launch.
- `public var usageStale: Bool` - `usage != nil` and `usageUpdatedAt` older than
  `2 × usageRefreshInterval` (guard nil → false). Mirrors `blocklistStale`.
- `UsageSection`: under the bars, when `usageUpdatedAt != nil`, a `.caption2` secondary line
  `updated \(AppModel.relative(at))`, appending ` ⚠️ stale` in orange when `usageStale`.

### P4 - Wake + network re-fetch for usage (`AppModel`)
- Extract a `private func startConnectivityRefresh()` that (a) registers the
  `NSWorkspace.didWakeNotification` observer and (b) sets `netMonitor.pathUpdateHandler` +
  `netMonitor.start`. Both call `refreshUsageNow()` always and `refreshBlocklistNow()` only when
  `config.blocklist.enabled`. Remove the wake/net registration from inside the blocklist block and
  call `startConnectivityRefresh()` once after the usage timer is scheduled.

### P5 - Verify
- `make test` - new + existing usage tests green; full suite green.
- `make run` - bars populate; kill wifi → within a tick the footer flips to `⚠️ stale`; restore →
  it clears and the timestamp advances. (Manual, since AppModel isn't unit-instantiated.)

## Acceptance criteria
Mirrors [the spec](../specs/features/usage-refresh-resilience.spec.md#acceptance-criteria).

## Notes
- Deferred sibling task (user-requested, tracked separately): install the tap cask
  `vhco-pro/tap/claude-companion` (latest 0.7.1; local has 0.6.1) and remove stale dev `.app`
  bundles registered with LaunchServices so the launcher shows one good version.
