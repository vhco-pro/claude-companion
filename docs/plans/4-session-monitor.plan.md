# Plan - Session Monitor

> Implements [session-monitor.spec.md](../specs/features/session-monitor.spec.md).
> Build order **4**. Depends on [foundation](1-foundation.plan.md). Read-only on `~/.claude`.

## Outcome

Live sessions, token totals, and tool chains in the DB + reflected in the in-app UI, parsed from the
per-session project JSONL using the **confirmed** shapes from recon.

## Phases

### P0 - JSONL tailer (`CompanionKit`)
- `FSEventStream` on `~/.claude/projects`, 500ms debounce; discover new
  `<session-uuid>.jsonl`, tail existing from a **persisted byte offset** (so restart resumes,
  not re-scans).
- Buffer partial trailing lines until newline; never block on mid-write files.
- *Test:* restart resumes from offset (no double-count); truncated trailing line is tolerated.

### P1 - Parser
- Decode the confirmed envelope. Extract per line:
  - `.sessionId`, `.cwd` (project path - do **not** decode the dir name), `.version`,
    `.gitBranch`, `.timestamp`.
  - `.message.model`; `.message.usage.{input_tokens, output_tokens,
    cache_creation_input_tokens, cache_read_input_tokens}`.
  - `.message.content[] | select(.type=="tool_use") | {name, input}` →
    Bash `input.command`, Edit/Write/Read `input.file_path`.
- Forward-compatible: unknown `type` / extra fields logged + skipped, never fatal.
- *Test:* parse a real captured JSONL; counts reconcile with `jq` over the same file.

### P2 - Persistence
- Upsert `sessions`; append `tool_events`; append/rollup `token_usage`.
- Per-session and per-project token totals.
- *Test:* tool calls land in `tool_events`; token sums match the source file.

### P3 - Liveness
- Active if recent event within window; reconcile with `SessionStart`/`Stop` signals from
  the permission-engine hooks (faster than fs-events alone).
- *Test:* session starts ⇒ active; ends ⇒ inactive within the window.

### P4 - Surface to the UI (in-process)
- Expose sessions/tool-chains/token deltas as observable in-app state (Swift observation);
  the menu-bar UI reads it directly - no IPC/push. (Faster SessionStart/Stop signals arrive
  via the hook's `audit.ndjson` lines that the app already tails.)
- *Test:* UI reflects session create + tool-chain updates live as the tailer ingests.

## Acceptance criteria (from spec)
- [ ] New session ⇒ `sessions` row + active.
- [ ] Tool calls append; recent chain queryable.
- [ ] Token totals per session + project match JSONL.
- [ ] Restart resumes from offset; truncated line safe.
- [ ] Zero writes under `~/.claude` (verified).

## Risks
- Context-fill % has no JSONL field → derive vs per-model context window (shared table with
  cost). Confirm window sizes (Opus 4.8 = 1M).
