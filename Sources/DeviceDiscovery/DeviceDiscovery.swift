import Foundation
import Network
import SwiftADBTransport

/// Keşfedilen ADB cihazı.
public struct DiscoveredDevice: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let host: String
    public let port: UInt16
    public let serviceType: ServiceType
    public let transportID: String?

    public enum ServiceType: String, Sendable {
        case adb = "_adb._tcp"
        case pairing = "_adb-tls-pairing._tcp"
    }

    public init(
        id: String,
        name: String,
        host: String,
        port: UInt16 = 5555,
        serviceType: ServiceType = .adb,
        transportID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.serviceType = serviceType
        self.transportID = transportID
    }
}

public enum DeviceDiscoveryError: Error, Sendable {
    case browseFailed(String)
    case permissionDenied
}

/// Ağ üzerinde ADB cihazlarını keşfeder.
public protocol DeviceDiscoverer: Sendable {
    func startBrowsing() async throws -> AsyncStream<DiscoveredDevice>
    func stopBrowsing() async
}

/// Bonjour/mDNS ile ADB cihaz keşfi.
public final class BonjourDeviceDiscoverer: DeviceDiscoverer, @unchecked Sendable {
    private var browser: NWBrowser?
    private var continuation: AsyncStream<DiscoveredDevice>.Continuation?
    private let queue = DispatchQueue(label: "com.swiftadb.discovery")

    public init() {}

    public func startBrowsing() async throws -> AsyncStream<DiscoveredDevice> {
        await stopBrowsing()

        return AsyncStream { continuation in
            self.continuation = continuation

            let parameters = NWParameters()
            parameters.includePeerToPeer = true

            let browser = NWBrowser(
                for: .bonjour(type: DiscoveredDevice.ServiceType.adb.rawValue, domain: "local."),
                using: parameters
            )
            self.browser = browser

            browser.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    continuation.finish()
                    self.continuation = nil
                    _ = error
                }
            }

            browser.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self else { return }
                for result in results {
                    if case let .service(name, _, _, _) = result.endpoint {
                        self.resolve(result: result, name: name)
                    }
                }
            }

            browser.start(queue: queue)
            continuation.onTermination = { @Sendable _ in
                Task { await self.stopBrowsing() }
            }
        }
    }

    public func stopBrowsing() async {
        browser?.cancel()
        browser = nil
        continuation?.finish()
        continuation = nil
    }

    private func resolve(result: NWBrowser.Result, name: String) {
        let connection = NWConnection(to: result.endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                if case let .hostPort(host, port) = connection.currentPath?.remoteEndpoint {
                    let device = DiscoveredDevice(
                        id: name,
                        name: name,
                        host: "\(host)",
                        port: port.rawValue,
                        serviceType: .adb
                    )
                    self.continuation?.yield(device)
                }
                connection.cancel()
            }
        }
        connection.start(queue: queue)
    }
}

/// Manuel IP/port ile cihaz oluşturucu.
public enum DeviceFactory {
    public static func manual(host: String, port: UInt16 = 5555, name: String? = nil) -> DiscoveredDevice {
        DiscoveredDevice(
            id: "\(host):\(port)",
            name: name ?? host,
            host: host,
            port: port
        )
    }
}
