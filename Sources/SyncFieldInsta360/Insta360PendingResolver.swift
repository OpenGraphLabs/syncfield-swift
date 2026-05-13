import Foundation

internal enum Insta360PendingResolver {
    struct Window: Sendable {
        let startWallMs: UInt64
        let endWallMs: UInt64
        let expectedDurationSec: UInt?
        let expectedSegments: Int?
        let toleranceMs: UInt64

        init(
            startWallMs: UInt64,
            endWallMs: UInt64,
            expectedDurationSec: UInt? = nil,
            expectedSegments: Int? = nil,
            toleranceMs: UInt64 = 30_000
        ) {
            self.startWallMs = startWallMs
            self.endWallMs = endWallMs
            self.expectedDurationSec = expectedDurationSec
            self.expectedSegments = expectedSegments
            self.toleranceMs = toleranceMs
        }
    }

    static func matchSegments(uris: [String], window: Window) -> [String] {
        let candidates = uris.compactMap { uri -> (uri: String, timestampMs: UInt64)? in
            guard isDownloadableVideo(uri),
                  let timestampMs = parseFilenameTimestampMs(uri)
            else {
                return nil
            }
            return (uri, timestampMs)
        }

        let lo = window.startWallMs > window.toleranceMs
            ? window.startWallMs - window.toleranceMs
            : 0
        let hi = window.endWallMs + window.toleranceMs
        let inWindow = candidates
            .filter { $0.timestampMs >= lo && $0.timestampMs <= hi }
            .sorted { $0.timestampMs < $1.timestampMs }

        if window.expectedSegments == 1 {
            guard let pick = inWindow.min(by: {
                distance($0.timestampMs, to: window.startWallMs)
                    < distance($1.timestampMs, to: window.startWallMs)
            }) else {
                return []
            }
            return [pick.uri]
        }

        return inWindow.map(\.uri)
    }

    private static func isDownloadableVideo(_ uri: String) -> Bool {
        let lower = uri.lowercased()
        guard lower.hasSuffix(".mp4") || lower.hasSuffix(".insv") else {
            return false
        }
        return !lower.contains("lrv")
    }

    private static func distance(_ lhs: UInt64, to rhs: UInt64) -> UInt64 {
        lhs > rhs ? lhs - rhs : rhs - lhs
    }

    /// Parses Insta360-style names such as VID_20260513_220000_001.mp4.
    /// Camera time is synced from the phone before capture, so the filename
    /// token is interpreted as an epoch-compatible UTC wall-clock timestamp.
    static func parseFilenameTimestampMs(_ uri: String) -> UInt64? {
        guard let token = timestampToken(in: uri) else { return nil }
        let year = Int(token.prefix(4))
        let month = Int(token.dropFirst(4).prefix(2))
        let day = Int(token.dropFirst(6).prefix(2))
        let hour = Int(token.dropFirst(8).prefix(2))
        let minute = Int(token.dropFirst(10).prefix(2))
        let second = Int(token.dropFirst(12).prefix(2))
        guard let year, let month, let day, let hour, let minute, let second else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let date = calendar.date(from: components) else { return nil }
        return UInt64(date.timeIntervalSince1970 * 1000)
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
                    // Accept common VID_YYYYMMDD_HHMMSS and dashed variants.
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
