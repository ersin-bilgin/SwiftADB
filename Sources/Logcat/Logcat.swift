import Foundation
import SwiftADBClient
import SwiftADBShell

/// Logcat record level.
public enum LogcatPriority: String, Sendable, CaseIterable {
    case verbose = "V"
    case debug = "D"
    case info = "I"
    case warning = "W"
    case error = "E"
    case fatal = "F"

    init?(symbol: Character) {
        self.init(rawValue: String(symbol))
    }
}

/// A single logcat line.
public struct LogcatEntry: Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let priority: LogcatPriority
    public let tag: String
    public let pid: Int
    public let message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        priority: LogcatPriority,
        tag: String,
        pid: Int,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.priority = priority
        self.tag = tag
        self.pid = pid
        self.message = message
    }
}

/// Logcat filter options.
public struct LogcatFilter: Sendable {
    public var tag: String?
    public var priority: LogcatPriority?
    public var pid: Int?

    public init(tag: String? = nil, priority: LogcatPriority? = nil, pid: Int? = nil) {
        self.tag = tag
        self.priority = priority
        self.pid = pid
    }

    func matches(_ entry: LogcatEntry) -> Bool {
        if let tag, entry.tag != tag { return false }
        if let priority, entry.priority != priority { return false }
        if let pid, entry.pid != pid { return false }
        return true
    }
}

public enum LogcatError: Error, Sendable {
    case notConnected
    case streamFailed(String)
}

/// ADB logcat service.
public protocol ADBLogcatService: Sendable {
    func stream(filter: LogcatFilter?) async throws -> AsyncStream<LogcatEntry>
    func clear() async throws
}

public final class DefaultLogcatService: ADBLogcatService, @unchecked Sendable {
    private let client: ADBClient
    private let shell: DefaultShellService

    public init(client: ADBClient) {
        self.client = client
        self.shell = DefaultShellService(client: client)
    }

    public func stream(filter: LogcatFilter? = nil) async throws -> AsyncStream<LogcatEntry> {
        guard client.device != nil else { throw LogcatError.notConnected }

        var command = "logcat -v brief"
        if let filter, let priority = filter.priority {
            command += " *:\(priority.rawValue)"
        }

        let textStream = try await shell.stream(command)

        return AsyncStream { continuation in
            Task {
                for await chunk in textStream {
                    for line in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
                        if let entry = Self.parseLine(String(line)), filter?.matches(entry) ?? true {
                            continuation.yield(entry)
                        }
                    }
                }
                continuation.finish()
            }
        }
    }

    public func clear() async throws {
        _ = try await shell.execute("logcat -c")
    }

    public static func parseLine(_ line: String) -> LogcatEntry? {
        // brief format: I/tag(pid): message
        guard line.count >= 5,
              let slash = line.firstIndex(of: "/"),
              let parenOpen = line.firstIndex(of: "("),
              let parenClose = line.firstIndex(of: ")"),
              let colon = line.firstIndex(of: ":"),
              colon > parenClose else {
            return nil
        }

        let priorityChar = line[line.startIndex]
        guard let priority = LogcatPriority(symbol: priorityChar) else { return nil }

        let tag = String(line[line.index(after: slash)..<parenOpen])
        let pid = Int(line[line.index(after: parenOpen)..<parenClose].filter(\.isNumber)) ?? 0
        let message = String(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))

        return LogcatEntry(priority: priority, tag: tag, pid: pid, message: message)
    }
}
