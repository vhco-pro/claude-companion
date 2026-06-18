import Foundation
import CompanionCore

// CompanionKit - the app library (GRDB-backed store, usage poller, JSONL tailer, cost,
// view models). The thin Xcode @main shell depends on this. Substance lands in later phases
// (P1 SQLite, then session-monitor / usage-limits / cost / menubar-ui).

public enum CompanionKit {
    public static let version = "0.1.0"
}
