import Foundation
import Network

#if os(iOS)
/// Triggers iOS 14+ local network permission. Required for TCP connections to a TV.
@MainActor
public final class LocalNetworkPermission: ObservableObject {
    public enum Status: Equatable, Sendable {
        case unknown
        case checking
        case granted
        case denied

        public var label: String {
            switch self {
            case .unknown: return "Not checked"
            case .checking: return "Checking local network permission…"
            case .granted: return "Local network permission granted"
            case .denied: return "Local network permission denied"
            }
        }
    }

    @Published public private(set) var status: Status = .unknown

    public static let settingsHint = """
    iPhone Settings → Privacy & Security → Local Network → SwiftADB Test → On

    This permission is required to connect to a TV over Wi‑Fi.
    """

    public init() {}

    public func refresh() async {
        status = .checking
        status = await Self.probe()
    }

    private static func probe() async -> Status {
        await withCheckedContinuation { continuation in
            final class Box: @unchecked Sendable {
                private let lock = NSLock()
                private var finished = false
                private let continuation: CheckedContinuation<Status, Never>

                init(_ continuation: CheckedContinuation<Status, Never>) {
                    self.continuation = continuation
                }

                func finish(_ value: Status, browser: NWBrowser) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !finished else { return }
                    finished = true
                    browser.cancel()
                    continuation.resume(returning: value)
                }
            }

            let box = Box(continuation)
            let browser = NWBrowser(for: .bonjour(type: "_adb._tcp", domain: nil), using: .tcp)
            browser.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.finish(.granted, browser: browser)
                case .failed(let error):
                    box.finish(isDenied(error) ? .denied : .granted, browser: browser)
                case .waiting(let error):
                    if isDenied(error) {
                        box.finish(.denied, browser: browser)
                    }
                default:
                    break
                }
            }
            browser.start(queue: .global(qos: .userInitiated))

            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                box.finish(.granted, browser: browser)
            }
        }
    }

    private nonisolated static func isDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error, code == kDNSServiceErr_PolicyDenied { return true }
        return false
    }
}
#endif
