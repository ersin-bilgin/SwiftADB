import Foundation
import SwiftADB

/// Uygulama içi ADB log paneli için paylaşılan log deposu.
@MainActor
public final class AppLogStore: ObservableObject {
    public static let shared = AppLogStore()

    @Published public private(set) var entries: [ADBLogEntry] = []
    private var installed = false

    public init() {}

    public func install(minimumLevel: ADBLogLevel = .debug) {
        guard !installed else { return }
        installed = true

        let uiLogger = CallbackADBLogger(minimumLevel: minimumLevel) { entry in
            Task { @MainActor in
                AppLogStore.shared.append(entry)
            }
        }

        #if DEBUG
        ADBLog.logger = MultiplexADBLogger([
            uiLogger,
            ConsoleADBLogger(minimumLevel: minimumLevel),
        ])
        #else
        ADBLog.logger = uiLogger
        #endif
    }

    public func clear() {
        entries.removeAll()
    }

    public func formattedLine(_ entry: ADBLogEntry) -> String {
        let time = Self.timeFormatter.string(from: entry.timestamp)
        let level: String
        switch entry.level {
        case .debug: level = "DBG"
        case .info: level = "INF"
        case .warning: level = "WRN"
        case .error: level = "ERR"
        }
        return "\(time) [\(level)] [\(entry.category)] \(entry.message)"
    }

    private func append(_ entry: ADBLogEntry) {
        entries.append(entry)
        if entries.count > 500 {
            entries.removeFirst(entries.count - 500)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
