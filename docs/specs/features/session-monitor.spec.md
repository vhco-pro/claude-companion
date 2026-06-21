# Feature Spec - Session Monitor (JSONL ingestion)

> Part of [Claude Companion](../claude-companion-spec.md). Build order **4** (M0/M3).
> Depends on [foundation](foundation.spec.md). Status: **shipped v0.1**.

## Purpose

Build the live picture of every Claude Code session by tailing the JSONL logs Claude Code
already writes. Produces sessions, token totals, and tool-call chains for the UI and the
cost feature. **Strictly read-only** - never writes to `~/.claude`.

## Data sources

- `~/.claude/projects/<encoded-path>/<session-uuid>.jsonl` - per-session event stream.
- **`~/.claude/projects/<enc>/<uuid>/subagents/agent-*.jsonl` - subagent transcripts**
  (confirmed: on this machine 52 of 76 files were subagent transcripts). They carry the
  **parent session's `sessionId`**, so the tailer scans `projects/` **recursively** and their
  tokens/tools attribute to the right session. They're separate API calls in separate files →
  **additive, not double-counted**. (One-level scanning badly undercounts agent-heavy sessions:
  e.g. ssm-connect went 2465→3958 tool events / its top session to 1,414 tools, 5.1M output once
  subagents were folded in.)
- `~/.claude/history.jsonl` - cross-session history (prompt text only; not the token source).
- Watched with `FSEventStream` on `~/.claude`, debounced ~500ms. New files are picked up;
  each file is tailed from a **persisted per-file byte offset** (restart resumes, no re-read /
  double-count). **Ingest is batched one transaction per file** (not per event) so the first
  full scan is fast.

### Confirmed JSONL shape (recon 2026-06-15, Claude Code 2.1.177)

Event envelope is one JSON object per line. Confirmed top-level keys:
`type, message, sessionId, cwd, gitBranch, version, timestamp, uuid, parentUuid,
promptId, requestId, toolUseResult`. Observed `type` values: `assistant`, `user`,
`attachment`, `file-history-snapshot`, `ai-title`, `last-prompt`, `queue-operation`.

The token/tool payload lives **nested under `.message`**, not at top level:
- **project path** → top-level `.cwd` (use this; do *not* reverse the directory's
  path-encoding).
- **session id** → top-level `.sessionId`.
- **model** → `.message.model` (e.g. `claude-opus-4-8`).
- **tokens** → `.message.usage`:
  `input_tokens`, `output_tokens`, `cache_creation_input_tokens` (= cache *write*),
  `cache_read_input_tokens` (= cache *read*). (Also a nested `cache_creation`
  ephemeral-5m/1h split and `server_tool_use` web counts - ignore for v0.1.)
- **tool calls** → `.message.content[] | select(.type=="tool_use") | {name, input}`.
  For Bash, `input.command`; for Edit/Write/Read, `input.file_path`. Renders the tool
  chain (Bash › Edit › Read …).

> `history.jsonl` is **prompt history only** - keys `{display, pastedContents, project,
> sessionId, timestamp}`. No token/tool data. Primary ingestion source is the per-session
> project JSONL above; `history.jsonl` is optional, for prompt-text enrichment only.

## Parsing

Map the confirmed shape above into the foundation tables. Derive **context-fill %** and
per-session/per-project token rollups from `.message.usage`.

Persist to foundation tables `sessions`, `tool_events`, `token_usage`. This runs **inside the
app**; the UI reads the updated state in-process (no daemon, no IPC).

## Session liveness

- A session is **active** if its file saw an event within a recent window (and/or
  `SessionStart` fired without a matching `Stop` from the permission-engine hooks).
- `Stop`/`SessionStart` hook signals (from permission-engine) refine status faster than
  fs-events alone; session-monitor reconciles the two.

## Robustness

- Tolerate partial/truncated trailing lines (file mid-write) - buffer until newline.
- Tolerate unknown event types and new fields (forward-compatible parsing; log + skip).
- Schema drift in Claude Code's JSONL is expected - parser is defensive, never crashes the
  app on an unrecognized line.

## Acceptance criteria

- [ ] Starting a Claude Code session creates a `sessions` row and shows it as active.
- [ ] Tool calls append to `tool_events`; the recent chain is queryable per session.
- [ ] Token counts accumulate per session and per project and match the JSONL totals.
- [ ] Daemon restart resumes tailing from the persisted offset (no double-count, no
      re-scan of the whole file).
- [ ] A truncated/half-written line never crashes or corrupts state.
- [ ] Ending a session flips it to inactive within the liveness window.
- [ ] Zero writes to anything under `~/.claude` (verified).

## Context-fill % (default locked)

Claude Code doesn't emit a context-window field, so derive: **most-recent assistant turn's
`input_tokens + cache_read_input_tokens + cache_creation_input_tokens`** (i.e. what was in
context for that turn) **÷ the model's context window**. Per-model window table lives in
the same per-model config as pricing (`pricing.yaml`, extended with a `context_window` field; app-editable), seeded:

```yaml
# context windows (tokens)
claude-opus-4-8:    { context_window: 1000000 }   # the [1m] variant; 200000 otherwise
claude-sonnet-4-6:  { context_window: 1000000 }
claude-fable-5:     { context_window: 1000000 }
# unknown model → omit the % (show "-"), never guess
```
> Values to confirm against current docs before shipping. If a model id carries a `[1m]`
> suffix, use 1M; otherwise fall back to the base window for that family.

## Open questions

- None blocking - confirm the per-model window numbers before release.
