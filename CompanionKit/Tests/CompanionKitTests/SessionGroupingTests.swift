import Foundation
import Testing
@testable import CompanionKit

struct SessionGroupingTests {
    private func session(_ id: String, path: String?, name: String, model: String?,
                         tools: Int, inTok: Int = 0, outTok: Int = 0, cache: Int = 0,
                         cost: Double? = nil, seen: Date?, active: Bool = true,
                         recent: [String] = [], host: String = "local",
                         working: String? = nil, repo: URL? = nil) -> SessionSummary {
        SessionSummary(id: id, projectName: name, model: model, toolCount: tools,
                       inputTokens: inTok, outputTokens: outTok, cacheTokens: cache, costUSD: cost,
                       projectPath: path, startedAt: nil, lastSeen: seen, active: active,
                       recentTools: recent, repoURL: repo, host: host, workingPath: working)
    }

    @Test func aggregatesMembersOfSameProject() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let s = [
            session("a", path: "/code/vega", name: "vega", model: "opus", tools: 245, inTok: 65_000,
                    outTok: 726_000, cost: 318.61, seen: t0.addingTimeInterval(10), recent: ["Bash"]),
            session("b", path: "/code/vega", name: "vega", model: "opus", tools: 475, inTok: 203_000,
                    outTok: 1_100_000, cost: 620.17, seen: t0.addingTimeInterval(30)),
            session("c", path: "/code/vega", name: "vega", model: "haiku", tools: 132, inTok: 76_000,
                    outTok: 308_000, cost: 89.10, seen: t0.addingTimeInterval(20)),
        ]
        let groups = SessionGrouping.groupByProject(s)
        #expect(groups.count == 1)
        let g = groups[0]
        #expect(g.sessionCount == 3)
        #expect(g.toolCount == 245 + 475 + 132)
        #expect(g.inputTokens == 65_000 + 203_000 + 76_000)
        #expect(abs((g.costUSD ?? 0) - (318.61 + 620.17 + 89.10)) < 0.001)
        // newest member (b, +30s) drives projectName/recentTools order; distinct models newest-first
        #expect(g.models == ["opus", "haiku"])
        #expect(g.sessions.first?.id == "b")
    }

    @Test func samedLeafNameDifferentPathStaySeparate() {
        let now = Date(timeIntervalSince1970: 2_000)
        let s = [
            session("a", path: "/code/one/vega", name: "vega", model: "opus", tools: 1, seen: now),
            session("b", path: "/code/two/vega", name: "vega", model: "opus", tools: 1, seen: now),
        ]
        #expect(SessionGrouping.groupByProject(s).count == 2)
    }

    @Test func groupsOrderedByLatestActivity() {
        let t0 = Date(timeIntervalSince1970: 3_000)
        let s = [
            session("old", path: "/code/a", name: "a", model: "opus", tools: 1, seen: t0),
            session("new", path: "/code/b", name: "b", model: "opus", tools: 1, seen: t0.addingTimeInterval(100)),
        ]
        let groups = SessionGrouping.groupByProject(s)
        #expect(groups.first?.projectName == "b")   // most recent first
    }

    @Test func costNilWhenNoMemberPriced() {
        let now = Date(timeIntervalSince1970: 4_000)
        let s = [session("a", path: "/code/x", name: "x", model: nil, tools: 2, cost: nil, seen: now)]
        #expect(SessionGrouping.groupByProject(s).first?.costUSD == nil)
    }

    @Test func workingDirectoryFromEditedFiles() {
        let root = "/Users/m/code/one-b2c"
        let edits = [
            "/tmp/scratch/notes.md",                                   // scratch → ignored, not "broad"
            root + "/platform/vega/README.md",
            root + "/platform/vega/research/x.md",
            root + "/platform/vega/CLAUDE.md",
        ]
        #expect(SessionGrouping.workingDirectory(projectPath: root, editPaths: edits)
                == root + "/platform/vega")
    }

    @Test func broadSessionEditingAnotherRepoKeepsCwd() {
        // The real bug: launched at ~/code/personal, but edits land in another repo too. Don't
        // mislabel the whole session as the one subfolder under cwd it happens to touch.
        let cwd = "/Users/m/code/personal"
        let edits = [
            cwd + "/vitepress/post.md",
            "/Users/m/code/one-b2c/platform/auto-diagrams/x.md",      // real edit outside cwd
        ]
        #expect(SessionGrouping.workingDirectory(projectPath: cwd, editPaths: edits) == nil)
    }

    @Test func scratchEditsOutsideCwdDoNotMarkBroad() {
        let cwd = "/Users/m/code/one-b2c"
        let edits = [cwd + "/platform/vega/a.md", "/tmp/run.sh"]      // /tmp is scratch, ignored
        #expect(SessionGrouping.workingDirectory(projectPath: cwd, editPaths: edits)
                == cwd + "/platform/vega")
    }

    @Test func workingDirectoryNilWhenOnlyRootOrOutside() {
        let root = "/Users/m/code/one-b2c"
        // edits at the root itself → no deeper subfolder
        #expect(SessionGrouping.workingDirectory(projectPath: root,
                editPaths: [root + "/README.md", root + "/CLAUDE.md"]) == nil)
        // nothing inside the project (all scratch) → nil (fall back to cwd)
        #expect(SessionGrouping.workingDirectory(projectPath: root,
                editPaths: ["/tmp/a.md"]) == nil)
    }

    @Test func groupingSplitsMonorepoRootByWorkingSubfolder() {
        let now = Date(timeIntervalSince1970: 6_000)
        let root = "/code/one-b2c"
        let s = [
            session("a", path: root, name: "vega", model: "opus", tools: 5, seen: now,
                    working: root + "/platform/vega"),
            session("b", path: root, name: "foo", model: "opus", tools: 5, seen: now,
                    working: root + "/satellites/foo"),
        ]
        let groups = SessionGrouping.groupByProject(s)
        #expect(groups.count == 2)
        #expect(Set(groups.map(\.projectName)) == ["vega", "foo"])   // split by working subfolder
        #expect(Set(groups.map(\.id)) == [root + "/platform/vega", root + "/satellites/foo"])
    }

    @Test func singleSessionGroupIntact() {
        let now = Date(timeIntervalSince1970: 5_000)
        let url = URL(string: "https://github.com/me/solo")!
        let s = [session("a", path: "/code/solo", name: "solo", model: "opus", tools: 9,
                         cost: 1.5, seen: now, recent: ["Read", "Edit"], repo: url)]
        let g = SessionGrouping.groupByProject(s)
        #expect(g.count == 1)
        #expect(g[0].sessionCount == 1)
        #expect(g[0].toolCount == 9)
        #expect(g[0].recentTools == ["Read", "Edit"])
        #expect(g[0].repoURL == url)   // repo link surfaces on the group card
    }
}
