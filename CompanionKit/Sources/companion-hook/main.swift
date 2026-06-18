import Foundation
import CompanionCore

// companion-hook - invoked by Claude Code's PreToolUse hook per tool call. Reads the payload on
// stdin, evaluates against compiled rules + the cached blocklist, prints the decision, appends an
// audit line, exits. Standalone: NO daemon, NO socket, NO network. Works even when the app is quit.
// Coexists with other hooks (e.g. rtk's command-rewrite hook) as a separate entry.
//
// Fail-safe: anything unexpected (unreadable payload, missing rules) → "ask" (defer to Claude
// Code's native prompt). A broken companion must NEVER silently widen permissions, and "ask"
// returns instantly so it can't decay into "allow" via a hook block-timeout.

let rulesPath = Paths.rulesCompiled
let auditPath = Paths.auditLog

func emit(_ decision: PermissionDecision, reason: String?) -> Never {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys // deterministic output
    if let data = try? encoder.encode(HookDecisionOutput(decision, reason: reason)) {
        FileHandle.standardOutput.write(data)
    }
    exit(0)
}

let input = FileHandle.standardInput.readDataToEndOfFile()

guard let payload = try? JSONDecoder().decode(HookPayload.self, from: input) else {
    emit(.ask, reason: "companion: unreadable hook payload")
}

// Only PreToolUse yields a decision. Other events (PostToolUse/SessionStart/Stop) just exit.
guard payload.hookEventName == "PreToolUse" else {
    exit(0)
}

guard let rulesData = FileManager.default.contents(atPath: rulesPath),
      let rules = try? JSONDecoder().decode(CompiledRules.self, from: rulesData) else {
    emit(.ask, reason: "companion: rules unavailable")
}

// Load the blocklist only when the command actually references a host - keeps the common
// (no-URL) case free of file IO.
var blocklist: Blocklist?
if let cmd = payload.toolInput?.command, !URLExtractor.hosts(in: cmd).isEmpty {
    blocklist = Blocklist.load(path: Paths.blocklist)
}

let result = RuleEngine.evaluate(payload, rules: rules, blocklist: blocklist)

// Best-effort audit (never blocks or fails the decision).
let entry = AuditEntry(
    ts: ISO8601DateFormatter().string(from: Date()),
    sessionId: payload.sessionId,
    tool: payload.toolName,
    command: payload.toolInput?.command,
    decision: result.decision.rawValue,
    ruleMatched: result.ruleMatched
)
AuditWriter.append(entry, toPath: auditPath)

emit(result.decision, reason: result.reason)
