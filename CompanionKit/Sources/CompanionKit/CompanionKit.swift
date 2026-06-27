import Foundation
import CompanionCore

// CompanionKit - the app library (GRDB-backed store, usage poller, JSONL tailer, cost,
// view models). The thin Xcode @main shell depends on this. Substance lands in later phases
// (P1 SQLite, then session-monitor / usage-limits / cost / menubar-ui).

public enum CompanionKit {
    /// The running app's version - read from the built bundle's CFBundleShortVersionString, which
    /// CI (gitversion via swift-release-action) injects at release time. NOT a hard-coded constant,
    /// so the menu-bar header always reflects the actually-built/tagged version. "dev" for an
    /// un-versioned local build.
    public static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
