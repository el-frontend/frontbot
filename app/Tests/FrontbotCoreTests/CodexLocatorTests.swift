import XCTest
@testable import FrontbotCore

final class CodexLocatorTests: XCTestCase {
    func testFindsCodexFromPathUsingInjectedCandidatesAndExistsCheck() {
        let location = CodexLocator.locate(
            environment: ["PATH": "/custom/bin:/usr/bin"],
            candidatePaths: ["/Applications/Codex.app/bin/codex"],
            exists: { ["/custom/bin/codex", "/Applications/Codex.app/bin/codex"].contains($0) }
        )

        XCTAssertEqual(location, "/custom/bin/codex")
    }

    func testFindsCodexFromSupportedCandidateWhenPathHasNoExecutable() {
        let location = CodexLocator.locate(
            environment: ["PATH": "/missing"],
            candidatePaths: ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"],
            exists: { $0 == "/usr/local/bin/codex" }
        )

        XCTAssertEqual(location, "/usr/local/bin/codex")
    }

    func testFindsCodexFromNVMVersionInstallOutsideGUIPath() {
        let home = "/Users/example"
        let location = CodexLocator.locate(
            environment: ["HOME": home, "PATH": "/usr/bin"],
            nvmNodeVersions: ["v22.11.0", "v20.18.0"],
            exists: { $0 == "\(home)/.nvm/versions/node/v22.11.0/bin/codex" }
        )

        XCTAssertEqual(location, "\(home)/.nvm/versions/node/v22.11.0/bin/codex")
    }

    func testReportsMissingCLIWithoutRunningLoginCheck() {
        let status = CodexLocator.status(
            environment: [:],
            candidatePaths: [],
            exists: { _ in false },
            loginCheck: { _ in XCTFail("Login check should not run without a CLI"); return .unavailable }
        )

        XCTAssertEqual(status, .notInstalled)
    }

    func testMapsLoginCheckToSignedInAndSignedOutStates() {
        let signedIn = CodexLocator.status(
            environment: [:], candidatePaths: ["/opt/codex"], exists: { $0 == "/opt/codex" },
            loginCheck: { _ in .signedIn }
        )
        let signedOut = CodexLocator.status(
            environment: [:], candidatePaths: ["/opt/codex"], exists: { $0 == "/opt/codex" },
            loginCheck: { _ in .signedOut }
        )

        XCTAssertEqual(signedIn, .available(executable: "/opt/codex"))
        XCTAssertEqual(signedOut, .notSignedIn(executable: "/opt/codex"))
    }
}
