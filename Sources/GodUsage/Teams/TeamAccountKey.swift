import CryptoKit
import Foundation

/// An anonymous fingerprint of a provider account, sent with account-wide team usage. Two members
/// who log into the same account (one shared Cursor seat) send the same fingerprint, so the team
/// counts that usage once. The account id itself never leaves the Mac.
enum TeamAccountKey {
    static func make(provider: String, accountID: String) -> String {
        let digest = SHA256.hash(data: Data("godusage.team-account.v1|\(provider)|\(accountID)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
