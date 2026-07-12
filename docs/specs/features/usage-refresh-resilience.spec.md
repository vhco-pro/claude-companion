# Feature Spec - Usage refresh resilience (no more silent freeze)

> Part of [Claude Companion](../claude-companion-spec.md). New (v0.6 candidate). Hardens the usage
> gauges from [usage-limits](usage-limits.spec.md). Depends on [foundation](foundation.spec.md).
> Status: **spec**.

## Purpose

The weekly / 5-hour usage bars froze for ~2 days while the app kept running. Diagnosis (2026-07-12):

- Only `usage.json` stopped updating - `companion.db`, `audit.offset`, `jsonl-offsets.json` and the
  blocklist all kept being rewritten on schedule. So the process was alive and un-napped; **only the
  usage refresh had wedged.**
- The live `GET /api/oauth/usage` returned **HTTP 200** and decoded cleanly (five_hour 4%, seven_day
  31%). Token was valid. Relaunching a fresh instance fetched successfully within ~6s.
- So the fetch code and API shape were both fine; a long-lived `URLSession.shared` connection to the
  host had wedged, and nothing recovered it or made the staleness visible.

Three weaknesses turned a transient wedge into a silent multi-day freeze:

1. **No staleness surfacing for usage.** The blocklist tracks `blocklistUpdatedAt` + `blocklistStale`
   and renders "⚠️ stale"; usage has no equivalent, so it serves last-good numbers forever with no
   error and no "updated Xm ago" - indistinguishable from fresh.
2. **No wake / network re-fetch for usage.** The wake-from-sleep observer and the
   network-recovery handler exist but live *inside* `if config.blocklist.enabled` and only call
   `refreshBlocklistNow()`. Usage never re-fetches on wake or when connectivity returns; it waits on
   the 120s timer, and if that path is wedged it never recovers.
3. **Unbounded fetch.** `UsageClient` uses `URLSession.shared` with only a per-request
   `timeoutInterval`. A half-open connection on the shared session can hang far longer, and every
   later fetch reuses the same wedged session.

This is a **resilience** fix. No change to the endpoint, auth, decode shape, or the rendered bars -
we make a wedge self-heal and make staleness impossible to miss.

## Design

### 1. Bounded, self-healing fetch (`UsageClient`)
- Each `fetch()` builds a fresh `URLSessionConfiguration.ephemeral` session with
  `timeoutIntervalForRequest = 20`, `timeoutIntervalForResource = 30` (a hard cap - a wedged
  connection can't hang past it), `waitsForConnectivity = false` (fail fast offline rather than
  queue), and `reloadIgnoringLocalCacheData`; `finishTasksAndInvalidate()` on the way out. A wedged
  connection therefore dies within 30s and the next 120s tick starts clean.

### 2. Staleness tracking + surfacing (`AppModel`)
- `usageUpdatedAt: Date?` - set to `Date()` on every successful fetch, and seeded from the
  `usage.json` file mtime when last-good is loaded at launch (so a relaunch shows the real age).
- `usageStale: Bool` - true when `usage != nil` and `usageUpdatedAt` is older than
  `2 × usageRefreshInterval` (interval promoted to a `static let usageRefreshInterval = 120`,
  reused by the timer). Mirrors `blocklistStale`.
- `UsageSection` renders a small footer line under the bars: `updated 1m ago`, appending
  `⚠️ stale` in orange when `usageStale`. The failure now shows itself instead of masquerading as
  fresh data.

### 3. Wake + network re-fetch for usage (`AppModel`)
- Factor the wake observer + `NWPathMonitor` recovery handler out of the blocklist-only block into a
  shared setup that runs regardless of blocklist config. On wake-from-sleep and on network recovery
  (`wasOffline` → satisfied) it calls `refreshUsageNow()`, and `refreshBlocklistNow()` only when the
  blocklist is enabled. A closed laptop or a dropped link no longer leaves usage frozen until the
  next slow timer.

## Non-goals

- No new endpoint, header, or credential handling - the token path is unchanged.
- No change to the decoded `UsageSnapshot` shape or the bar rendering.
- No background daemon - the in-process timer stays the refresh driver; we just bound and
  supplement it.

## Acceptance criteria

1. A wedged/slow usage request cannot exceed ~30s; the following 120s tick fetches successfully
   without an app relaunch.
2. When the last successful usage fetch is older than ~4 min, the popover and dashboard show
   `updated Nm ago ⚠️ stale`; a successful fetch clears it and updates the timestamp.
3. Waking from sleep or regaining network triggers an immediate usage re-fetch, independent of
   whether the blocklist is enabled.
4. The live API payload as of 2026-07-12 (with `limits` / `spend` / `extra_usage` and null codename
   buckets) still decodes to the rendered five_hour + seven_day buckets (regression test).
5. No change to endpoint, auth, decoded shape, or the bars when data is fresh.
