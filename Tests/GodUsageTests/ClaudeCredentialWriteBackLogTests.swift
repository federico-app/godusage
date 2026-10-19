import XCTest
@testable import GodUsage

/// A failed write-back must say why in the log (exit code and the helper's output), without the
/// credential it tried to write.
final class ClaudeCredentialWriteBackLogTests: XCTestCase {
    func testFailureDetailIncludesExitCodeAndHelperOutput() {
        let result = ProcessResult(
            exitCode: 45,
            stdout: "",
            stderr: "security: SecKeychainItemModifyContent: User interaction is not allowed.\n"
        )

        let detail = ClaudeCredentialWriteBack.failureDetail(result, secrets: ["{\"token\":\"x\"}"])

        XCTAssertEqual(detail, "exit 45, security: SecKeychainItemModifyContent: User interaction is not allowed.")
    }

    func testFailureDetailRedactsTheCredential() {
        let blob = "{\"claudeAiOauth\":{\"accessToken\":\"sk-secret\"}}"
        let result = ProcessResult(exitCode: 1, stdout: "", stderr: "bad input: \(blob)")

        let detail = ClaudeCredentialWriteBack.failureDetail(result, secrets: [blob])

        XCTAssertFalse(detail.contains("sk-secret"))
        XCTAssertEqual(detail, "exit 1, bad input: <redacted>")
    }

    func testFailureDetailWithoutOutputReportsOnlyExitCode() {
        let detail = ClaudeCredentialWriteBack.failureDetail(
            ProcessResult(exitCode: 2, stdout: "", stderr: "  \n"),
            secrets: []
        )

        XCTAssertEqual(detail, "exit 2")
    }
}
