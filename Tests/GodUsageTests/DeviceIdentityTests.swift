import Security
import XCTest
@testable import GodUsage

/// This Mac's device identity: where the id comes from, how it migrates off the legacy Keychain
/// items, and — most importantly — that Teams never sees a second id for a Mac that already has one.
@MainActor
final class DeviceIdentityTests: XCTestCase {
    private let deviceIDKey = "godusage.icloudSync.deviceID.v1"
    private let ownedService = "com.montinovo.godusage.icloud-sync-device-id.v3"

    /// The SwiftPM test host is ad-hoc signed, so the real process-signature check would refuse the
    /// interactive legacy-recovery reads these tests exercise. Pin the seam to "durable" here;
    /// `KeychainAccessorTests` covers the refusal path explicitly.
    override func setUp() {
        super.setUp()
        InteractiveKeychainReadGate.processCanHoldDurableApprovals = { true }
    }

    override func tearDown() {
        InteractiveKeychainReadGate.processCanHoldDurableApprovals = {
            ProcessCodeSignature.canHoldDurableKeychainApprovals
        }
        super.tearDown()
    }

    func testDeviceIdentitySurvivesPreferencesReset() {
        let expectedID = UUID().uuidString.lowercased()
        let firstDefaults = makeDefaults("identity-first")
        firstDefaults.set(expectedID, forKey: deviceIDKey)
        let deviceIDStore = MemoryDeviceIDStore()

        let first = DeviceIdentityStore(defaults: firstDefaults, deviceIDStore: deviceIDStore)
        let resetDefaults = makeDefaults("identity-after-reset")
        let afterReset = DeviceIdentityStore(defaults: resetDefaults, deviceIDStore: deviceIDStore)

        XCTAssertEqual(first.durableDeviceID, expectedID)
        XCTAssertEqual(afterReset.durableDeviceID, expectedID)
        XCTAssertEqual(resetDefaults.string(forKey: deviceIDKey), expectedID)
    }

    func testIdentityIsScopedToDevelopmentAndProductionBundles() throws {
        let owned = InMemoryOwnedSecretStore()
        let development = OwnedDeviceIDStore(
            ownedStore: owned,
            legacyKeychain: ServiceKeychain(),
            bundleIdentifier: "com.montinovo.godusage.dev"
        )
        let production = OwnedDeviceIDStore(
            ownedStore: owned,
            legacyKeychain: ServiceKeychain(),
            bundleIdentifier: "com.montinovo.godusage"
        )

        try development.writeDeviceID("development-id")
        try production.writeDeviceID("production-id")

        XCTAssertEqual(try development.readDeviceID(), "development-id")
        XCTAssertEqual(try production.readDeviceID(), "production-id")
    }

    func testExistingMacKeepsItsStoredIDAndFileLocation() {
        // Upgrading from the iCloud Sync era: the id lives in the same owned file, under the same
        // service name, so Teams sees the same device as before.
        let defaults = makeDefaults("existing-owned-id")
        let owned = InMemoryOwnedSecretStore()
        owned.secrets[ownedService] = "abababab-1111-2222-3333-444444444444"
        let identity = DeviceIdentityStore(
            defaults: defaults,
            deviceIDStore: OwnedDeviceIDStore(
                ownedStore: owned,
                legacyKeychain: TrappingKeychain(),
                bundleIdentifier: "com.montinovo.godusage"
            )
        )

        XCTAssertEqual(identity.durableDeviceID, "abababab-1111-2222-3333-444444444444")
        XCTAssertNil(identity.identityError)
    }

    func testUpgradeSeedsTheOwnedItemFromSavedPreferencesWithoutTouchingLegacyKeychain() {
        // UserDefaults still carries the device id, so the owned item is seeded from it directly.
        // The prompt-capable legacy Keychain path must not be consulted at all.
        let defaults = makeDefaults("upgrade-from-saved")
        defaults.set("aaaaaaaa-1111-2222-3333-444444444444", forKey: deviceIDKey)
        let owned = InMemoryOwnedSecretStore()
        let identity = DeviceIdentityStore(
            defaults: defaults,
            deviceIDStore: OwnedDeviceIDStore(
                ownedStore: owned,
                legacyKeychain: TrappingKeychain(),
                bundleIdentifier: "com.montinovo.godusage"
            )
        )

        XCTAssertEqual(identity.deviceID, "aaaaaaaa-1111-2222-3333-444444444444")
        XCTAssertEqual(owned.secrets[ownedService], "aaaaaaaa-1111-2222-3333-444444444444")
    }

    func testPreferencesResetUpgradeRecoversTheLegacyDeviceIDOnce() {
        // Only when BOTH the owned item and the saved preference are gone is the legacy v1 item
        // consulted — once. It seeds the owned item, and later launches never reach it again.
        let defaults = makeDefaults("upgrade-after-prefs-reset")
        let owned = InMemoryOwnedSecretStore()
        let legacy = ServiceKeychain()
        legacy.currentUserValues["com.montinovo.godusage.icloud-sync-device-id.v1"] = "bbbbbbbb-1111-2222-3333-444444444444"
        legacy.values["com.montinovo.godusage.icloud-sync-device-id.v1"] = "bbbbbbbb-1111-2222-3333-444444444444"
        let store = OwnedDeviceIDStore(ownedStore: owned, legacyKeychain: legacy, bundleIdentifier: "com.montinovo.godusage")

        let identity = DeviceIdentityStore(defaults: defaults, deviceIDStore: store)

        XCTAssertEqual(identity.deviceID, "bbbbbbbb-1111-2222-3333-444444444444")
        XCTAssertEqual(owned.secrets[ownedService], "bbbbbbbb-1111-2222-3333-444444444444")
        XCTAssertEqual(defaults.string(forKey: deviceIDKey), "bbbbbbbb-1111-2222-3333-444444444444")

        legacy.currentUserValues["com.montinovo.godusage.icloud-sync-device-id.v1"] = "cccccccc-1111-2222-3333-444444444444"
        let relaunch = DeviceIdentityStore(defaults: defaults, deviceIDStore: store)
        XCTAssertEqual(relaunch.deviceID, "bbbbbbbb-1111-2222-3333-444444444444")
    }

    func testPreferencesResetCanRecoverLegacyIdentityOnlyAfterExplicitUserAction() async {
        let defaults = makeDefaults("manual-legacy-identity-recovery")
        let owned = InMemoryOwnedSecretStore()
        let legacy = ManualOnlyLegacyKeychain(value: "eeeeeeee-1111-2222-3333-444444444444")
        let identity = DeviceIdentityStore(
            defaults: defaults,
            deviceIDStore: OwnedDeviceIDStore(
                ownedStore: owned,
                legacyKeychain: legacy,
                bundleIdentifier: "com.montinovo.godusage"
            )
        )

        XCTAssertTrue(identity.canRecoverIdentity)
        XCTAssertNotNil(identity.identityError)
        XCTAssertEqual(legacy.interactiveReads, 0, "launch must not request the legacy secret")

        await identity.recoverIdentity()

        XCTAssertFalse(identity.canRecoverIdentity)
        XCTAssertNil(identity.identityError)
        XCTAssertEqual(identity.durableDeviceID, "eeeeeeee-1111-2222-3333-444444444444")
        XCTAssertEqual(legacy.interactiveReads, 1)
        XCTAssertEqual(owned.secrets[ownedService], "eeeeeeee-1111-2222-3333-444444444444")
    }

    func testManualLegacyRecoveryBypassesBreakerTrippedByAutomaticAttempt() throws {
        // Models an item whose ACL does NOT grant this process: the quiet automatic read gets
        // errSecAuthFailed (suppressed UI forbids the dialog), trips the breaker, and only the
        // user-attended read — where the dialog may show and be approved — recovers the secret.
        let owned = InMemoryOwnedSecretStore()
        let approvedReads = KeychainReadCounter()
        let suppressedState = KeychainReadCounter()
        let accessor = SecurityKeychainAccessor(
            coordinator: KeychainReadCoordinator(),
            copyMatching: { query, result in
                let attributes = query as NSDictionary
                if attributes[kSecReturnData] as? Bool == true {
                    guard suppressedState.value == 0 else {
                        return errSecAuthFailed
                    }
                    approvedReads.increment()
                    result?.pointee = Data("ffffffff-1111-2222-3333-444444444444".utf8) as CFData
                    return errSecSuccess
                }
                if attributes[kSecReturnAttributes] as? Bool == true {
                    result?.pointee = [
                        kSecAttrService as String: "com.montinovo.godusage.icloud-sync-device-id.v1",
                        kSecAttrModificationDate as String: Date(timeIntervalSinceReferenceDate: 1),
                    ] as CFDictionary
                }
                return errSecSuccess
            },
            setUserInteractionAllowed: { allowed in
                if allowed { suppressedState.reset() } else { suppressedState.increment() }
                return errSecSuccess
            },
            // The real fallback would consult the REAL keychain (a legacy item can exist on a
            // developer machine); this test models an item whose approval is genuinely pending.
            partitionWallFallback: { _, _ in nil }
        )
        let store = OwnedDeviceIDStore(
            ownedStore: owned,
            legacyKeychain: accessor,
            bundleIdentifier: "com.montinovo.godusage"
        )

        XCTAssertThrowsError(try store.migrateLegacyDeviceID())
        XCTAssertEqual(approvedReads.value, 0, "automatic recovery must never obtain the secret via a dialog")

        XCTAssertEqual(
            try store.migrateLegacyDeviceID(allowInteraction: true),
            "ffffffff-1111-2222-3333-444444444444"
        )
        XCTAssertEqual(approvedReads.value, 1, "manual recovery must reach the interactive read")
        XCTAssertEqual(owned.secrets[ownedService], "ffffffff-1111-2222-3333-444444444444")
    }

    func testUnknownLegacyProbeLeavesTheIdentityProvisional() {
        // The owned item and the saved preference are both gone and the keychain can't be checked.
        // Any id minted here could duplicate this Mac's real one, so Teams gets no id at all.
        let defaults = makeDefaults("unknown-legacy-probe")
        let store = OwnedDeviceIDStore(
            ownedStore: InMemoryOwnedSecretStore(),
            legacyKeychain: IndeterminateProbeKeychain(),
            bundleIdentifier: "com.montinovo.godusage"
        )
        XCTAssertThrowsError(try store.migrateLegacyDeviceID())

        let identity = DeviceIdentityStore(defaults: defaults, deviceIDStore: store)

        XCTAssertNil(identity.durableDeviceID, "a provisional identity must never reach Teams")
        XCTAssertTrue(identity.isProvisional)
        XCTAssertNil(defaults.string(forKey: deviceIDKey), "a provisional id must not be persisted")
        XCTAssertNotNil(identity.identityError, "the user must be told why usage isn't shared")
    }

    func testProvisionalIdentityRecoversWithinTheSameSession() {
        // Once identity storage becomes readable, the next lookup adopts the real id without a
        // relaunch.
        let defaults = makeDefaults("provisional-recovers-in-session")
        let recovering = RecoveringDeviceIDStore()
        let identity = DeviceIdentityStore(defaults: defaults, deviceIDStore: recovering)
        XCTAssertNil(identity.durableDeviceID)

        recovering.recover(as: "dddddddd-1111-2222-3333-444444444444")

        XCTAssertEqual(identity.durableDeviceID, "dddddddd-1111-2222-3333-444444444444")
        XCTAssertNil(identity.identityError)
        XCTAssertEqual(defaults.string(forKey: deviceIDKey), "dddddddd-1111-2222-3333-444444444444")
    }

    func testTeamsWithholdsUploadWhileTheIdentityIsProvisional() async {
        let defaults = makeDefaults("teams-provisional")
        let recovering = RecoveringDeviceIDStore()
        let identity = DeviceIdentityStore(defaults: defaults, deviceIDStore: recovering)
        XCTAssertNil(identity.durableDeviceID)
        // The closure AppContainer hands TeamsStore: nil while provisional, so no upload can carry a
        // minted id.
        let deviceID: @MainActor () -> String? = { identity.durableDeviceID }
        XCTAssertNil(deviceID())
        recovering.recover(as: "12121212-1111-2222-3333-444444444444")
        XCTAssertEqual(deviceID(), "12121212-1111-2222-3333-444444444444")
    }

    func testFreshInstallNeverSpawnsTheLegacyKeychainRead() throws {
        // A fresh install has no legacy item: the prompt-free existence probe answers "absent" and
        // the legacy secret read must never run.
        let store = OwnedDeviceIDStore(
            ownedStore: InMemoryOwnedSecretStore(),
            legacyKeychain: ProbeOnlyKeychain(),
            bundleIdentifier: "com.montinovo.godusage"
        )
        XCTAssertNil(try store.migrateLegacyDeviceID())
    }

    func testFreshInstallMintsAndPersistsADurableID() throws {
        let defaults = makeDefaults("fresh-install")
        let owned = InMemoryOwnedSecretStore()
        let identity = DeviceIdentityStore(
            defaults: defaults,
            deviceIDStore: OwnedDeviceIDStore(
                ownedStore: owned,
                legacyKeychain: ProbeOnlyKeychain(),
                bundleIdentifier: "com.montinovo.godusage"
            )
        )

        let id = try XCTUnwrap(identity.durableDeviceID)
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(owned.secrets[ownedService], id)
        XCTAssertEqual(defaults.string(forKey: deviceIDKey), id)
    }

    func testAReadableButInvalidStoredIDNeverMintsAReplacement() {
        // A stored value that is readable text but not a UUID is a CORRUPT identity, not an absent
        // one. Treating it as absent would mint a new id and count this Mac twice.
        let defaults = makeDefaults("invalid-stored-device-id")
        let owned = InMemoryOwnedSecretStore()
        owned.secrets[ownedService] = "not-a-uuid"
        let identity = DeviceIdentityStore(
            defaults: defaults,
            deviceIDStore: OwnedDeviceIDStore(
                ownedStore: owned,
                legacyKeychain: ProbeOnlyKeychain(),
                bundleIdentifier: "com.montinovo.godusage"
            )
        )

        XCTAssertNotNil(identity.identityError, "a corrupt identity must be reported, not silently replaced")
        XCTAssertFalse(identity.canRecoverIdentity, "legacy recovery cannot repair a malformed current identity file")
        XCTAssertNil(identity.durableDeviceID)
        XCTAssertNil(defaults.string(forKey: deviceIDKey), "no replacement identity may be persisted")
        XCTAssertEqual(owned.secrets[ownedService], "not-a-uuid")
    }

    func testAnInvalidLegacyIdentityNeverMintsAReplacement() {
        let defaults = makeDefaults("invalid-legacy-device-id")
        let identity = DeviceIdentityStore(defaults: defaults, deviceIDStore: InvalidLegacyDeviceIDStore())

        XCTAssertNotNil(identity.identityError, "a corrupt legacy identity must be reported")
        XCTAssertNil(identity.durableDeviceID)
        XCTAssertNil(defaults.string(forKey: deviceIDKey), "no replacement identity may be persisted")
    }

    func testAnUndecodableOwnedValueIsAReadFailureNotAnAbsentItem() throws {
        // The owned store must surface a present-but-undecodable item as an error. Returning nil
        // would put the store on the same "fresh install" path as a genuinely missing item.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GodUsageOwnedFileStoreInvalidTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GodUsageOwnedFileStore(directory: directory.path)
        let service = "GodUsageTests.owned.invalid.\(UUID().uuidString)"
        try Data([0xFF, 0xFE, 0xFD]).write(to: directory.appendingPathComponent(service))

        XCTAssertThrowsError(try store.read(service: service))
    }

    func testMissingDeviceIDReadsNilWithoutInventingAnIdentity() throws {
        let store = OwnedDeviceIDStore(
            ownedStore: InMemoryOwnedSecretStore(),
            legacyKeychain: ServiceKeychain(),
            bundleIdentifier: "com.montinovo.godusage"
        )
        XCTAssertNil(try store.readDeviceID())
        XCTAssertNil(try store.migrateLegacyDeviceID())
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "GodUsageTests.DeviceIdentity.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

final class InMemoryOwnedSecretStore: GodUsageOwnedSecretStoring, @unchecked Sendable {
    var secrets: [String: String] = [:]

    func read(service: String) throws -> String? {
        secrets[service]
    }

    func write(service: String, value: String) throws {
        secrets[service] = value
    }
}

/// Fails the test on ANY read: proves a code path never consults the (prompt-capable) legacy
/// Keychain.
final class TrappingKeychain: KeychainReading, @unchecked Sendable {
    func readGenericPassword(service: String) throws -> String? {
        XCTFail("the legacy Keychain path must not be consulted")
        return nil
    }

    func writeGenericPassword(service: String, value: String) throws {}
}

/// Answers the prompt-free existence probe with "absent" and fails the test if any secret read runs.
final class ProbeOnlyKeychain: KeychainReading, @unchecked Sendable {
    func readGenericPassword(service: String) throws -> String? {
        XCTFail("no secret read may run when the existence probe reports the item absent")
        return nil
    }

    func genericPasswordExists(service: String) -> Bool? {
        false
    }

    func genericPasswordExists(service: String, account: String) -> Bool? {
        false
    }

    func writeGenericPassword(service: String, value: String) throws {}
}

/// The legacy item's existence cannot be determined (locked keychain / suppressed probe), and any
/// secret read would fail the test — the migration must stop at the probe.
final class IndeterminateProbeKeychain: KeychainReading, @unchecked Sendable {
    func readGenericPassword(service: String) throws -> String? {
        XCTFail("no secret read may run when existence is unknown")
        return nil
    }

    func genericPasswordExists(service: String) -> Bool? {
        nil
    }

    func genericPasswordExists(service: String, account: String) -> Bool? {
        nil
    }

    func genericPasswordForCurrentUserExists(service: String) -> Bool? {
        nil
    }
}

private final class ManualOnlyLegacyKeychain: KeychainReading, @unchecked Sendable {
    private let value: String
    private let lock = NSLock()
    private var readCount = 0

    init(value: String) {
        self.value = value
    }

    var interactiveReads: Int { lock.withLock { readCount } }

    func readGenericPassword(service: String) throws -> String? { nil }

    func readGenericPasswordForCurrentUserWithoutUserInteraction(
        service: String
    ) -> NonInteractiveKeychainRead {
        .unavailable
    }

    func readGenericPasswordForCurrentUserAllowingUserInteraction(service: String) throws -> String? {
        lock.withLock { readCount += 1 }
        return value
    }

    func genericPasswordForCurrentUserExists(service: String) -> Bool? { true }
}

private final class KeychainReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }

    func reset() {
        lock.withLock { count = 0 }
    }
}

/// No v2 item, and the legacy recovery hands back a value that is readable but not a UUID.
private final class InvalidLegacyDeviceIDStore: DeviceIDStoring, @unchecked Sendable {
    func readDeviceID() throws -> String? { nil }
    func writeDeviceID(_ deviceID: String) throws {}
    func migrateLegacyDeviceID() throws -> String? { "definitely-not-a-uuid" }
}

/// Unresolvable until `recover` is called, then returns a real id — models a keychain that becomes
/// readable during the session.
final class RecoveringDeviceIDStore: DeviceIDStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    func recover(as id: String) {
        lock.withLock { stored = id }
    }

    func readDeviceID() throws -> String? {
        lock.withLock { stored }
    }

    func writeDeviceID(_ deviceID: String) throws {
        lock.withLock { stored = deviceID }
    }

    func migrateLegacyDeviceID() throws -> String? {
        guard lock.withLock({ stored }) != nil else {
            throw KeychainError.readFailed("keychain unavailable")
        }
        return nil
    }
}

final class MemoryDeviceIDStore: DeviceIDStoring, @unchecked Sendable {
    private var deviceID: String?

    func readDeviceID() throws -> String? {
        deviceID
    }

    func writeDeviceID(_ deviceID: String) throws {
        self.deviceID = deviceID
    }
}
