import Foundation
import SwiftADBAuthentication
import SwiftADBDeviceDiscovery
import SwiftADBPairing
import SwiftADBTransport

/// Bağlantı türü.
public enum ADBConnectionType: Sendable {
    case tcp(host: String, port: UInt16)
    case usb(deviceID: Int, port: UInt16)
    case custom(any ADBTransport)
}

/// Bağlı ADB cihazı.
public struct ADBDevice: Sendable, Identifiable {
    public let id: String
    public let serial: String
    public let model: String?
    public let host: String
    public let port: UInt16
    public let banner: String?
    public let connectionType: ADBConnectionType

    public init(
        id: String,
        serial: String,
        model: String? = nil,
        host: String,
        port: UInt16,
        banner: String? = nil,
        connectionType: ADBConnectionType
    ) {
        self.id = id
        self.serial = serial
        self.model = model
        self.host = host
        self.port = port
        self.banner = banner
        self.connectionType = connectionType
    }
}

public enum ADBClientError: Error, Sendable {
    case notConnected
    case connectionFailed(String)
    case serviceUnavailable(String)
}

/// Ana ADB istemci.
public final class ADBClient: @unchecked Sendable {
    private let keyStore: any ADBKeyStore
    private let authenticator: any ADBAuthenticator
    private let pairingClient: any ADBPairingClient
    private var session: ADBSession?
    private var currentDevice: ADBDevice?

    public init(
        keyStore: any ADBKeyStore = FileKeyStore(),
        authenticator: any ADBAuthenticator = DefaultAuthenticator(),
        pairingClient: any ADBPairingClient = DefaultPairingClient()
    ) {
        self.keyStore = keyStore
        self.authenticator = authenticator
        self.pairingClient = pairingClient
    }

    public var device: ADBDevice? { currentDevice }

    public func pair(host: String, port: UInt16, code: String) async throws {
        let session = PairingSession(host: host, port: port, method: .pairingCode(code))
        try await pairingClient.pair(session: session, keyStore: keyStore)
    }

    public func connect(host: String, port: UInt16 = 5555) async throws {
        try await connect(type: .tcp(host: host, port: port))
    }

    public func connect(to discovered: DiscoveredDevice) async throws {
        try await connect(host: discovered.host, port: discovered.port)
    }

    public func connectUSB(deviceID: Int, port: UInt16 = 5555) async throws {
        #if os(macOS)
        try await connect(type: .usb(deviceID: deviceID, port: port))
        #else
        throw ADBClientError.connectionFailed("USB ADB yalnızca macOS'ta desteklenir")
        #endif
    }

    public func connect(transport: any ADBTransport) async throws {
        try await connect(type: .custom(transport))
    }

    public func connect(type: ADBConnectionType) async throws {
        let transport: any ADBTransport
        let host: String
        let port: UInt16

        switch type {
        case .tcp(let h, let p):
            transport = TCPTransport(host: h, port: p)
            host = h
            port = p
        case .usb(let deviceID, let p):
            #if os(macOS)
            transport = UsbMuxTransport(deviceID: deviceID, port: p)
            host = "usb:\(deviceID)"
            port = p
            #else
            throw ADBClientError.connectionFailed("USB ADB yalnızca macOS'ta desteklenir")
            #endif
        case .custom(let custom):
            transport = custom
            host = custom.host
            port = custom.port
        }

        let session = ADBSession(transport: transport, keyStore: keyStore, authenticator: authenticator)
        try await session.connect()

        self.session = session
        let banner = await session.banner
        let serial = parseSerial(from: banner) ?? host
        currentDevice = ADBDevice(
            id: serial,
            serial: serial,
            model: parseModel(from: banner),
            host: host,
            port: port,
            banner: banner,
            connectionType: type
        )
    }

    public func disconnect() async {
        if let session {
            await session.disconnect()
        }
        session = nil
        currentDevice = nil
    }

    public func openStream(_ destination: String) async throws -> ADBStream {
        guard let session else { throw ADBClientError.notConnected }
        return try await session.openStream(destination)
    }

    public func openService(_ name: String) async throws -> ADBStream {
        try await openStream(name)
    }

    private func parseSerial(from banner: String?) -> String? {
        guard let banner else { return nil }
        let parts = banner.split(separator: ":")
        if parts.count >= 5, parts[0] == "device" {
            return String(parts[4])
        }
        if parts.count >= 2, parts[0] == "host" {
            return String(parts[1])
        }
        return banner
    }

    private func parseModel(from banner: String?) -> String? {
        guard let banner else { return nil }
        let parts = banner.split(separator: ":")
        if parts.count >= 3, parts[0] == "device" {
            return String(parts[2])
        }
        return nil
    }
}
