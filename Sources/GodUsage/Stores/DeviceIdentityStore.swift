import Foundation
import Observation

private struct DeviceIdentityResolution: Sendable {
    var id: String
    var error: String?
    var isProvisional: Bool
    /// True only when the current file and saved preference were absent and a legacy Keychain read
    /// was the step that failed. Other provisional states need storage repair, not another prompt.
    var canRecoverLegacyIdentity: Bool
}

/// This Mac's durable device id. Teams keys this Mac's usage upload by it, so one Mac stays one
/// device on the server across launches, upgrades, and preference resets.
///
/// When the id can't be established (the legacy lookup was indeterminate and no saved id exists),
/// the identity is provisional: any id minted then could register this Mac a second time, so
/// `durableDeviceID` stays nil and Teams withholds its upload until the lookup works or the user
/// chooses Recover Identity.
@MainActor
@Observable
final class DeviceIdentityStore {
    /// Frozen key name: the id was first minted for the retired iCloud Sync, and existing Macs must
    /// keep the same value.
    static let deviceIDKey = "godusage.icloudSync.deviceID.v1"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let deviceIDStore: any DeviceIDStoring

    private(set) var deviceID: String
    /// Why the identity is provisional or not durable; nil when everything is fine.
    private(set) var identityError: String?
    private(set) var isProvisional: Bool
    private(set) var isRecovering = false
    private var legacyIdentityRecoveryAvailable: Bool
    var canRecoverIdentity: Bool { isProvisional && legacyIdentityRecoveryAvailable }

    /// This Mac's durable id, or nil while it is provisional. Retries the lookup first, so a
    /// transient storage or Keychain failure clears without a relaunch.
    var durableDeviceID: String? {
        resolveProvisionalIdentityIfNeeded()
        return isProvisional ? nil : deviceID
    }

    init(
        defaults: UserDefaults = .standard,
        deviceIDStore: any DeviceIDStoring = OwnedDeviceIDStore()
    ) {
        self.defaults = defaults
        self.deviceIDStore = deviceIDStore
        let identity = Self.resolveDeviceID(defaults: defaults, store: deviceIDStore)
        self.deviceID = identity.id
        self.identityError = identity.error
        self.isProvisional = identity.isProvisional
        self.legacyIdentityRecoveryAvailable = identity.canRecoverLegacyIdentity
    }

    /// Explicit, user-attended recovery of a legacy Keychain identity. Automatic paths stay
    /// metadata/cache-only; only this Settings action may raise an approval dialog for an old item.
    func recoverIdentity() async {
        guard canRecoverIdentity, !isRecovering else { return }
        isRecovering = true
        let store = deviceIDStore
        let savedDeviceID = defaults.string(forKey: Self.deviceIDKey)
        let identity = await loadOffMainActor {
            Self.resolveDeviceID(savedDeviceID: savedDeviceID, store: store, allowLegacyInteraction: true)
        }
        isRecovering = false

        guard !identity.isProvisional else {
            identityError = identity.error
            legacyIdentityRecoveryAvailable = identity.canRecoverLegacyIdentity
            return
        }
        AppLog.info(.config, "device identity recovered by explicit user action")
        defaults.set(identity.id, forKey: Self.deviceIDKey)
        adopt(identity)
    }

    /// Re-runs identity resolution while it is provisional. A success adopts the real id; a failure
    /// leaves the state as it was and the next attempt tries again.
    private func resolveProvisionalIdentityIfNeeded() {
        guard isProvisional else { return }
        let identity = Self.resolveDeviceID(defaults: defaults, store: deviceIDStore)
        guard !identity.isProvisional else {
            legacyIdentityRecoveryAvailable = identity.canRecoverLegacyIdentity
            return
        }
        AppLog.info(.config, "device identity resolved")
        adopt(identity)
    }

    private func adopt(_ identity: DeviceIdentityResolution) {
        deviceID = identity.id
        identityError = identity.error
        isProvisional = false
        legacyIdentityRecoveryAvailable = false
    }

    private static func resolveDeviceID(
        defaults: UserDefaults,
        store: any DeviceIDStoring
    ) -> DeviceIdentityResolution {
        let identity = resolveDeviceID(
            savedDeviceID: defaults.string(forKey: deviceIDKey),
            store: store,
            allowLegacyInteraction: false
        )
        if !identity.isProvisional {
            defaults.set(identity.id, forKey: deviceIDKey)
        }
        return identity
    }

    nonisolated private static func resolveDeviceID(
        savedDeviceID: String?,
        store: any DeviceIDStoring,
        allowLegacyInteraction: Bool
    ) -> DeviceIdentityResolution {
        let saved = normalizedDeviceID(savedDeviceID)
        var legacyRecoveryFailed = false
        do {
            if let stored = try store.readDeviceID() {
                // Present but not a UUID is a corrupt identity, not an absent one. Falling through
                // would mint a fresh id and register this Mac a second time, so this fails into the
                // provisional path exactly like an unreadable item.
                guard let normalized = normalizedDeviceID(stored) else {
                    throw KeychainError.readFailed("This Mac's stored device identity is not a valid identifier.")
                }
                return DeviceIdentityResolution(
                    id: normalized, error: nil, isProvisional: false, canRecoverLegacyIdentity: false
                )
            }

            // The saved preference is the same id the older Keychain stores held, so on upgrades it
            // seeds the private file without touching either legacy Keychain path. Legacy recovery,
            // which can raise a prompt, runs only when BOTH are gone (a preferences reset).
            if let saved {
                try store.writeDeviceID(saved)
                return DeviceIdentityResolution(
                    id: saved, error: nil, isProvisional: false, canRecoverLegacyIdentity: false
                )
            }
            // Same rule as the current file: a legacy value that is present but not a UUID is a
            // corrupt identity, never a reason to mint a replacement.
            let migrated: String?
            do {
                migrated = try store.migrateLegacyDeviceID(allowInteraction: allowLegacyInteraction)
            } catch {
                legacyRecoveryFailed = true
                throw error
            }
            if let migrated {
                guard let normalized = normalizedDeviceID(migrated) else {
                    throw KeychainError.readFailed("This Mac's previous device identity is not a valid identifier.")
                }
                return DeviceIdentityResolution(
                    id: normalized, error: nil, isProvisional: false, canRecoverLegacyIdentity: false
                )
            }

            let id = UUID().uuidString.lowercased()
            try store.writeDeviceID(id)
            return DeviceIdentityResolution(
                id: id, error: nil, isProvisional: false, canRecoverLegacyIdentity: false
            )
        } catch {
            AppLog.warn(.config, "device identity failed: \(error.localizedDescription)")
            if let saved {
                // A known id: uploading under it is still correct, it just isn't durable against a
                // preferences reset.
                return DeviceIdentityResolution(
                    id: saved,
                    error: "GodUsage couldn’t save this Mac’s identity. Teams can count this Mac twice "
                        + "if you reset app preferences.",
                    isProvisional: false,
                    canRecoverLegacyIdentity: false
                )
            }
            // Nothing to go on: any id minted here can duplicate this Mac's existing one. Keep it out
            // of the defaults and off the server until the lookup works.
            return DeviceIdentityResolution(
                id: UUID().uuidString.lowercased(),
                error: "GodUsage couldn’t identify this Mac, so Teams won’t share its usage until "
                    + "its local identity storage is available again.",
                isProvisional: true,
                canRecoverLegacyIdentity: legacyRecoveryFailed
            )
        }
    }

    nonisolated private static func normalizedDeviceID(_ value: String?) -> String? {
        guard let value, UUID(uuidString: value) != nil else { return nil }
        return value.lowercased()
    }
}
