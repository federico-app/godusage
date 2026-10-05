import CryptoKit
import Foundation
import LocalAuthentication
import Security

private func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(status)
}

private func organizationalUnit(of certificate: SecCertificate) -> String? {
    guard
        let values = SecCertificateCopyValues(
            certificate,
            [kSecOIDX509V1SubjectName] as CFArray,
            nil
        ) as? [String: Any],
        let subject = values[kSecOIDX509V1SubjectName as String] as? [String: Any],
        let fields = subject[kSecPropertyKeyValue as String] as? [[String: Any]]
    else {
        return nil
    }

    return fields.first { field in
        field[kSecPropertyKeyLabel as String] as? String == kSecOIDOrganizationalUnitName as String
    }?[kSecPropertyKeyValue as String] as? String
}

private func isValidForCodeSigning(_ certificate: SecCertificate) -> Bool {
    guard let policy = SecPolicyCreateWithProperties(kSecPolicyAppleCodeSigning, nil) else {
        return false
    }
    var trust: SecTrust?
    guard
        SecTrustCreateWithCertificates(certificate, policy, &trust) == errSecSuccess,
        let trust
    else {
        return false
    }
    SecTrustSetNetworkFetchAllowed(trust, false)
    return SecTrustEvaluateWithError(trust, nil)
}

private func sha1Hex(of certificate: SecCertificate) -> String {
    let data = SecCertificateCopyData(certificate) as Data
    return Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
}

// Two modes:
//   <certificate-name-prefix> <team-id>  prints the first valid identity's display name
//   --sha1 <hex>...                       prints the first listed SHA-1 that is a valid identity
//                                         (a provisioning profile's certificates, in profile order)
let arguments = Array(CommandLine.arguments.dropFirst())
let wantedSHA1s: [String]?
if arguments.first == "--sha1" {
    wantedSHA1s = arguments.dropFirst().map { $0.uppercased() }
    guard wantedSHA1s?.isEmpty == false else { fail("usage: find_codesigning_identity.swift --sha1 <hex>...") }
} else {
    wantedSHA1s = nil
    guard arguments.count == 2 else {
        fail("usage: find_codesigning_identity.swift <certificate-name-prefix> <team-id> | --sha1 <hex>...")
    }
}
let namePrefix = arguments.first ?? ""
let teamID = arguments.count > 1 ? arguments[1] : ""

// Identity discovery is non-interactive. A prompt here would authorize this short-lived Swift
// helper rather than codesign or GodUsage, and a locked Keychain should fail the build explicitly.
let authenticationContext = LAContext()
authenticationContext.interactionNotAllowed = true
let query: [String: Any] = [
    kSecClass as String: kSecClassIdentity,
    kSecMatchLimit as String: kSecMatchLimitAll,
    kSecReturnRef as String: true,
    kSecUseAuthenticationContext as String: authenticationContext,
]
var result: CFTypeRef?
let queryStatus = SecItemCopyMatching(query as CFDictionary, &result)
if queryStatus == errSecItemNotFound {
    exit(1)
}
guard queryStatus == errSecSuccess else {
    fail("could not read code-signing identities (OSStatus \(queryStatus))", status: 2)
}
guard let identities = result as? [SecIdentity] else {
    fail("the Keychain returned an unexpected identity result", status: 2)
}

if let wantedSHA1s {
    var available: Set<String> = []
    for identity in identities {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate,
              isValidForCodeSigning(certificate)
        else { continue }
        available.insert(sha1Hex(of: certificate))
    }
    guard let match = wantedSHA1s.first(where: available.contains) else { exit(1) }
    print(match)
    exit(0)
}

for identity in identities {
    var certificate: SecCertificate?
    guard
        SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
        let certificate,
        let name = SecCertificateCopySubjectSummary(certificate) as String?,
        name.hasPrefix(namePrefix),
        organizationalUnit(of: certificate) == teamID,
        isValidForCodeSigning(certificate)
    else {
        continue
    }

    print(name)
    exit(0)
}

exit(1)
