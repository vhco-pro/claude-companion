# Feature Spec - Approval UX (how `ask` reaches you)

> Part of [Claude Companion](../claude-companion-spec.md). Build order **3** (M2).
> Depends on [permission-engine](permission-engine.spec.md), [foundation](foundation.spec.md).
> Status: **shipped v0.1 (revised 2026-06-15 after empirical recon).**

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

- **Deny notification (built 2026-06-28).** When the engine returns `deny`, the app posts a
  passive macOS notification ("Claude Companion blocked a command — `<cmd>`") so a 2am block
  isn't silent. Config: `approval.notify_on_deny: true|false` (default true). Posted by the
  **running app** (not the hook/daemon), so it surfaces as a normal local notification - the
  earlier "may not surface in VSCode" worry doesn't apply (that was about hook/daemon-posted
  ones). No action *buttons* (a hard deny isn't one-click-allowable), but **clicking the banner
  reveals the config folder** (where `rules.yaml` lives) so a wrong rule is one step from edit.
- **Needs-attention surface in the dropdown (built; revised).** The menu-bar panel shows recent
  **ask/deny** decisions (routine `allow`s are hidden - they're the 99% and aren't actionable),
  with an `N total` count. An `ask`/compromised row offers "Always allow this" / "Block this";
  a hard `deny` offers a guarded "Edit deny rule…". See [allow-tier](allow-tier.spec.md).

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
- ⤳ "Always allow this" custom exception flow - *originally* deferred to Claude Code's native
  "don't ask again", but **subsequently built as its own feature** ([allow-tier](allow-tier.spec.md),
  shipped 2026-06-28): it writes an app-owned `rules.local.yaml` exception, scoped to the matched
  tool+pattern, and can clear an `ask`/compromised match (never a hard `deny`).

## Acceptance criteria
- [x] An `ask`-tier match produces Claude Code's native permission prompt (no custom UI),
      and the hook returns within the latency budget (does not block).
- [x] A `deny`-tier match posts a passive deny notification when `notify_on_deny: true`,
      and is silent when `false`. *(built 2026-06-28; clicking it reveals the config folder)*
- [x] The dropdown shows recent decisions from the audit log. *(revised: actionable ask/deny only;
      routine allows hidden - see [allow-tier](allow-tier.spec.md))*
- [x] Nothing in this feature ever holds a hook call open.

## Open questions
- *(Resolved 2026-06-28)* VSCode-surfacing was never the issue: the notification is posted by the
  **running menu-bar app**, not a hook/daemon, so it shows as a normal macOS local notification.
