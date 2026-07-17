import Foundation

/// Test ve simülasyon için sahte ADB cihazı transport'u.
public final class MockADBTransport: ADBTransport, @unchecked Sendable {
    public let host: String
    public let port: UInt16

    public var requireAuth: Bool
    public var deviceBanner: String
    public var authToken: Data
    public var shellResponses: [String: Data]
    public var serviceResponses: [String: Data]

    private let state = MockState()

    public init(
        host: String = "mock-device",
        port: UInt16 = 5555,
        requireAuth: Bool = false,
        deviceBanner: String = "device:product:MockPhone:device:ABC123"
    ) {
        self.host = host
        self.port = port
        self.requireAuth = requireAuth
        self.deviceBanner = deviceBanner
        self.authToken = Data((0..<ADBProtocol.tokenSize).map { _ in UInt8.random(in: 0...255) })
        self.shellResponses = [:]
        self.serviceResponses = [:]
    }

    public var isConnected: Bool {
        get async { state.connected }
    }

    public func connect() async throws {
        state.connected = true
        state.authenticated = !requireAuth
    }

    public func disconnect() async {
        state.reset()
    }

    public func send(header: ADBMessageHeader, payload: Data?) async throws {
        guard await isConnected else { throw TransportError.notConnected }
        let body = payload ?? Data()

        switch header.command {
        case .cnxn:
            if requireAuth && !state.authenticated {
                enqueue(message: .auth, arg0: ADBAuthType.token.rawValue, payload: authToken)
            } else {
                enqueueCNXN()
            }

        case .auth:
            if header.arg0 == ADBAuthType.signature.rawValue || header.arg0 == ADBAuthType.rsaPublicKey.rawValue {
                state.authenticated = true
                enqueueCNXN()
            }

        case .open:
            let localID = header.arg0
            let destination = String(data: body.filter { $0 != 0 }, encoding: .utf8) ?? ""
            let remoteID = state.allocateRemoteID()
            state.setDestination(remoteID: remoteID, destination: destination)
            enqueue(message: .okay, arg0: remoteID, arg1: localID)

            if let response = shellResponses[destination] ?? serviceResponses[destination] {
                enqueue(message: .wrte, arg0: remoteID, arg1: localID, payload: response)
                enqueue(message: .clse, arg0: remoteID, arg1: localID)
            }

        case .wrte:
            let remoteID = header.arg1
            if state.destination(for: remoteID) == "sync:", let response = serviceResponses["sync:"] {
                enqueue(message: .wrte, arg0: remoteID, arg1: header.arg0, payload: response)
            }
            enqueue(message: .okay, arg0: header.arg1, arg1: header.arg0)

        case .clse, .okay, .stls:
            break

        default:
            break
        }
    }

    public func receiveHeader() async throws -> ADBMessageHeader {
        try await receiveMessage().header
    }

    public func receivePayload(length: Int) async throws -> Data {
        _ = length
        throw TransportError.invalidMessage
    }

    public func receiveMessage() async throws -> ADBMessage {
        guard await isConnected else { throw TransportError.notConnected }
        while true {
            if let packet = state.dequeue() {
                let headerData = packet.prefix(ADBMessageHeader.size)
                let header = try ADBMessageCodec.decodeHeader(from: headerData)
                let payload = packet.count > ADBMessageHeader.size
                    ? packet.subdata(in: ADBMessageHeader.size..<packet.count)
                    : Data()
                return ADBMessage(header: header, payload: payload)
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    public func upgradeToTLS(identity: SecIdentity) async throws {
        _ = identity
    }

    public func sendRaw(_ data: Data) async throws {
        _ = data
    }

    public func receiveRaw(count: Int) async throws -> Data {
        _ = count
        return Data()
    }

    private func enqueueCNXN() {
        var banner = Data(deviceBanner.utf8)
        banner.append(0)
        enqueue(message: .cnxn, arg0: ADBProtocol.version, arg1: ADBProtocol.maxDataSize, payload: banner)
    }

    private func enqueue(message: ADBCommand, arg0: UInt32 = 0, arg1: UInt32 = 0, payload: Data = Data()) {
        let packet = ADBMessageCodec.encode(
            header: ADBMessageHeader(command: message, arg0: arg0, arg1: arg1),
            payload: payload
        )
        state.enqueue(packet)
    }
}

private enum ADBAuthType: UInt32 {
    case token = 1
    case signature = 2
    case rsaPublicKey = 3
}

private final class MockState: @unchecked Sendable {
    private let lock = NSLock()
    var connected = false
    var authenticated = false
    private var receiveQueue: [Data] = []
    private var remoteIDCounter: UInt32 = 1
    private var streamDestinations: [UInt32: String] = [:]

    func reset() {
        lock.lock()
        connected = false
        authenticated = false
        receiveQueue.removeAll()
        streamDestinations.removeAll()
        lock.unlock()
    }

    func allocateRemoteID() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        let id = remoteIDCounter
        remoteIDCounter &+= 1
        return id
    }

    func setDestination(remoteID: UInt32, destination: String) {
        lock.lock()
        streamDestinations[remoteID] = destination
        lock.unlock()
    }

    func destination(for remoteID: UInt32) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return streamDestinations[remoteID]
    }

    func enqueue(_ packet: Data) {
        lock.lock()
        receiveQueue.append(packet)
        lock.unlock()
    }

    func dequeue() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !receiveQueue.isEmpty else { return nil }
        return receiveQueue.removeFirst()
    }
}
