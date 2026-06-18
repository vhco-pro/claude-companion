# Feature Spec - Approval UX (how `ask` reaches you)

> Part of [Claude Companion](../claude-companion-spec.md). Build order **3** (M2).
> Depends on [permission-engine](permission-engine.spec.md), [foundation](foundation.spec.md).
> Status: **spec (revised 2026-06-15 after empirical recon).**

## ⚠️ Design revision - this feature collapsed

The original v0.1 design had the daemon **hold the hook call open** while a notification
banner / pending-queue waited for your Allow/Deny click. **Empirical findings killed that
design:**

1. **Hook block-timeout runs the command.** On Claude Code 2.1.177, if a `PreToolUse` hook
   blocks past its timeout, the tool **proceeds (runs)** - it does *not* fall back to a
   prompt. Holding the call open for a slow human is therefore unsafe.
2. **Notification action-hooks are unreliable in the VSCode extension** (research-reported),
   and the user runs the extension, not the terminal.
3. The user's own intent: *"it should not replace anything."*

**Revised model: for an `ask`-tier match, the hook simply returns `permissionDecision:
"ask"` and Claude Code shows its OWN native permission prompt.** You answer in Claude Code,
exactly where you already do. No custom banner, no pending queue, no held-open daemon call.

## What this feature now is

A thin, **informational** layer - it never gates a decision (the native prompt does that):

- **Deny notification (best-effort).** When the engine returns `deny`, post a passive macOS
  notification ("Companion blocked: `<cmd>`") so a 2am block isn't silent. No action buttons,
  no waiting. Config: `approval.notify_on_deny: true|false`. (May not surface in the VSCode
  extension - treat as best-effort, never load-bearing.)
- **Recent-decisions surface in the dropdown.** The menu-bar panel shows a short list of
  recent allow/deny/ask decisions (from the audit log) so you can see what auto-ran. This is
  read-only history, not a queue to action.

## Config - `config.yaml`
```yaml
approval:
  notify_on_deny: true     # passive banner when a command is hard-denied
  recent_count: 20         # how many recent decisions to show in the dropdown
```

## Removed from scope (vs v0.1)
- ❌ Hold-open hook calls / `PendingApproval` blocking lifecycle.
- ❌ Notification action buttons (Allow/Deny on the banner).
- ❌ Pending-approval queue with age timers + inline resolve.
- ❌ `notify_mode: banner|badge|both`, `timeout_seconds`, `on_timeout`.
- ❌ "Always allow this" custom exception flow - Claude Code's native prompt already offers
  its own "don't ask again" affordance; an `ask` rule that's too noisy is edited in
  `rules.yaml` instead.

## Acceptance criteria
- [ ] An `ask`-tier match produces Claude Code's native permission prompt (no custom UI),
      and the hook returns within the latency budget (does not block).
- [ ] A `deny`-tier match posts a passive deny notification when `notify_on_deny: true`,
      and is silent when `false`.
- [ ] The dropdown shows the most recent N decisions from the audit log, read-only.
- [ ] Nothing in this feature ever holds a hook call open.

## Open questions
- Does the VSCode extension surface passive (action-less) `UNUserNotificationCenter`
  notifications from a background daemon? If not, the deny-notification is dropped and the
  dropdown recent-list is the only surface. Confirm during plan 3.
