import Foundation

/// Detects Bash commands whose *effect* runs on another host - `aws ssm send-command`, an
/// interactive SSM session, or `ssh host <command>`. Used by the engine to reclassify a matched
/// local-filesystem `deny` (tagged `remote_overridable`) down to the human-approval (`confirm`)
/// tier: the flagged path/redirect describes the REMOTE box, not this Mac, so a human should
/// approve rather than be hard-walled. See human-override-remote-awareness.spec.md §3.
///
/// Deliberately CONSERVATIVE: over-detection would soften a genuinely-local deny, so ambiguous
/// forms (bare `ssh host`, `scp`, port-forward-only sessions) are NOT flagged - they fall through
/// to normal tiering. Under-detection just keeps the hard deny, which is the safe direction.
public enum RemoteExec {
    // `aws ssm send-command …` always runs a remote command document. `start-session` is remote-exec
    // only with the interactive-command document (plain sessions / port-forwarding run nothing).
    nonisolated(unsafe) private static let ssm: NSRegularExpression = {
        try! NSRegularExpression(pattern:
            #"\baws\s+ssm\s+send-command\b|\baws\s+ssm\s+start-session\b[^|;&]*AWS-StartInteractiveCommand"#)
    }()

    // `ssh [opts] [user@]host <remote-command>`: a quoted remote command (`ssh host 'script'`), or a
    // host followed by a non-option word (`ssh host ls`). A bare `ssh host` / `ssh -t host` (no
    // trailing command token) runs an interactive shell unattended-of-nothing → NOT flagged.
    nonisolated(unsafe) private static let ssh: NSRegularExpression = {
        // Host must start with an alnum/underscore (not a dash) so an option like `-t` is not
        // mistaken for the host with the real host as its "command" (ssh -t box → interactive).
        try! NSRegularExpression(pattern:
            #"\bssh\s+(?:-\w+\s+|-o\s+\S+\s+)*(?:\S+@)?[A-Za-z0-9_][\w.-]*\s+(?:['"].+|[^-\s]\S*)"#)
    }()

    public static func isRemoteExec(_ command: String) -> Bool {
        let range = NSRange(command.startIndex..., in: command)
        return ssm.firstMatch(in: command, range: range) != nil
            || ssh.firstMatch(in: command, range: range) != nil
    }
}
