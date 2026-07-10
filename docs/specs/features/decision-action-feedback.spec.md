# Feature Spec - Confirmation when acting on a surfaced decision

> Part of [Claude Companion](../claude-companion-spec.md). New (v0.6 candidate). Refines the
> Decisions surface of [approval-ux](approval-ux.spec.md), [panel-redesign](panel-redesign.spec.md)
> and [allow-tier](allow-tier.spec.md). Depends on [foundation](foundation.spec.md). Status: **spec**.

## Purpose

Expanding a **Needs attention** row exposes two actions - **Always allow this** and **Block this**
(allow-tier.spec.md). Tapping either one writes a scoped exception to `rules.local.yaml`, but the
UI gives **no confirmation**: the expanded row simply collapses, and the audit row stays exactly
where it was. That row is a *historical* record - the exception only takes effect on the hook's
**next** call - so it does not disappear or change tier. From the user's chair, tapping "Always
allow this" looks like nothing happened. They can't tell the tap registered, whether it hit allow
vs block, or that the change applies going forward rather than retroactively.

This is a **feedback** fix. No rule, ingest, DB, or hook-contract change - `alwaysAllow`/`blockThis`
already do the right thing. We only surface that they happened.

## Design

### 1. Two complementary signals

Tapping **Always allow this** or **Block this** produces:

1. **A transient toast** - a brief banner at the top of the surface (popover and dashboard both)
   confirming *what* was actioned and *that it applies next time*, e.g.
   `✓ Always allowing · git push origin main · applies on next call`. Auto-dismisses after ~3s; a
   tap dismisses it immediately. Allow is green/`checkmark.shield.fill`; block is red/`xmark.shield.fill`.
2. **A persistent row mark** - the actioned row restyles for the rest of the session so a later
   glance still shows the outcome: the collapsed row gets an `allowed ✓` / `blocked ✓` trailing
   badge in the action's tint, and re-expanding it shows `Now always-allowed · applies on next call`
   instead of the buttons (you can't re-allow what you just allowed).

The toast catches the eye in the moment; the row mark is the durable record for when you look back.
Both are needed because the row does **not** leave the list after the action.

### 2. State lives on AppModel (CompanionKit)

- `actionFeedback: ActionFeedback?` - the current toast, or `nil`. `ActionFeedback` carries a
  monotonic `id` (so a new toast re-triggers the transition), a `kind` (`.allow` / `.block`), and a
  `summary` string. Presentation (color, icon) is derived in the view from `kind`, matching how
  `DecisionRow` already maps a decision to color/icon.
- `actionedDecisions: [Int64: DecisionActionKind]` - decision-record `id` → the action taken. Keyed
  by the stable `AuditRecord.id`, so it survives `refresh()` (the same row is re-fetched) and drives
  the row mark. In-memory only; a fresh launch starts clean (the exception itself is already
  persisted in `rules.local.yaml`).
- `alwaysAllow`/`blockThis` set both (`actionedDecisions[id]` + a new toast) after the existing rule
  write, then `refresh()` as today. `dismissFeedback()` clears the toast; an internal ~3s timer
  clears it too, guarded by the monotonic id so a newer toast is never cleared by an older timer.

### 3. Pure, testable summary

- `AppModel.actionSummary(_ record:) -> String` - the human label for the toast/row: the command
  collapsed to one line and truncated (fallback to the tool name, then `—`). Pure and unit-tested,
  same discipline as the timestamp helpers (decision-timestamps.spec.md).

### 4. Rendering (shared section views)

- A small `ActionFeedbackBanner(model:)` view renders the toast (nothing when `actionFeedback` is
  `nil`) with a slide/fade transition; mounted as a top overlay on both `PanelView` and
  `DashboardView`, so it appears wherever the action was taken.
- `DecisionRow` takes an optional `actioned: DecisionActionKind?`; when set it shows the trailing
  badge. `DecisionsList` passes `model.actionedDecisions[d.id]` and, in the expanded detail, swaps
  the action buttons for the confirmation line when the row is already actioned.

## Non-goals

- No retroactive re-evaluation of the actioned call - honoring the exception on the *next* call is
  the existing, correct behavior (allow-tier.spec.md); the copy says so explicitly.
- No change to the hard-`deny` path - it still routes to "Edit deny rule…" with no allow/toast.
- No persistence of the row mark across launches - the durable truth is `rules.local.yaml`.

## Acceptance criteria

1. Tapping **Always allow this** shows a green toast naming the command and stating it applies on the
   next call; the toast auto-dismisses after ~3s and dismisses immediately on tap.
2. Tapping **Block this** shows the equivalent red toast.
3. After either action, the collapsed row shows an `allowed ✓` / `blocked ✓` badge in the action's
   tint, and re-expanding it shows the confirmation line instead of the buttons.
4. The row mark persists across a `refresh()` (the row is not re-offered as actionable) and is
   visible in both popover and dashboard.
5. A hard `deny` row is unaffected - no toast, no badge, still "Edit deny rule…".
6. `AppModel.actionSummary` is unit-tested: command one-lined + truncated, tool fallback, `—` when
   both are absent.
