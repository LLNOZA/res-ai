import Foundation
import Security

/// The signing identity of the running app. macOS matches Accessibility and Input
/// Monitoring grants against it, so a change here explains grants that stop applying.
public struct CodeSigningIdentity: Equatable, Sendable {
    public let teamID: String?
    public let signerName: String?
    public let isAdHoc: Bool

    public init(teamID: String?, signerName: String?, isAdHoc: Bool) {
        self.teamID = teamID
        self.signerName = signerName
        self.isAdHoc = isAdHoc
    }

    public static let unsigned = CodeSigningIdentity(teamID: nil, signerName: nil, isAdHoc: false)

    /// Stable key for comparing identities across launches.
    public var fingerprint: String {
        if isAdHoc {
            return "adhoc"
        }
        guard teamID != nil || signerName != nil else {
            return "unsigned"
        }
        return "team=\(teamID ?? "none") signer=\(signerName ?? "none")"
    }

    public var logDescription: String {
        if isAdHoc {
            return "signing=adhoc"
        }
        guard teamID != nil || signerName != nil else {
            return "signing=unsigned"
        }
        return "team=\(teamID ?? "none") signer=\"\(signerName ?? "none")\""
    }

    public static func current() -> CodeSigningIdentity {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return .unsigned
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return .unsigned
        }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &information
            ) == errSecSuccess,
            let info = information as? [String: Any]
        else {
            return .unsigned
        }

        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate]
        let signerName = certificates?.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        return CodeSigningIdentity(
            teamID: info[kSecCodeInfoTeamIdentifier as String] as? String,
            signerName: signerName,
            isAdHoc: flags & SecCodeSignatureFlags.adhoc.rawValue != 0
        )
    }
}
