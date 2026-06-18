import XCTest
@testable import CompanionCore

final class RepoURLTests: XCTestCase {
    private func assertWeb(_ input: String, _ expected: String,
                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(RepoURL.web(from: input)?.absoluteString, expected, input, file: file, line: line)
    }

    func testGitHub() {
        assertWeb("git@github.com:owner/repo.git", "https://github.com/owner/repo")
        assertWeb("https://github.com/owner/repo.git", "https://github.com/owner/repo")
        assertWeb("https://github.com/owner/repo", "https://github.com/owner/repo")
        assertWeb("ssh://git@github.com/owner/repo.git", "https://github.com/owner/repo")
    }

    func testGitLabNestedGroups() {
        assertWeb("git@gitlab.com:group/sub/repo.git", "https://gitlab.com/group/sub/repo")
        assertWeb("https://gitlab.com/group/sub/repo.git", "https://gitlab.com/group/sub/repo")
    }

    func testBitbucket() {
        assertWeb("git@bitbucket.org:owner/repo.git", "https://bitbucket.org/owner/repo")
    }

    func testAzureDevOps() {
        // SSH scp form: v3/{org}/{project}/{repo}
        assertWeb("git@ssh.dev.azure.com:v3/org/project/repo",
                  "https://dev.azure.com/org/project/_git/repo")
        // https form already carries _git
        assertWeb("https://org@dev.azure.com/org/project/_git/repo",
                  "https://dev.azure.com/org/project/_git/repo")
    }

    func testSelfHostedKeepsItsOwnHost() {
        assertWeb("git@git.acme.internal:team/service.git", "https://git.acme.internal/team/service")
        assertWeb("https://git.acme.internal/team/service.git", "https://git.acme.internal/team/service")
    }

    func testStripsEmbeddedCredentials() {
        assertWeb("https://x-access-token:REDACTED@github.com/owner/repo.git",
                  "https://github.com/owner/repo")
        assertWeb("https://user@github.com/owner/repo.git", "https://github.com/owner/repo")
    }

    func testStripsPortAndLowercasesHost() {
        assertWeb("ssh://git@GitHub.com:22/owner/repo.git", "https://github.com/owner/repo")
    }

    func testUnparseableReturnsNil() {
        XCTAssertNil(RepoURL.web(from: ""))
        XCTAssertNil(RepoURL.web(from: "   "))
        XCTAssertNil(RepoURL.web(from: "not a url"))
        XCTAssertNil(RepoURL.web(from: "github.com"))            // bare host, no path/colon
        XCTAssertNil(RepoURL.web(from: "git@github.com:"))       // host but empty path
        XCTAssertNil(RepoURL.web(from: "https://github.com/"))   // no path
    }
}
