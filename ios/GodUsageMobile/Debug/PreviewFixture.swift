#if DEBUG
import Foundation

/// Sample data for screenshots: launch a Debug build with `-fixture YES` (and `-startTab you` for the
/// You tab). The data is JSON in the server's shapes, so it also exercises the decoders. Never in
/// Release builds.
enum PreviewFixture {
    @MainActor
    static func model() -> TeamsModel {
        let model = TeamsModel()
        guard UserDefaults.standard.bool(forKey: "fixture") else { return model }
        do {
            try apply(to: model, now: Date())
        } catch {
            fatalError("The preview fixture doesn't decode: \(error)")
        }
        return model
    }

    @MainActor
    static func apply(to model: TeamsModel, now: Date) throws {
        let calendar = Calendar.current
        func day(_ offset: Int) -> String { TeamsFormat.localToday(calendar.date(byAdding: .day, value: offset, to: now)!) }
        func iso(_ hours: Double) -> String { now.addingTimeInterval(hours * 3600).formatted(.iso8601) }
        let today = day(0)
        let weekday = (calendar.component(.weekday, from: now) + 5) % 7 // Monday = 0
        let week = (0..<7).map { day($0 - weekday) }
        let monthStart = String(today.prefix(8)) + "01"

        let usageDays = (0..<30).map { index -> String in
            let offset = index - 29
            let claude = offset == 0 ? 14.93 : Double((index * 7) % 11) * 1.9
            let codex = offset == 0 ? 0 : Double((index * 5) % 7) * 0.8
            return """
            {"day":"\(day(offset))","tokens":\(Int((claude + codex) * 90_000)),"costUSD":\(claude + codex),
             "providers":[{"provider":"claude","tokens":\(Int(claude * 80_000)),"costUSD":\(claude)},{"provider":"codex","tokens":\(Int(codex * 100_000)),"costUSD":\(codex)}]}
            """
        }
        let usage = """
        {"from":"\(day(-29))","to":"\(today)","days":[\(usageDays.joined(separator: ","))],
         "providers":[{"provider":"claude","tokens":30000000,"costUSD":301.2},{"provider":"codex","tokens":9000000,"costUSD":61.4}],
         "lastSyncAt":"\(iso(-0.1))"}
        """

        func member(_ id: String, _ name: String, rank: Int, cost: Double, previous: Int?, sync: Double, claudeShare: Double = 0.8) -> String {
            let previousJSON = previous.map { #"{"rank":\#($0),"tokens":1,"costUSD":1}"# } ?? "null"
            return """
            {"userID":"\(id)","displayName":"\(name)","rank":\(rank),"tokens":\(Int(cost * 70_000)),"costUSD":\(cost),
             "providers":[{"provider":"claude","tokens":1,"costUSD":\(cost * claudeShare)},{"provider":"codex","tokens":1,"costUSD":\(cost * (1 - claudeShare))}],
             "previous":\(previousJSON),"lastSyncAt":"\(iso(-sync))"}
            """
        }
        let members = [
            member("u-federico", "Federico", rank: 1, cost: 8.18, previous: 2, sync: 0.05),
            member("u-andrea", "Andrea", rank: 2, cost: 4.21, previous: 1, sync: 0.2, claudeShare: 1),
            member("u-matteo", "Matteo", rank: 3, cost: 1.20, previous: nil, sync: 3, claudeShare: 0.5),
            member("u-giulia", "Giulia", rank: 4, cost: 0, previous: 3, sync: 13 * 24 + 2),
        ]
        func board(from: String, total: Double, members: [String]) -> String {
            """
            {"range":{"name":"today","from":"\(from)","to":"\(today)"},"totals":{"tokens":951300,"costUSD":\(total)},
             "members":[\(members.joined(separator: ","))],
             "providers":[{"provider":"claude","tokens":800000,"costUSD":11.2},{"provider":"codex","tokens":151300,"costUSD":2.39}],
             "models":[{"model":"claude-opus-4-5","provider":"claude","tokens":600000,"costUSD":10.1},{"model":"gpt-5-codex","provider":"codex","tokens":151300,"costUSD":2.39}],
             "daily":[{"day":"\(today)","providers":[{"provider":"claude","tokens":800000,"costUSD":11.2}]}]}
            """
        }
        let stats = """
        {"team":{"id":"t1","name":"Appload"},"stats":\(board(from: today, total: 13.59, members: members)),
         "momentum":{"u-federico":{"lastHourUSD":8.18,"level":2}},
         "champions":[{"month":"\(String(day(-calendar.component(.day, from: now)).prefix(7)))","userID":"u-andrea","displayName":"Andrea","costUSD":812}],
         "extra":{"mtd":\(board(from: monthStart, total: 1_664.3, members: []))}}
        """

        func days(_ percents: [Double?]) -> String {
            week.enumerated().map { index, key in
                let percent = index < percents.count ? percents[index] : nil
                return #"{"day":"\#(key)","percent":\#(percent.map { "\($0)" } ?? "null"),"working":\#(index < 5),"estimated":false}"#
            }.joined(separator: ",")
        }
        let future = week.enumerated().filter { $0.element > today && $0.offset < 5 }.map { #"{"day":"\#($0.element)","hours":8}"# }.joined(separator: ",")
        func pace(budget: Double, used: Double, left: Double, rate: Double?) -> String {
            """
            {"budgetPercent":\(budget),"usedPercent":\(used),"leftPercent":\(left),"ratePerHour":\(rate.map { "\($0)" } ?? "null"),
             "hours":[{"from":"\(iso(-3))","to":"\(iso(5))"}],"futureDays":[\(future)],"today":[],"sharedWith":[],"resetsAt":"\(iso(80))"}
            """
        }
        let plans = """
        {"plans":[
          {"id":"p1","provider":"claude","name":"Claude Team","budget":{"todayPercent":0,"affordablePercent":19.8,"leftPercent":79.2,
            "resetsAt":"\(iso(80))","accounts":3,"days":[\(days([18, 21.5, 0]))],"pace":\(pace(budget: 19.8, used: 0, left: 79.2, rate: 0))}},
          {"id":"p2","provider":"codex","name":"ChatGPT Pro","budget":{"todayPercent":12,"affordablePercent":20,"leftPercent":60,
            "resetsAt":"\(iso(80))","accounts":1,"days":[\(days([25, 3, 12]))],"pace":\(pace(budget: 20, used: 12, left: 60, rate: 4))}}
        ]}
        """

        let decoder = JSONDecoder()
        model.loadFixture(
            session: TeamsSession(token: "fixture", user: TeamsUser(id: "u-andrea", displayName: "Andrea")),
            usage: try decoder.decode(MyUsage.self, from: Data(usage.utf8)),
            teams: [TeamSummary(id: "t1", name: "Appload", memberCount: 4)],
            board: try decoder.decode(TeamStatsResponse.self, from: Data(stats.utf8)),
            range: .today,
            plans: try decoder.decode(TeamPlans.self, from: Data(plans.utf8))
        )
    }
}
#endif
