import Foundation

public enum ADBLogLevel: Int, Sendable, Comparable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    public static func < (lhs: ADBLogLevel, rhs: ADBLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ADBLogEntry: Sendable {
    public let level: ADBLogLevel
    public let category: String
    public let message: String
    public let timestamp: Date

    public init(level: ADBLogLevel, category: String, message: String, timestamp: Date = Date()) {
        self.level = level
        self.category = category
        self.message = message
        self.timestamp = timestamp
    }
}

/// SwiftADB loglama arabirimi.
public protocol ADBLogger: Sendable {
    func log(_ entry: ADBLogEntry)
}

public struct ConsoleADBLogger: ADBLogger, Sendable {
    public let minimumLevel: ADBLogLevel

    public init(minimumLevel: ADBLogLevel = .info) {
        self.minimumLevel = minimumLevel
    }

    public func log(_ entry: ADBLogEntry) {
        guard entry.level >= minimumLevel else { return }
        let prefix: String
        switch entry.level {
        case .debug: prefix = "🔍"
        case .info: prefix = "ℹ️"
        case .warning: prefix = "⚠️"
        case .error: prefix = "❌"
        }
        fputs("\(prefix) [\(entry.category)] \(entry.message)\n", stderr)
    }
}

/// Logger that forwards log entries via callback (for UI / tests).
public struct CallbackADBLogger: ADBLogger, Sendable {
    public let minimumLevel: ADBLogLevel
    private let handler: @Sendable (ADBLogEntry) -> Void

    public init(minimumLevel: ADBLogLevel = .info, handler: @escaping @Sendable (ADBLogEntry) -> Void) {
        self.minimumLevel = minimumLevel
        self.handler = handler
    }

    public func log(_ entry: ADBLogEntry) {
        guard entry.level >= minimumLevel else { return }
        handler(entry)
    }
}

/// Writes to multiple loggers at once.
public struct MultiplexADBLogger: ADBLogger, Sendable {
    private let loggers: [any ADBLogger]

    public init(_ loggers: [any ADBLogger]) {
        self.loggers = loggers
    }

    public func log(_ entry: ADBLogEntry) {
        for logger in loggers {
            logger.log(entry)
        }
    }
}

public struct NullADBLogger: ADBLogger, Sendable {
    public init() {}
    public func log(_ entry: ADBLogEntry) {}
}

public enum ADBLog {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var _logger: any ADBLogger = NullADBLogger()

    public static var logger: any ADBLogger {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _logger
        }
        set {
            lock.lock()
            _logger = newValue
            lock.unlock()
        }
    }

    public static func debug(_ message: String, category: String = "SwiftADB") {
        logger.log(ADBLogEntry(level: .debug, category: category, message: message))
    }

    public static func info(_ message: String, category: String = "SwiftADB") {
        logger.log(ADBLogEntry(level: .info, category: category, message: message))
    }

    public static func warning(_ message: String, category: String = "SwiftADB") {
        logger.log(ADBLogEntry(level: .warning, category: category, message: message))
    }

    public static func error(_ message: String, category: String = "SwiftADB") {
        logger.log(ADBLogEntry(level: .error, category: category, message: message))
    }
}
