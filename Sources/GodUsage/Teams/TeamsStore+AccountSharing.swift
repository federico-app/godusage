import Foundation

/// Leaving an account out of a team: a member with a personal and a work login of one provider
/// counts only the work one in the work team. The choice is per team and per Mac, kept on this Mac;
/// the upload sends each left-out account on its own with the teams it is left out of (see
/// `TeamUsageUpload.make`).
extension TeamsStore {
    private static let excludedCardsKey = "godusage.teams.excludedCards.v1"

    /// The cards whose usage this Mac uploads, in card-id order (the plain card first).
    func shareableCardIDs() -> [String] {
        historySources().map(\.cardID).sorted()
    }

    func isCardCounted(_ cardID: String, in teamID: String) -> Bool {
        !(excludedCards[teamID]?.contains(cardID) ?? false)
    }

    /// Counts the card in the team again, or leaves it out, and uploads at once so the board follows.
    func setCardCounted(_ counted: Bool, cardID: String, in teamID: String) {
        var cards = excludedCards[teamID] ?? []
        if counted { cards.remove(cardID) } else { cards.insert(cardID) }
        excludedCards[teamID] = cards.isEmpty ? nil : cards
        do {
            defaults.set(try JSONEncoder().encode(excludedCards), forKey: Self.excludedCardsKey)
        } catch {
            AppLog.error(.teams, "couldn't save the accounts left out of teams: \(error)")
        }
        AppLog.info(.teams, "\(counted ? "counting" : "leaving out") \(cardID) in team \(teamID)")
        scheduleUpload(force: true)
    }

    /// The exclusions of the teams the user is still in (all of them until the team list loads).
    func uploadExclusions() -> [String: Set<String>] {
        guard !teams.isEmpty else { return excludedCards }
        return excludedCards.filter { teamID, _ in teams.contains { $0.id == teamID } }
    }

    static func loadExcludedCards(from defaults: UserDefaults) -> [String: Set<String>] {
        guard let data = defaults.data(forKey: excludedCardsKey) else { return [:] }
        do {
            return try JSONDecoder().decode([String: Set<String>].self, from: data)
        } catch {
            AppLog.error(.teams, "couldn't read the accounts left out of teams, counting every account: \(error)")
            return [:]
        }
    }

    /// The fingerprint a card's account goes up under. Cursor's names the account on every Mac;
    /// Claude's and Codex's name this Mac and card, the same as their quota windows.
    nonisolated static func accountKey(for source: TeamHistorySource, deviceID: String) -> String {
        source.history.accountKey ?? TeamAccountKey.make(
            provider: ProviderAccountID.family(of: source.cardID),
            accountID: localAccountID(cardID: source.cardID, deviceID: deviceID)
        )
    }

    nonisolated static func localAccountID(cardID: String, deviceID: String) -> String {
        "\(deviceID)|\(cardID)"
    }
}
