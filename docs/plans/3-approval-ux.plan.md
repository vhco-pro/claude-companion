# Plan - Approval UX

> Implements [approval-ux.spec.md](../specs/features/approval-ux.spec.md). Build order **3**.
> Depends on [permission-engine](2-permission-engine.plan.md) + [foundation](1-foundation.plan.md).
> **Revised 2026-06-15** - collapsed after recon (see spec's design-revision note).

## Outcome

`ask`-tier matches surface via Claude Code's **own native prompt** (the hook returns
`"ask"`). Companion adds only a passive deny-notification and a read-only recent-decisions
list. No held-open hook calls, no custom banner/queue.

## Phases

### P0 - `ask` → native prompt (mostly engine-side)
- Confirm the hook returning `permissionDecision:"ask"` triggers Claude Code's native
  prompt and that the hook returns immediately (no block). This is largely verified by the
  permission-engine work; this phase just asserts the end-to-end UX.
- *Test:* an `ask` rule (e.g. `git push`) yields the native prompt; hook latency within budget.

### P1 - Passive deny notification
- The app, tailing `audit.ndjson`, posts an action-less `UNUserNotificationCenter`
  notification ("Companion blocked: `<cmd>`") when it ingests a `deny`. Config
  `approval.notify_on_deny`.
- *Test:* deny with flag on posts a banner; off is silent. (Best-effort in VSCode extension -
  verify whether app notifications surface there; if not, document the drop.)

### P2 - Recent-decisions list in the dropdown
- Read-only list of the last `approval.recent_count` decisions from the audit log
  (allow/deny/ask, command, time, rule matched).
- *Test:* recent decisions render and update live; list is informational only (no actions).

## Acceptance criteria (from spec)
- [ ] `ask` match ⇒ native Claude Code prompt; hook never blocks.
- [ ] `deny` ⇒ passive notification when `notify_on_deny: true`, silent when `false`.
- [ ] Dropdown shows recent N decisions, read-only.
- [ ] Nothing here holds a hook call open.

## Risks
- VSCode-extension may not surface app notifications → deny-notification degrades to
  "dropdown recent-list only." Verify in P1; not load-bearing either way.
