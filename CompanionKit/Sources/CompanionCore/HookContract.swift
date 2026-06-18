import Foundation

// The PreToolUse contract, confirmed empirically against Claude Code 2.1.177 (see
// docs/specs/features/permission-engine.spec.md → "Confirmed hook contract").

/// Payload Claude Code sends on stdin to a hook command.
public struct HookPayload: Decodable, Sendable {
    public let hookEventName: String
    public let sessionId: String?
    public let toolUseId: String?
    public let transcriptPath: String?
    public let cwd: String?
    public let permissionMode: String?
    public let toolName: String?
    public let toolInput: ToolInput?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case toolUseId = "tool_use_id"
        case transcriptPath = "transcript_path"
        case cwd
        case permissionMode = "permission_mode"
        case toolName = "tool_name"
        case toolInput = "tool_input"
    }

    public init(hookEventName: String, sessionId: String? = nil, toolUseId: String? = nil,
                transcriptPath: String? = nil, cwd: String? = nil, permissionMode: String? = nil,
                toolName: String? = nil, toolInput: ToolInput? = nil) {
        self.hookEventName = hookEventName
        self.sessionId = sessionId
        self.toolUseId = toolUseId
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.permissionMode = permissionMode
        self.toolName = toolName
        self.toolInput = toolInput
    }
}

public struct ToolInput: Decodable, Sendable {
    public let command: String?      // Bash
    public let filePath: String?     // Edit/Write/Read
    public let description: String?

    enum CodingKeys: String, CodingKey {
        case command, description
        case filePath = "file_path"
    }

    public init(command: String? = nil, filePath: String? = nil, description: String? = nil) {
        self.command = command
        self.filePath = filePath
        self.description = description
    }
}

public enum PermissionDecision: String, Codable, Sendable {
    case allow, deny, ask
}

/// Exact JSON we print to stdout for a PreToolUse decision.
/// → {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"…","permissionDecisionReason":"…"}}
public struct HookDecisionOutput: Encodable, Sendable {
    public struct Inner: Encodable, Sendable {
        public let hookEventName: String
        public let permissionDecision: PermissionDecision
        public let permissionDecisionReason: String?
        public let updatedInput: [String: String]?   // optional command rewrite (e.g. from rtk)
    }
    public let hookSpecificOutput: Inner

    public init(_ decision: PermissionDecision, reason: String?,
                updatedInput: [String: String]? = nil, event: String = "PreToolUse") {
        hookSpecificOutput = Inner(hookEventName: event,
                                   permissionDecision: decision,
                                   permissionDecisionReason: reason,
                                   updatedInput: updatedInput)
    }
}
