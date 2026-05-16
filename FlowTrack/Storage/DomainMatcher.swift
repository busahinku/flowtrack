import Foundation

enum DomainMatcher {
    nonisolated static func normalizedDomain(_ rawValue: String) -> String? {
        var raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty else { return nil }

        if raw.hasPrefix("*.") {
            raw.removeFirst(2)
        }

        if let components = URLComponents(string: raw), let host = components.host {
            raw = host
        } else if let schemeRange = raw.range(of: "://") {
            raw = String(raw[schemeRange.upperBound...])
        }

        if let end = raw.firstIndex(where: { "/?#".contains($0) }) {
            raw = String(raw[..<end])
        }
        if let portStart = raw.lastIndex(of: ":") {
            raw = String(raw[..<portStart])
        }

        raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if raw.hasPrefix("www.") {
            raw.removeFirst(4)
        }

        guard !raw.isEmpty,
              raw.contains(".") || raw == "localhost",
              raw.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return nil
        }
        return raw
    }

    nonisolated static func host(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if let host = URLComponents(string: trimmed)?.host {
            return normalizedDomain(host)
        }
        return normalizedDomain(trimmed)
    }

    nonisolated static func host(_ host: String, matches blockedDomain: String) -> Bool {
        guard let normalizedHost = normalizedDomain(host),
              let normalizedBlocked = normalizedDomain(blockedDomain) else { return false }
        return normalizedHost == normalizedBlocked || normalizedHost.hasSuffix("." + normalizedBlocked)
    }

    nonisolated static func url(_ urlString: String, matches blockedDomain: String) -> Bool {
        guard let currentHost = host(from: urlString) else { return false }
        return host(currentHost, matches: blockedDomain)
    }

    nonisolated static func normalizedDomains(_ domains: [String]) -> [String] {
        Array(Set(domains.compactMap(normalizedDomain))).sorted()
    }
}
