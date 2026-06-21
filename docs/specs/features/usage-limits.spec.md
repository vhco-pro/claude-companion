# Feature Spec - Usage Limits (5h + weekly)

> Part of [Claude Companion](../claude-companion-spec.md). Build order **5** (M1).
> Depends on [foundation](foundation.spec.md). Status: **shipped v0.1 (endpoint confirmed 2026-06-15).**

## Purpose

Show the user how close they are to their Claude limits without a separate API key - by
reusing the OAuth token Claude Code already stores and polling the usage endpoint.

## ✅ Confirmed endpoint (live probe, 2026-06-15, HTTP 200)

```
GET https://api.anthropic.com/api/oauth/usage
Headers:
  Authorization: Bearer <claudeAiOauth.accessToken>   # sk-ant-oat01… OAuth token
  anthropic-beta: oauth-2025-04-20
```
Response shape (each bucket is `{utilization: <float %>, resets_at: <ISO8601 UTC>}`, or
`null` when not applicable to the plan):
```json
{
  "five_hour":  { "utilization": 22.0, "resets_at": "2026-06-15T20:00:00Z" },
  "seven_day":  { "utilization": 23.0, "resets_at": "2026-06-18T22:00:00Z" },
  "seven_day_opus":   null,
  "seven_day_sonnet": { "utilization": 0.0, "resets_at": "…" },
  "seven_day_oauth_apps": null, "seven_day_cowork": null, "seven_day_omelette": null,
  "tangelo": null, "iguana_necktie": null, "omelette_promotional": null, "cinder_cove": null,
  "extra_usage": { "is_enabled": false, "monthly_limit": null, "used_credits": null,
                   "utilization": null, "currency": null, "disabled_reason": "…" }
}
```
- `five_hour` → the 5h session gauge. `seven_day` → weekly all-models gauge.
- `seven_day_<model>` → per-model weekly; **frequently `null`** (e.g. opus was null on this
  account). Several extra buckets are internal codenames - ignore unknown keys, render only
  the ones we recognize and that are non-null.
- Related endpoints seen in the binary (not used by this feature): `/api/oauth/profile`-style
  routes, `/api/claude_code/policy_limits`, `/api/rate-limits`.

## Auth

- The token lives in the macOS **Keychain** as a generic password -
  `service = "Claude Code-credentials"`, `account = <macOS username>`; value is JSON with
  `claudeAiOauth.{accessToken, refreshToken, expiresAt, scopes, subscriptionType,
  rateLimitTier}` + `organizationUuid`. Read `claudeAiOauth.accessToken`. No
  `~/.claude/.credentials.json` on this machine; keep the file path only as a fallback.
- **Read-only** - never refresh, rotate, or write credentials.
- **Keychain ACL prompt (impl note):** the item's ACL is keyed to Claude Code's signing
  identity. Companion (ad-hoc signed / different identity) reading it triggers a one-time macOS
  prompt - *"ClaudeCompanion wants to use Claude Code-credentials"* - which the user resolves
  with **Always Allow**. A proper Developer-ID signature doesn't remove this (still a different
  identity), so document the Always-Allow step in onboarding. If access is denied the poller
  reports the signed-out state.
- If the token is missing/expired (check `expiresAt`), surface a clear "sign in via Claude
  Code" state rather than failing silently. Do not attempt our own OAuth flow in v0.1.

## Polling

- Poll the usage endpoint every **~2 min**; exponential backoff on rate-limit (429) or
  error, capped.
- Surface:
  - current **5h session %** + **reset time** (local `HH:mm`, from `five_hour.resets_at`),
  - **weekly all-models %** + **reset day** (local `EEE HH:mm`, e.g. "resets Thu 22:00", from
    `seven_day.resets_at`) - *implemented 2026-06-16; the user specifically wanted the day of week.*
  - **per-model weekly** (Opus / Sonnet / Fable) where the plan exposes it.
  - `resets_at` is parsed with `ISO8601DateFormatter` (fractional-seconds variant + plain
    fallback); `DateFormatter` renders it in the **local** timezone.
- Cache the last good response in memory **and persist it to `usage.json`** (implemented
  2026-06-16) so a relaunch shows last-known bars immediately instead of blanking while the
  first poll is in flight (or rate-limited).
- **Signed-out vs transient error (implemented):** only the **no-token** case shows "sign in";
  transient failures (HTTP 429, offline) keep the last-good bars and the status item shows `-`
  with a "Usage unavailable (…) - retrying" note - never a misleading "sign in". (Frequent
  relaunches during dev can themselves trigger 429 since each launch polls immediately; it
  clears on its own.)

> ⚠️ **Still an unpublished API.** Confirmed working today, but not a stable/documented
> contract. Decode defensively: tolerate missing/null/new fields, render only recognized
> non-null buckets, never crash on shape drift. Isolate decoding behind one type so a future
> shape change is a one-file fix.

## Output to UI

- Update in-process state with the parsed usage model (this poller runs **inside the app**,
  on a timer - no daemon). The menu-bar status string and
  dropdown Usage section ([menubar-ui](menubar-ui.spec.md)) render it with color grading
  (green <50 / orange 50-79 / red 80+).

## Acceptance criteria

- [ ] Reads the existing Claude Code token from Keychain (fallback to credentials file)
      without prompting for a new login.
- [ ] Shows live 5h % and weekly % with reset countdowns.
- [ ] Shows per-model weekly breakdown when the response includes it; hides it cleanly
      when it doesn't.
- [ ] 429 triggers backoff, not a hammering loop; UI shows last-known + staleness.
- [ ] Missing/expired token → explicit "sign in via Claude Code" state, no crash.
- [ ] Never writes to Keychain or the credentials file (verified).

## Open questions

- *(Resolved - endpoint, headers, and schema all confirmed by live probe; see top.)*
- Minor: does `anthropic-version` need to be sent? The probe succeeded with and without it -
  send a current value to be safe.
- Confirm safe poll cadence against this endpoint's own rate limits (start ~2 min, back off).
