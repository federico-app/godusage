import XCTest
@testable import GodUsage

final class TeamScheduleTests: XCTestCase {
    func testTheStandardScheduleIsFine() {
        XCTAssertNil(TeamSchedule.standard.problem)
        XCTAssertEqual(TeamSchedule.standard.weeklyHours, 45)
    }

    func testABreakIsTakenOffEveryWorkingDay() {
        let schedule = TeamSchedule(days: [1, 2, 3], start: 9 * 60, end: 18 * 60, breakStart: 13 * 60, breakEnd: 13 * 60 + 30)
        XCTAssertNil(schedule.problem)
        XCTAssertEqual(schedule.weeklyHours, 25.5)
    }

    func testProblemsNameWhatTheServerWouldRefuse() {
        XCTAssertEqual(TeamSchedule(days: [], start: 540, end: 1080).problem, "Pick at least one working day.")
        XCTAssertEqual(TeamSchedule(days: [1], start: 600, end: 600).problem, "The working hours must end after they start.")
        let outside = "The break must fall inside the working hours."
        XCTAssertEqual(TeamSchedule(days: [1], start: 540, end: 1080, breakStart: 540, breakEnd: 600).problem, outside)
        XCTAssertEqual(TeamSchedule(days: [1], start: 540, end: 1080, breakStart: 1000, breakEnd: 1080).problem, outside)
        XCTAssertEqual(TeamSchedule(days: [1], start: 540, end: 1080, breakStart: 800, breakEnd: 780).problem, outside)
    }

    func testClockAndTimeZoneCity() {
        XCTAssertEqual(TeamSchedule.clock(9 * 60), "9:00")
        XCTAssertEqual(TeamSchedule.clock(13 * 60 + 5), "13:05")
        XCTAssertEqual(TeamWorkingHoursSection.city("America/New_York"), "New York")
        XCTAssertNil(TeamWorkingHoursSection.city(nil))
    }
}
