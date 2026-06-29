import Foundation

/// Produces the string the rule regexes should match against, so a flagged pattern sitting INSIDE
/// quoted *data* (or a comment) doesn't cause a false deny/ask - e.g. `echo "rm -rf /"`,
/// `git commit -m "fixes rm -rf / guard"`, `gh pr create --body "...git push --force..."`,
/// `cmd # rm -rf / later`. Text inside quotes is data, not execution.
///
/// SAFETY: the only ways quoted text can actually execute are command substitution (`$(…)` /
/// backticks) or an evaluator consuming the string (`eval`, `sh -c`, `xargs`, …). If ANY such
/// construct is present we return the command UNCHANGED (match the original), so a real
/// `sh -c "rm -rf /"` or `$(rm -rf /)` is never masked. We only ever sanitize commands with no
/// execution-capable construct - erring, always, toward more matching.
public enum CommandSanitizer {
    nonisolated(unsafe) private static let executable: NSRegularExpression = {
        // command substitution, eval, `…sh -c`, xargs → text inside quotes might run → don't touch.
        try! NSRegularExpression(pattern: #"\$\(|`|\beval\b|\b(?:ba|z|da|k|t?c)?sh\s+-c\b|\bxargs\b"#)
    }()

    public static func forMatching(_ command: String) -> String {
        let full = NSRange(command.startIndex..., in: command)
        if executable.firstMatch(in: command, range: full) != nil { return command }

        var out = ""
        out.reserveCapacity(command.count)
        var quote: Character? = nil
        var atWordStart = true        // a `#` at a word start (outside quotes) begins a comment
        var i = command.startIndex
        while i < command.endIndex {
            let c = command[i]
            if let q = quote {                      // inside a quote: drop literal data, keep the quotes
                if c == q { quote = nil; out.append(c) }
                i = command.index(after: i)
                continue
            }
            if c == "'" || c == "\"" {              // open a quote (kept; contents blanked)
                quote = c; out.append(c); atWordStart = false; i = command.index(after: i); continue
            }
            if c == "#" && atWordStart {             // line comment → drop to EOL
                while i < command.endIndex && command[i] != "\n" { i = command.index(after: i) }
                continue
            }
            out.append(c)
            atWordStart = c == " " || c == "\t" || c == "\n" || c == ";" || c == "|" || c == "&" || c == "("
            i = command.index(after: i)
        }
        return out
    }
}
