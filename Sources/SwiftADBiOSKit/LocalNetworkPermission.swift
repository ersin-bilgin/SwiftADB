import Foundation
import Network

#if os(iOS)
/// iOS 14+ yerel ağ iznini tetikler. TV'ye TCP bağlantısı için zorunludur.
@MainActor
public final class LocalNetworkPermission: ObservableObject {
    public enum Status: Equatable, Sendable {
        case unknown
        case checking
        case granted
        case denied

        public var label: String {
            switch self {
            case .unknown: return "Kontrol edilmedi"
            case .checking: return "Yerel ağ izni kontrol ediliyor…"
            case .granted: return "Yerel ağ izni verildi"
            case .denied: return "Yerel ağ izni reddedildi"
            }
        }
    }

    @Published public private(set) var status: Status = .unknown

    public static let settingsHint = """
    iPhone Ayarlar → Gizlilik ve Güvenlik → Yerel Ağ → SwiftADB Test → Açık

    TV'ye Wi‑Fi üzerinden bağlanmak için bu izin zorunludur.
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
