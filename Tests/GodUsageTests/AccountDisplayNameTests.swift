import XCTest
@testable import GodUsage

@MainActor
final class AccountDisplayNameTests: XCTestCase {
    // MARK: Short label

    func testOrgNameWinsOverTheEmail() {
        XCTAssertEqual(AccountDisplayName.shortLabel("dev@appload.studio (Appload)"), "Appload")
        XCTAssertEqual(AccountDisplayName.shortLabel("a@b.co (Acme (EU))"), "Acme (EU)")
    }

    func testEmailIsTheFallbackWithoutAnOrg() {
        XCTAssertEqual(AccountDisplayName.shortLabel("dev@appload.studio"), "dev@appload.studio")
        XCTAssertEqual(AccountDisplayName.shortLabel("Just A Name"), "Just A Name")
    }

    func testPersonalOrgNamedAfterTheEmailFallsBackToTheEmail() {
        XCTAssertEqual(
            AccountDisplayName.shortLabel("dev@appload.studio (dev@appload.studio's Organization)"),
            "dev@appload.studio"
        )
    }

    func testLabeledKeepsTheFullLabelOnlyWhenItSaysMore() {
        let org = AccountDisplayName.labeled("Claude", label: "dev@appload.studio (Appload)")
        XCTAssertEqual(org, AccountDisplayName(name: "Claude", account: "Appload", detail: "dev@appload.studio (Appload)"))
        XCTAssertEqual(org.inline, "Claude (Appload)")

        let email = AccountDisplayName.labeled("Codex", label: "dev@appload.studio")
        XCTAssertEqual(email, AccountDisplayName(name: "Codex", account: "dev@appload.studio"))
        XCTAssertEqual(AccountDisplayName(name: "Cursor").inline, "Cursor")
    }

    // MARK: Store

    private func store() -> ProviderAccountsStore {
        let suite = "GodUsageTests.AccountDisplayName.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return ProviderAccountsStore(defaults: defaults)
    }

    private func observation(_ key: String, label: String?, isDefault: Bool) -> ProviderAccountsStore.AccountObservation {
        ProviderAccountsStore.AccountObservation(
            family: "claude", identityKey: key, label: label,
            sources: [ProviderAccountSource(
                kind: isDefault ? .defaultHome : .configDir,
                anchor: isDefault ? "/Users/dev/.claude" : "/Users/dev/.claude-\(key)",
                holdsDefaultSource: isDefault
            )]
        )
    }

    func testSiblingAccountsSplitIntoProviderAndShortLabel() throws {
        let store = store()
        let records = store.reconcile(with: [
            observation("acct-a", label: "a@example.com", isDefault: true),
            observation("acct-b", label: "b@example.com (Acme)", isDefault: false),
        ])
        let second = try XCTUnwrap(records.first { $0.identityKey == "acct-b" }?.id)

        XCTAssertEqual(store.resolvedDisplayParts(cardID: "claude"), AccountDisplayName(name: "Claude", account: "a@example.com"))
        XCTAssertEqual(
            store.resolvedDisplayParts(cardID: second),
            AccountDisplayName(name: "Claude", account: "Acme", detail: "b@example.com (Acme)")
        )
        // The plain name everywhere else keeps the email.
        XCTAssertEqual(store.resolvedDisplayName(cardID: second), "Claude — b@example.com (Acme)")
    }

    func testALoneAccountOrARenameIsJustAName() throws {
        let store = store()
        store.reconcile(with: [observation("acct-a", label: "a@example.com (Acme)", isDefault: true)])
        XCTAssertEqual(store.resolvedDisplayParts(cardID: "claude"), AccountDisplayName(name: "Claude"))

        store.rename(cardID: "claude", to: "Work")
        XCTAssertEqual(store.resolvedDisplayParts(cardID: "claude"), AccountDisplayName(name: "Work"))
        XCTAssertNil(store.resolvedDisplayParts(cardID: "cursor"))
    }

    func testDuplicateLabelsKeepTheirHashSuffix() throws {
        let store = store()
        store.reconcile(with: [
            observation("acct-a", label: "same@example.com (Acme)", isDefault: true),
            observation("acct-b", label: "same@example.com (Acme)", isDefault: false),
        ])
        XCTAssertEqual(
            store.resolvedDisplayParts(cardID: "claude")?.account,
            "Acme · \(ProviderAccountID.hash8("acct-a"))"
        )
    }
}
