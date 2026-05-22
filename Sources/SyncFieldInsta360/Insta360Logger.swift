import Foundation
import os

/// Categories for the Insta360 connection coordinator family of logs. Each
/// category maps to an `os.Logger` keyed on the same OSLog subsystem so that
/// Console.app can show the entire `com.opengraph.ogskill.insta360` subsystem
/// with a single filter while still letting users drill into one area.
public enum InstaLogCategory: String, Sendable {
    case coord   = "INSTA360.COORD"
    case sup     = "INSTA360.SUP"
    case ble     = "INSTA360.BLE"
    case wake    = "INSTA360.WAKE"
    case radio   = "INSTA360.RADIO"
    case wifi    = "INSTA360.WIFI"
    case bg      = "INSTA360.BG"
    case scan    = "INSTA360.SCAN"
    case collect = "INSTA360.COLLECT"
    case stream  = "INSTA360.STREAM"
    case bridge  = "INSTA360.BRIDGE"
    case probe   = "INSTA360.PROBE"
}

public enum InstaLogLevel: Int, Comparable, Sendable {
    case debug = 0
    case info  = 1
    case state = 2
    case warn  = 3
    case error = 4

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    fileprivate var label: String {
        switch self {
        case .debug: return "debug"
        case .info:  return "info "
        case .state: return "state"
        case .warn:  return "warn "
        case .error: return "error"
        }
    }

    fileprivate var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info:  return .info
        case .state: return .default
        case .warn:  return .error
        case .error: return .fault
        }
    }
}

/// Single entry-point for every Insta360-related log line. Goals:
///
/// 1. **Greppable**: every line starts with `[INSTA360.<CATEGORY>(.<role>)]`
///    so a single Xcode Console filter (`[INSTA360`) shows the scenario tape.
/// 2. **Structured**: event name + field map, written deterministically as
///    `key=value` pairs so failed scenarios can be diff'd line-by-line.
/// 3. **State-transition emphasis**: `.state` level lines render with a
///    horizontal separator to stand out during live scrolling.
/// 4. **Console.app friendly**: also emits through `os.Logger` keyed on a
///    fixed subsystem so on-device captures can use predicate filtering.
public enum InstaLog {
    /// Log lines below this level are dropped. Set to `.debug` during
    /// scenario verification; `.info` is the production default.
    nonisolated(unsafe) public static var minLevel: InstaLogLevel = .info

    /// OSLog subsystem. Console.app: filter `subsystem == "<this>"`.
    public static let subsystem = "com.opengraph.ogskill.insta360"

    /// Mirror to `NSLog` (Xcode Console). Disable in release builds if the
    /// double-write becomes a problem; os.Logger surface is canonical.
    nonisolated(unsafe) public static var mirrorToNSLog: Bool = true

    public static func log(
        _ category: InstaLogCategory,
        role: String? = nil,
        level: InstaLogLevel = .info,
        _ event: String,
        _ fields: [String: Any] = [:]
    ) {
        guard level >= minLevel else { return }
        let tag = role.map { "\(category.rawValue).\($0)" } ?? category.rawValue
        let body = formatFields(fields)
        let composed = "[\(tag)] \(level.label) \(event)\(body.isEmpty ? "" : " " + body)"
        emit(category: category, level: level, message: composed)
    }

    /// State-transition convenience: emits a separator-wrapped line so the
    /// reader can scan transitions at a glance. Always at `.state` level.
    public static func state(
        _ category: InstaLogCategory,
        role: String? = nil,
        from: String,
        to: String,
        reason: String? = nil
    ) {
        guard InstaLogLevel.state >= minLevel else { return }
        let tag = role.map { "\(category.rawValue).\($0)" } ?? category.rawValue
        let reasonSuffix = reason.map { " reason=\"\($0)\"" } ?? ""
        let core = "[\(tag)] STATE \(from) → \(to)\(reasonSuffix)"
        let separator = String(repeating: "─", count: 6)
        emit(category: category, level: .state, message: "\(separator) \(core) \(separator)")
    }

    // MARK: - Internals

    private static func formatFields(_ fields: [String: Any]) -> String {
        guard !fields.isEmpty else { return "" }
        // Stable ordering — easier to diff scenario captures.
        return fields.keys.sorted().map { key in
            let value = fields[key]!
            return "\(key)=\(stringify(value))"
        }.joined(separator: " ")
    }

    private static func stringify(_ value: Any) -> String {
        // Unwrap Optional<...> so callers using `value as Any` (which wraps
        // optionals into `Optional(x)`) don't leak the Optional shape into
        // log output. `rssi=Optional(-37)` → `rssi=-37`, nil → `nil`.
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            if let child = mirror.children.first {
                return stringify(child.value)
            }
            return "nil"
        }
        switch value {
        case let s as String:
            // Quote when whitespace or special chars would confuse grep.
            if s.contains(" ") || s.contains("=") || s.contains("[") || s.isEmpty {
                return "\"\(s)\""
            }
            return s
        case let arr as [Any]:
            return "[" + arr.map(stringify).joined(separator: ",") + "]"
        case let n as Bool:
            return n ? "true" : "false"
        default:
            return String(describing: value)
        }
    }

    private static let loggers: [InstaLogCategory: os.Logger] = {
        var map: [InstaLogCategory: os.Logger] = [:]
        for category in [
            InstaLogCategory.coord, .sup, .ble, .wake, .radio, .wifi, .bg, .scan,
            .collect, .stream, .bridge, .probe,
        ] {
            map[category] = os.Logger(subsystem: InstaLog.subsystem, category: category.rawValue)
        }
        return map
    }()

    private static func emit(category: InstaLogCategory, level: InstaLogLevel, message: String) {
        let logger = loggers[category] ?? os.Logger(subsystem: subsystem, category: category.rawValue)
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info:  logger.info("\(message, privacy: .public)")
        case .state: logger.notice("\(message, privacy: .public)")
        case .warn:  logger.error("\(message, privacy: .public)")
        case .error: logger.fault("\(message, privacy: .public)")
        }
        if mirrorToNSLog {
            NSLog("%@", message)
        }
    }
}
