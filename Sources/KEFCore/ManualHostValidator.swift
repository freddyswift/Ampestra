import Foundation

/// Validates manual speaker hosts before the app attempts a network request.
///
/// The app controls only local speakers, so public IPs and URL-like strings are
/// rejected. This reduces accidental requests to arbitrary hosts and keeps the
/// settings UI focused on private LAN addresses or Bonjour `.local` names.
public enum ManualHostValidator {
    public static func normalizedHost(_ host: String) -> String? {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard normalized.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        guard !normalized.contains("://") else { return nil }

        let blockedCharacters = CharacterSet(charactersIn: "/?#@\\")
        guard normalized.rangeOfCharacter(from: blockedCharacters) == nil else { return nil }

        let lowercased = normalized.lowercased()
        if isPrivateIPv4Address(lowercased) {
            // Emit decimal octets so leading zeroes cannot be interpreted as
            // octal by a URL parser or resolver after validation.
            return lowercased.split(separator: ".").compactMap { Int($0) }.map(String.init).joined(separator: ".")
        }
        if isLocalHostname(lowercased) {
            return lowercased
        }

        return nil
    }

    public static func normalizedDiscoveryHost(_ host: String) -> String? {
        guard let normalized = normalizedHost(host),
              !isLoopbackIPv4Address(normalized) else {
            return nil
        }

        return normalized
    }

    private static func isPrivateIPv4Address(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }

        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part), 0...255 ~= value else {
                return nil
            }

            return value
        }

        guard octets.count == 4 else { return false }

        switch (octets[0], octets[1]) {
        case (10, _), (169, 254), (172, 16...31), (192, 168):
            return true
        default:
            return false
        }
    }

    private static func isLoopbackIPv4Address(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              let firstOctet = Int(parts[0]),
              firstOctet == 127 else {
            return false
        }

        return parts.allSatisfy { part in
            guard !part.isEmpty,
                  part.allSatisfy(\.isNumber),
                  let value = Int(part) else {
                return false
            }

            return 0...255 ~= value
        }
    }

    private static func isLocalHostname(_ host: String) -> Bool {
        guard host.hasSuffix(".local") else { return false }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }

        return labels.allSatisfy { label in
            guard !label.isEmpty, label.count <= 63 else { return false }
            guard label.first != "-", label.last != "-" else { return false }

            return label.allSatisfy { character in
                character.isLetter || character.isNumber || character == "-"
            }
        }
    }
}
