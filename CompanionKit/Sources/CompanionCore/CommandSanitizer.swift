import Foundation

/// Produces the string the rule regexes should match against, so a flagged pattern sitting INSIDE
/// *data* (a quoted string, a comment, or a heredoc payload) doesn't cause a false deny/ask - e.g.
/// `echo "rm -rf /"`, `git commit -m "fixes rm -rf / guard"`, `cmd # rm -rf / later`, or a
/// `cat > /tmp/x <<'JSON' … >> /etc/… … JSON` whose body is just text being written to a file.
///
/// SAFETY: the only ways data can actually execute are command substitution (`$(…)` / backticks),
/// an evaluator consuming the string (`eval`, `sh -c`, `xargs`, …), or a heredoc fed to an
/// interpreter (`bash <<EOF`, `… | sh`). Heredoc bodies are blanked ONLY when they're pure data -
/// a quoted delimiter (no expansion) whose introducing line invokes no interpreter. After that, if
/// any execution-capable construct REMAINS we return the (heredoc-blanked) text unchanged rather
/// than masking its quotes - so a real `sh -c "rm -rf /"` or `$(rm -rf /)` is never hidden. We err,
/// always, toward more matching.
public enum CommandSanitizer {
    nonisolated(unsafe) private static let executable: NSRegularExpression = {
        // command substitution, eval, `…sh -c`, xargs → text inside quotes might run → don't touch.
        try! NSRegularExpression(pattern: #"\$\(|`|\beval\b|\b(?:ba|z|da|k|t?c)?sh\s+-c\b|\bxargs\b"#)
    }()

    // A line carrying one of these EXECUTES a heredoc it opens (directly, e.g. `bash <<EOF`, or via
    // a pipe, e.g. `cat <<EOF | sh`), so that body is code - never blank it.
    nonisolated(unsafe) private static let interpreter: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\b(?:bash|sh|zsh|ksh|dash|csh|tcsh|fish|python|python2|python3|ruby|perl|node|php|osascript|Rscript|lua)\b"#)
    }()

    // A heredoc operator with a QUOTED delimiter only (`<<'EOF'`, `<<"EOF"`, `<<-'EOF'`): a quoted
    // delimiter disables expansion, so the body is literal data. Captures the delimiter name (g2).
    nonisolated(unsafe) private static let quotedHeredocOp: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"<<-?\s*(['"])([A-Za-z_][A-Za-z0-9_]*)\1"#)
    }()

    public static func forMatching(_ command: String) -> String {
        // 1. Blank pure-data heredoc bodies first - even when the command ALSO has a real $()/eval
        //    elsewhere - so a flagged pattern living in heredoc data can't trip a deny.
        let deheredoc = blankDataHeredocs(command)

        // 2. If an execution-capable construct still remains, the rest could run quoted text - leave
        //    it intact (match the original quotes).
        let full = NSRange(deheredoc.startIndex..., in: deheredoc)
        if executable.firstMatch(in: deheredoc, range: full) != nil { return deheredoc }

        // 3. Otherwise blank quoted-string contents + `#` comments (the remaining data).
        return blankQuotesAndComments(deheredoc)
    }

    /// Replace the body lines of pure-data heredocs with blanks. A heredoc is treated as data when
    /// its delimiter is quoted (no expansion) AND its introducing line invokes no interpreter (no
    /// execution). Interpreter-fed or unquoted heredocs are left verbatim - their bodies can execute
    /// or expand, so a flagged pattern there must still match.
    static func blankDataHeredocs(_ command: String) -> String {
        guard command.contains("<<") else { return command }
        let lines = command.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count)
        // FIFO of data-heredoc bodies opened by command lines, consumed in order (stacked heredocs).
        var active: [(delim: String, stripTabs: Bool)] = []
        for line in lines {
            if let cur = active.first {
                let candidate = cur.stripTabs ? String(line.drop(while: { $0 == "\t" })) : line
                if candidate == cur.delim {
                    out.append(line)            // terminator line stays
                    active.removeFirst()
                } else {
                    out.append("")              // body line → blanked (it's data)
                }
                continue
            }
            out.append(line)                    // a real command line: keep it
            let r = NSRange(line.startIndex..., in: line)
            // An interpreter on this line would run any heredoc it opens → its body is code, skip.
            if interpreter.firstMatch(in: line, range: r) != nil { continue }
            quotedHeredocOp.enumerateMatches(in: line, range: r) { m, _, _ in
                guard let m = m, let nameR = Range(m.range(at: 2), in: line),
                      let opR = Range(m.range, in: line) else { return }
                active.append((String(line[nameR]), line[opR].hasPrefix("<<-")))
            }
        }
        return out.joined(separator: "\n")
    }

    /// Blank the contents of quoted strings and `#` comments, keeping the delimiters/structure.
    static func blankQuotesAndComments(_ command: String) -> String {
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
