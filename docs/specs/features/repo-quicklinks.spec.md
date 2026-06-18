# Feature Spec - Repo Quicklinks (jump to GitHub/GitLab/Azure DevOps from a session)

> Part of [Claude Companion](../claude-companion-spec.md). New (v0.3 candidate). Extends
> [menubar-ui](menubar-ui.spec.md) B2 session detail + [session-monitor](session-monitor.spec.md).
> Status: **spec.**

## Purpose

When an active/recent session's working directory is a git repo, surface a **clickable link to
the repo's web home** (GitHub / GitLab / Azure DevOps / Bitbucket / generic). One click in the
popover → the browser opens at the repo, instead of the user hand-navigating there every time.
Pure time-saver, zero risk (read-only, opens a URL).

> User's words: *"when a workspace is shown in recent, if that workspace is a git repository I
> should be able to click on the url … get straight to the github/azure devops/gitlab so I can
> check stuff - saves doing it manually each time, huge time gain."*

## Where it shows

In the **expanded session detail** (B2), next to the full project path: a small repo glyph +
the repo's `owner/name` (or host + path) rendered as a link. Click → `NSWorkspace.open(url)`.
Hidden cleanly when the cwd isn't a git repo or has no parseable remote.

## How we get the remote

- **Local sessions:** resolve the remote at **ingest time** (when the session's `cwd` is known),
  not on every render - run `git -C <cwd> config --get remote.origin.url` (or read
  `<cwd>/.git/config`). Cache the parsed web URL on the session row so the UI is pure.
  - Prefer `origin`; if absent, fall back to the first remote. If multiple, `origin` wins.
  - A worktree / submodule resolves via the gitdir pointer - `git -C` handles it; raw
    `.git/config` reading must follow a `gitdir:` file. Use the `git` CLI to avoid that edge.
- **Remote-SSH sessions:** the cwd lives on the remote host - a local `git -C` won't see it. The
  remote URL must be captured during the SSH sync (see [remote-ssh](remote-ssh.spec.md)); this
  feature **depends on that sync** carrying `remote.origin.url` back per session. Until then,
  quicklinks render for local sessions only. (Cross-link tracked in both specs.)

## URL normalization (the core logic - one pure function, well-tested)

Map any remote URL form to a canonical **https web URL**. Strip a trailing `.git`, strip embedded
credentials (`user@`, `https://token@`), lowercase the host. Known hosts:

| Remote form (input) | Web URL (output) |
|---|---|
| `git@github.com:owner/repo.git` | `https://github.com/owner/repo` |
| `https://github.com/owner/repo.git` | `https://github.com/owner/repo` |
| `ssh://git@github.com/owner/repo.git` | `https://github.com/owner/repo` |
| `git@gitlab.com:group/sub/repo.git` | `https://gitlab.com/group/sub/repo` |
| `git@bitbucket.org:owner/repo.git` | `https://bitbucket.org/owner/repo` |
| `git@ssh.dev.azure.com:v3/org/project/repo` | `https://dev.azure.com/org/project/_git/repo` |
| `https://org@dev.azure.com/org/project/_git/repo` | `https://dev.azure.com/org/project/_git/repo` |
| `https://host.tld/<scm>/<path>.git` (self-hosted GitLab/Gitea) | `https://host.tld/<scm>/<path>` |

- **Azure DevOps** is the irregular one: SSH path `v3/{org}/{project}/{repo}` and the https form
  both map to `https://dev.azure.com/{org}/{project}/_git/{repo}`. Legacy
  `{org}.visualstudio.com` → keep host, insert `_git`.
- **Unknown host:** if it parses as `scheme://host/path` or `git@host:path`, still build a
  best-effort `https://host/path` (works for self-hosted GitHub Enterprise / Gitea / generic).
  If it doesn't parse at all → no link (never show a broken/guessed URL).
- **SaaS detection is by host**, not by assuming GitHub - a self-hosted GitLab at
  `git.acme.internal` must produce `https://git.acme.internal/...`, not github.com.

## Out of scope (v1 of this feature)

- Deep links to the *current branch* / a specific file / the latest commit. (Possible later:
  `…/tree/<branch>` from `git branch --show-current`, or `…/commit/<sha>`.) v1 = repo home only.
- Opening PRs / issues. Just the repo landing page.
- Auth - we only build a public web URL; the browser/user's existing login handles access.

## Acceptance criteria

- [ ] A session whose cwd is a GitHub repo shows a clickable link that opens
      `https://github.com/owner/repo` in the browser.
- [ ] GitLab (incl. nested groups), Bitbucket, Azure DevOps (SSH **and** https forms), and a
      self-hosted host all normalize correctly (unit-tested table above).
- [ ] SSH-form remotes (`git@…:…`) and embedded-credential https remotes normalize to a clean,
      credential-free https URL.
- [ ] A non-git cwd, or a remote that can't be parsed, shows **no** link (no crash, no guess).
- [ ] The remote is resolved at ingest and cached on the session - no `git`/shell call on render.
- [ ] (When [remote-ssh](remote-ssh.spec.md) lands) remote-SSH sessions also show the link, fed
      by the sync.

## Open questions

- Resolve-on-ingest cost: `git config --get` is ~ms, but do it off the main thread and cache.
  Confirm it doesn't stall session ingest for repos on slow/network mounts (timeout it).
- Branch-aware deep link - worth a v2? (low effort once host parsing exists; gated on demand.)
