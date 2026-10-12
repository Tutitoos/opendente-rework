import Foundation
import Security

/// XPC enforces this requirement against the actual message sender, avoiding PID lookup races.
enum CallerAuthorization {
    enum VerificationError: Error {
        case unsignedHelper
        case invalidTeamIdentifier
        case invalidRequirement
    }

    static func requirement(teamIdentifier: String, bundleIdentifier: String) throws -> String {
        guard teamIdentifier.count == 10,
              teamIdentifier.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }),
              bundleIdentifier.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }) else {
            throw VerificationError.invalidTeamIdentifier
        }
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\" and identifier \"\(bundleIdentifier)\""
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess else {
            throw VerificationError.invalidRequirement
        }
        return requirement
    }

    /// Only a properly Apple-signed helper can establish a trusted team. Ad-hoc and unsigned
    /// binaries fail closed in Debug as well as Release; tests inject hardware, never trust.
    static func currentHelperRequirement() throws -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            throw VerificationError.unsignedHelper
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw VerificationError.unsignedHelper
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String else {
            throw VerificationError.unsignedHelper
        }
        let ownRequirement = try requirement(teamIdentifier: team, bundleIdentifier: HelperConstants.helperBundleID)
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(ownRequirement as CFString, [], &compiled) == errSecSuccess,
              let compiled,
              SecCodeCheckValidity(code, [], compiled) == errSecSuccess else {
            throw VerificationError.unsignedHelper
        }
        return try requirement(teamIdentifier: team, bundleIdentifier: HelperConstants.appBundleID)
    }
}
