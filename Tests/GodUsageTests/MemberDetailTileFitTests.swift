import AppKit
import XCTest
@testable import GodUsage

/// The member detail's tiles are about 115pt wide (two columns in the popover). Labels stay on one
/// line (shrinking at most to `MemberDetailTile`'s 0.8 scale) and contexts wrap to at most two lines,
/// in English and in Italian, with the longest month names and contexts.
final class MemberDetailTileFitTests: XCTestCase {
    /// The narrowest tile's text width: 115pt minus 9pt padding on each side.
    private static let width: CGFloat = 115 - 18
    private static let labelScale: CGFloat = 0.8
    private static var regular: NSFont { NSFont.systemFont(ofSize: 10) }
    private static var semibold: NSFont { NSFont.systemFont(ofSize: 10, weight: .semibold) }

    private func italian() throws -> Bundle {
        let url = try XCTUnwrap(Bundle.godUsageResources.url(forResource: "it", withExtension: "lproj"))
        return try XCTUnwrap(Bundle(url: url))
    }

    private func it(_ key: String, _ args: CVarArg..., bundle: Bundle) -> String {
        String(format: bundle.localizedString(forKey: key, value: nil, table: nil), locale: Locale(identifier: "it"), arguments: args)
    }

    private func assertLabelFits(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let width = (label as NSString).size(withAttributes: [.font: Self.semibold]).width
        XCTAssertLessThanOrEqual(width * Self.labelScale, Self.width, "label cut off: \(label)", file: file, line: line)
    }

    private func assertContextFits(_ context: String, file: StaticString = #filePath, line: UInt = #line) {
        let font = Self.regular
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let rect = (context as NSString).boundingRect(
            with: NSSize(width: Self.width, height: 1000), options: [.usesLineFragmentOrigin], attributes: [.font: font]
        )
        XCTAssertLessThanOrEqual((rect.height / lineHeight).rounded(), 2, "context over two lines: \(context)", file: file, line: line)
    }

    func testEnglishTilesFit() {
        let labels = [
            MemberDetailFormat.lastHourTile(nil).label,
            MemberDetailFormat.paceTile(TeamProjection(spentSoFar: 1, projected: 1, monthName: "September", daysLeft: 30)).label,
            MemberDetailFormat.efficiencyTile(UsageTotals(tokens: 1_000_000, costUSD: 1))?.label ?? "",
            MemberDetailFormat.placeTile(rank: 12, of: 20, rankChange: 0, hasUsage: true, range: .today).label,
        ]
        labels.forEach { assertLabelFits($0) }

        var contexts = [
            MemberDetailFormat.momentumContext(TeamMomentum(lastHourUSD: 30, level: 1, reasons: ["fast", "top"])),
            MemberDetailFormat.momentumContext(TeamMomentum(lastHourUSD: 30, level: 3, reasons: ["fast", "self", "top"])),
            MemberDetailFormat.efficiencyTile(UsageTotals(tokens: 1_000_000, costUSD: 1))?.context ?? "",
            MemberDetailFormat.paceTile(TeamProjection(spentSoFar: 1, projected: 1, monthName: "September", daysLeft: 30)).context,
        ]
        for range in [StatsRange.today, .week, .month, .monthToDate] {
            for change in [-12, 0, 12] {
                contexts.append(MemberDetailFormat.movementText(rankChange: change, hasUsage: true, range: range) ?? "")
            }
        }
        contexts.forEach { assertContextFits($0) }
    }

    func testItalianTilesFit() throws {
        let bundle = try italian()
        let labels = [
            it("LAST HOUR", bundle: bundle),
            it("BY END OF %@", "SETTEMBRE", bundle: bundle),
            it("EFFICIENCY", bundle: bundle),
            it("PLACE", bundle: bundle),
        ]
        XCTAssertEqual(labels[1], "A FINE SETTEMBRE")
        labels.forEach { assertLabelFits($0) }

        let contexts = [
            it("%@ · top of the team", it("Picking up", bundle: bundle), bundle: bundle),
            it("%@ · top of the team", it("Very fast", bundle: bundle), bundle: bundle),
            it("Normal pace", bundle: bundle),
            it("per 1M tokens", bundle: bundle),
            it("%lld days left", 30, bundle: bundle),
            it("Same as yesterday", bundle: bundle),
            it("Up %lld since yesterday", 12, bundle: bundle),
            it("Down %lld since yesterday", 12, bundle: bundle),
            it("Same as the previous 7 days", bundle: bundle),
            it("Up %lld since the previous 7 days", 12, bundle: bundle),
            it("Down %lld since the previous 7 days", 12, bundle: bundle),
            it("Same as the previous 30 days", bundle: bundle),
            it("Up %lld since the previous 30 days", 12, bundle: bundle),
            it("Down %lld since the previous 30 days", 12, bundle: bundle),
            it("Same as last month", bundle: bundle),
            it("Up %lld since last month", 12, bundle: bundle),
            it("Down %lld since last month", 12, bundle: bundle),
        ]
        XCTAssertEqual(contexts[1], "Molto veloce · il più alto")
        XCTAssertEqual(contexts[3], "per 1M token")
        contexts.forEach { assertContextFits($0) }
    }
}
