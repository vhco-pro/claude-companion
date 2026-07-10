# Plan - Confirmation when acting on a surfaced decision

> Implements [decision-action-feedback.spec.md](../specs/features/decision-action-feedback.spec.md).
> Build order **17**. Refines the Decisions surface of [allow-tier](10-allow-tier.plan.md) +
> [approval-ux](3-approval-ux.plan.md) + [decision-timestamps](16-decision-timestamps.plan.md).
> **Branch:** `feat/decision-action-feedback`.

## Outcome

Tapping **Always allow this** / **Block this** on a Needs-attention row now confirms itself two ways:
a transient toast at the top of the surface (`✓ Always allowing · git push origin main · applies on
next call`) and a persistent row mark (`allowed ✓` / `blocked ✓` badge + a confirmation line on
re-expand). The audit row stays put - it's history and the exception applies on the *next* call - so
both signals exist to make "the tap registered, going forward" unmistakable. No rule / ingest / DB /
hook-contract change; `alwaysAllow`/`blockThis` already do the write, we surface it.

## Phases

### P1 - Model state + pure summary in CompanionKit (unit-tested)
- In `AppModel` add:
  - `public enum DecisionActionKind: String, Sendable { case allow, block }`.
  - `public struct ActionFeedback: Identifiable, Sendable, Equatable` with `id: Int` (monotonic),
    `kind: DecisionActionKind`, `summary: String`. No SwiftUI types - color/icon derive in the view.
  - `public private(set) var actionFeedback: ActionFeedback?` and
    `public private(set) var actionedDecisions: [Int64: DecisionActionKind] = [:]`.
  - `public static func actionSummary(_ record: AuditRecord) -> String` - `command` collapsed to one
    line (split on whitespace, join with a space) and truncated to ~60 chars with an ellipsis;
    fallback to `tool`, then `—`. Pure.
  - `private var feedbackSeq = 0`; `private func showFeedback(kind:summary:)` bumps the seq, sets
    `actionFeedback`, and starts a `Task` that sleeps ~3s then clears **only if** the seq still
    matches (a newer toast wins). `public func dismissFeedback()` clears it now.
- Wire into the existing actions (after the rule write, before/around `refresh()`):
  - `alwaysAllow`: on success record `actionedDecisions[id] = .allow` (when `record.id != nil`) and
    `showFeedback(kind: .allow, summary: Self.actionSummary(record))`. Keep the `decision == "ask"`
    guard - no feedback for a non-ask.
  - `blockThis`: same with `.block`.
- *Tests* (`DecisionActionFeedbackTests`): `actionSummary` one-lines a multi-whitespace command;
  truncates an over-long command with `…`; falls back to `tool` when `command` is nil/empty; returns
  `—` when both are nil. (Pure static - no DB/UI, same shape as `DecisionTimestampTests`.)

### P2 - Row mark + confirmation line (shared `DecisionsList`)
- `DecisionRow`: add `var actioned: DecisionActionKind? = nil`. When set, replace the trailing
  `Text(d.decision)` with a badge - `allowed ✓` (green) / `blocked ✓` (red) - so the collapsed row
  shows the outcome. Unactioned rows are byte-for-byte unchanged.
- `DecisionsList`: pass `actioned: model.actionedDecisions[d.id]` (guard `d.id`); in
  `decisionActions(_:)`, when the row is already actioned show a single confirmation line
  (`✓ Now always-allowed · applies on next call` / `✓ Now blocked · applies on next call`) in place
  of the `ask` buttons. The `deny` and default branches are unchanged.

### P3 - Toast rendering (both surfaces)
- Add `ActionFeedbackBanner(model:)` in `Sections.swift`: renders nothing when `actionFeedback == nil`;
  else a rounded banner with the kind's icon+tint, the summary, and `applies on next call`, with a
  `.transition(.move(edge: .top).combined(with: .opacity))` and `onTapGesture { model.dismissFeedback() }`.
- Mount it as a top overlay on `PanelView` (width 300 - keep it inside the padding) and
  `DashboardView`, animated on `model.actionFeedback`.

### P4 - Verify
- `make test` - new `DecisionActionFeedbackTests` pass; existing suite stays green.
- `make run` - expand a Needs-attention `ask` row, tap **Always allow this**: green toast appears and
  auto-dismisses; row shows `allowed ✓`; re-expand shows the confirmation line. Repeat **Block this**
  (red). Confirm both in the popover and the dashboard Decisions tab. Confirm a `deny` row is
  unchanged.

## Acceptance criteria
Mirrors [the spec](../specs/features/decision-action-feedback.spec.md#acceptance-criteria).
