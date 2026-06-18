# Plan - Usage Limits

> Implements [usage-limits.spec.md](../specs/features/usage-limits.spec.md). Build order **5**.
> Depends on [foundation](1-foundation.plan.md).
> **Endpoint confirmed by live probe 2026-06-15 - no spike needed.**

## Phases

### P0 - ✅ Endpoint (resolved)
- `GET https://api.anthropic.com/api/oauth/usage` + `Authorization: Bearer <oauth>` +
  `anthropic-beta: oauth-2025-04-20` → `{five_hour, seven_day, seven_day_<model>,
  extra_usage}` (HTTP 200). Schema pinned in the
  [spec](../specs/features/usage-limits.spec.md#-confirmed-endpoint-live-probe-2026-06-15-http-200).
  Nothing to discover; proceed straight to the decoder.

### P1 - Keychain reader (`CompanionKit`)
- Read generic password `service="Claude Code-credentials"`, `account=<username>` (confirmed
  by recon). Parse the token. Read-only. Fallback to `~/.claude/.credentials.json` if present.
- Missing/expired ⇒ explicit "sign in via Claude Code" state.
- *Test:* reads existing token without a new login; missing-token path yields the signed-out
  state, no crash.

### P2 - Poller
- Poll every ~2 min; exponential backoff on 429/errors, capped. Cache last-good in memory.
- *Test:* 429 ⇒ backoff (no hammering); UI shows last-known + staleness flag.

### P3 - Defensive decoder
- Decode the P0 schema tolerantly: missing fields hidden, present fields shown; never crash on
  shape drift.
- *Test:* synthetic responses with missing/extra fields decode gracefully.

### P4 - Surface to the UI (in-process)
- Expose the usage model (5h %, weekly %, per-model, reset countdowns) as observable in-app
  state; the status item + Usage section read it directly with color grading. (Poller runs on
  a timer inside the app - no daemon, no push.)
- *Test:* live 5h/weekly %, countdowns, per-model shown when present / hidden when absent.

## Acceptance criteria (from spec)
- [ ] Reads existing token from Keychain, no re-login.
- [ ] Live 5h % + weekly % + reset countdowns.
- [ ] Per-model shown when available, hidden when not.
- [ ] 429 ⇒ backoff + last-known/staleness.
- [ ] Missing token ⇒ "sign in via Claude Code".
- [ ] Never writes Keychain/creds (verified).

## Risks
- The endpoint is undocumented and may change - keep the decoder defensive and isolate it
  behind one type so a future shape change is a one-file fix.
