import XCTest
@testable import GodUsage

/// Antigravity 2.34 starts its language server with `--read_host_bridge_token_from_stdin` instead of
/// `--csrf_token`, and publishes the token in `~/.gemini/antigravity/daemon/hub_<port>.json`.
/// Regression: without reading that file the local server was never used and every refresh went to
/// Cloud Code.
final class AntigravityHubDiscoveryTests: XCTestCase {
    private static let hubDirectory = "/hub"
    private static let psLine = "54342 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone "
        + "--override_ide_name antigravity --subclient_type hub --override_ide_version 2.34.0 --https_server_port 0 "
        + "--app_data_dir antigravity --host_bridge_url=http://127.0.0.1:62620 --read_host_bridge_token_from_stdin\n"
    private static let lsof = """
    language_ 54342 user 7u IPv4 0x0 0t0 TCP 127.0.0.1:62621 (LISTEN)
    language_ 54342 user 8u IPv4 0x0 0t0 TCP 127.0.0.1:62622 (LISTEN)

    """

    private static func hub(pid: Int, token: String = "hub-token") -> String {
        #"{"pid":\#(pid),"httpsPort":62621,"httpPort":62622,"lsVersion":"2.34.0","csrfToken":"\#(token)"}"#
    }

    private static let options = LanguageServerDiscovery.Options(
        processName: "language_server",
        markers: ["antigravity", "antigravity-ide"],
        csrfFlag: "--csrf_token",
        portFlag: "--extension_server_port",
        hubDirectory: hubDirectory
    )

    private func discovery(files: [String: String]) -> LanguageServerDiscovery {
        LanguageServerDiscovery(processRunner: HubProcessRunner(ps: Self.psLine, lsof: Self.lsof), files: FakeFiles(files))
    }

    func testParseHubFile() {
        XCTAssertEqual(LanguageServerDiscovery.parseHubFile(Self.hub(pid: 7)), .init(pid: 7, csrfToken: "hub-token"))
        XCTAssertNil(LanguageServerDiscovery.parseHubFile(Self.hub(pid: 7, token: " ")))
        XCTAssertNil(LanguageServerDiscovery.parseHubFile(#"{"pid":7}"#))
        XCTAssertNil(LanguageServerDiscovery.parseHubFile("not json"))
    }

    func testTokenComesFromTheHubFileOfTheRunningProcess() {
        let outcome = discovery(files: ["/hub/hub_62622.json": Self.hub(pid: 54342)]).discoverOutcome(Self.options)
        guard case .found(let result) = outcome else { return XCTFail("expected a server, got \(outcome)") }
        XCTAssertEqual(result.csrf, "hub-token")
        XCTAssertEqual(result.ports, [62621, 62622])
    }

    func testStaleHubFileFromAnotherPidIsIgnored() {
        let outcome = discovery(files: ["/hub/hub_62622.json": Self.hub(pid: 111)]).discoverOutcome(Self.options)
        guard case .indeterminate = outcome else { return XCTFail("expected indeterminate, got \(outcome)") }
    }

    func testWithoutHubDirectoryAMissingFlagStillSkipsTheProcess() {
        var options = Self.options
        options.hubDirectory = nil
        let outcome = discovery(files: ["/hub/hub_62622.json": Self.hub(pid: 54342)]).discoverOutcome(options)
        guard case .indeterminate = outcome else { return XCTFail("expected indeterminate, got \(outcome)") }
    }

    @MainActor
    func testProviderPointsAtAntigravityDaemonDirectory() {
        XCTAssertEqual(AntigravityProvider.hubDirectory, "~/.gemini/antigravity/daemon")
    }
}

private struct HubProcessRunner: ProcessRunning {
    let ps: String
    let lsof: String

    func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: executable.hasSuffix("/ps") ? ps : lsof, stderr: "")
    }
}
