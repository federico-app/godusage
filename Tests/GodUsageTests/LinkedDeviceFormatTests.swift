import XCTest
@testable import GodUsage

final class LinkedDeviceFormatTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    func testDecodesTheDetailsTheServerSends() throws {
        let json = """
        {"id":"h1","name":"iPhone","linkedAt":"2026-11-01T10:00:00.000Z","model":"iPhone 13","osVersion":"26.1","appVersion":"1.10.1","lastSeenAt":"2026-11-18T09:00:00.000Z"}
        """
        let device = try JSONDecoder().decode(LinkedDevice.self, from: Data(json.utf8))
        XCTAssertEqual(device.model, "iPhone 13")
        XCTAssertEqual(device.osVersion, "26.1")
        XCTAssertEqual(device.appVersion, "1.10.1")
        XCTAssertEqual(device.lastSeenAt, "2026-11-18T09:00:00.000Z")
    }

    func testDecodesDevicesWithoutDetailsAndNulls() throws {
        let missing = try JSONDecoder().decode(LinkedDevice.self, from: Data(#"{"id":"h1","name":"iPhone","linkedAt":"2026-11-01T10:00:00.000Z"}"#.utf8))
        XCTAssertEqual(missing, LinkedDevice(id: "h1", name: "iPhone", linkedAt: "2026-11-01T10:00:00.000Z"))
        let nulls = try JSONDecoder().decode(
            LinkedDevice.self,
            from: Data(#"{"id":"h1","name":"iPhone","linkedAt":"2026-11-01T10:00:00.000Z","model":null,"osVersion":null,"appVersion":null,"lastSeenAt":null}"#.utf8)
        )
        XCTAssertEqual(nulls, missing)
    }

    func testTitleShowsModelAndSystemOrFallsBackToTheName() {
        var device = LinkedDevice(id: "h1", name: "iPhone", linkedAt: iso(now))
        XCTAssertEqual(LinkedDeviceFormat.title(device), "iPhone")
        device.model = "iPhone 13"
        XCTAssertEqual(LinkedDeviceFormat.title(device), "iPhone 13")
        device.osVersion = "26.1"
        XCTAssertEqual(LinkedDeviceFormat.title(device), "iPhone 13 · iOS 26.1")
        device.model = "iPad Pro 11-inch (M4)"
        XCTAssertEqual(LinkedDeviceFormat.title(device), "iPad Pro 11-inch (M4) · iPadOS 26.1")
    }

    func testSubtitleLeavesOutWhatTheDeviceNeverReported() {
        let linked = now.addingTimeInterval(-3 * 86_400)
        var device = LinkedDevice(id: "h1", name: "iPhone", linkedAt: iso(linked))
        let date = Formatters.monthDayLabel(linked)
        XCTAssertEqual(LinkedDeviceFormat.subtitle(device, now: now), "Linked on \(date)")
        device.lastSeenAt = iso(now.addingTimeInterval(-5 * 60))
        device.appVersion = "1.10.1"
        XCTAssertEqual(LinkedDeviceFormat.subtitle(device, now: now), "Linked on \(date) · Last active 5m ago · GodUsage 1.10.1")
    }

    func testLastActiveSteps() {
        XCTAssertEqual(LinkedDeviceFormat.lastActive(now.addingTimeInterval(-20), now: now), "Last active just now")
        XCTAssertEqual(LinkedDeviceFormat.lastActive(now.addingTimeInterval(-59 * 60), now: now), "Last active 59m ago")
        XCTAssertEqual(LinkedDeviceFormat.lastActive(now.addingTimeInterval(-3 * 3600), now: now), "Last active 3h ago")
        XCTAssertEqual(LinkedDeviceFormat.lastActive(now.addingTimeInterval(-50 * 3600), now: now), "Last active 2d ago")
        // A clock slightly behind the server's never shows a negative age.
        XCTAssertEqual(LinkedDeviceFormat.lastActive(now.addingTimeInterval(120), now: now), "Last active just now")
    }
}
