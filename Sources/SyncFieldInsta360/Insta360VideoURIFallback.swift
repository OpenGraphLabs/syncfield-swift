import Foundation

internal enum Insta360VideoURIFallback {
    static func bestCandidate(from uris: [String]) -> String? {
        rankedCandidates(from: uris).first
    }

    static func rankedCandidates(from uris: [String]) -> [String] {
        uris
            .filter(isLikelyDownloadableVideoURI)
            .sorted { lhs, rhs in
                sortKey(lhs) > sortKey(rhs)
            }
    }

    private static func isLikelyDownloadableVideoURI(_ uri: String) -> Bool {
        let lower = uri.lowercased()
        guard lower.hasSuffix(".mp4") || lower.hasSuffix(".insv") else {
            return false
        }
        return !lower.contains("lrv")
    }

    private static func sortKey(_ uri: String) -> String {
        let lower = uri.lowercased()
        let extRank = lower.hasSuffix(".mp4") ? "2" : "1"
        return "\(timestampToken(in: lower) ?? "00000000000000")|\(extRank)|\(lower)"
    }

    private static func timestampToken(in uri: String) -> String? {
        let chars = Array(uri)
        guard chars.count >= 14 else { return nil }

        for idx in chars.indices {
            var digits = ""
            var cursor = idx
            while cursor < chars.endIndex, digits.count < 14 {
                let ch = chars[cursor]
                if ch >= "0" && ch <= "9" {
                    digits.append(ch)
                } else if ch == "_" || ch == "-" {
                    // Accept common VID_YYYYMMDD_HHMMSS / VID_YYYY-MM-DD-HHMMSS variants.
                } else {
                    break
                }
                cursor = chars.index(after: cursor)
            }
            if digits.count >= 14 {
                return String(digits.prefix(14))
            }
        }
        return nil
    }
}
