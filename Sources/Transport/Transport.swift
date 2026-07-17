import Foundation

/// Transport layer protocol providing raw connection to an ADB device.
public protocol ADBTransport: Sendable {
    var isConnected: Bool { get async }
    var host: String { get }
    var port: UInt16 { get }

    func connect() async throws
    func disconnect() async
    func send(header: ADBMessageHeader, payload: Data?) async throws
    func receiveHeader() async throws -> ADBMessageHeader
    func receivePayload(length: Int) async throws -> Data
    func receiveMessage() async throws -> ADBMessage
    func upgradeToTLS(identity: SecIdentity) async throws
    func sendRaw(_ data: Data) async throws
    func receiveRaw(count: Int) async throws -> Data
}

public final class TCPTransport: ADBTransport, @unchecked Sendable {
    public let host: String
    public let port: UInt16

    private let connection: AsyncTCPConnection
    private let state = LockedValue(false)

    public init(host: String, port: UInt16 = 5555, tlsRequired: Bool = false, secIdentity: SecIdentity? = nil) {
        self.host = host
        self.port = port
        self.connection = AsyncTCPConnection(
            host: host,
            port: port,
            tlsRequired: tlsRequired,
            secIdentity: secIdentity
        )
    }

    public var isConnected: Bool {
        get async { state.value }
    }

    public func connect() async throws {
        try await connection.connect()
        state.value = true
    }

    public func disconnect() async {
        connection.disconnect()
        state.value = false
    }

    public func send(header: ADBMessageHeader, payload: Data?) async throws {
        guard await isConnected else { throw TransportError.notConnected }
        let packet = ADBMessageCodec.encode(header: header, payload: payload)
        try await connection.send(packet)
    }

    public func receiveHeader() async throws -> ADBMessageHeader {
        guard await isConnected else { throw TransportError.notConnected }
        let data = try await connection.receive(count: ADBMessageHeader.size)
        return try ADBMessageCodec.decodeHeader(from: data)
    }

    public func receivePayload(length: Int) async throws -> Data {
        guard await isConnected else { throw TransportError.notConnected }
        guard length > 0 else { return Data() }
        return try await connection.receive(count: length)
    }

    public func receiveMessage() async throws -> ADBMessage {
        let header = try await receiveHeader()
        let payload = try await receivePayload(length: Int(header.payloadLength))
        try ADBMessageCodec.validatePayload(payload, expectedChecksum: header.checksum)
        return ADBMessage(header: header, payload: payload)
    }

    public func upgradeToTLS(identity: SecIdentity) async throws {
        try await connection.upgradeToTLS(identity: identity)
    }

    public func sendRaw(_ data: Data) async throws {
        guard await isConnected else { throw TransportError.notConnected }
        try await connection.send(data)
    }

    public func receiveRaw(count: Int) async throws -> Data {
        guard await isConnected else { throw TransportError.notConnected }
        return try await connection.receive(count: count)
    }
}

private final class LockedValue<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()

    init(_ value: T) {
        _value = value
    }

    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            _value = newValue
            lock.unlock()
        }
    }
}
