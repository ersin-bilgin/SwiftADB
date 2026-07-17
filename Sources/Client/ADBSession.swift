import Foundation
import SwiftADBAuthentication
import SwiftADBTransport

/// ADB oturumu — tek okuyucu ile mesaj yönlendirme.
public actor ADBSession {
    private let transport: TransportBox
    private let keyStore: any ADBKeyStore
    private let authenticator: any ADBAuthenticator

    private var nextLocalID: UInt32 = 1
    private var streams: [UInt32: ADBStream] = [:]
    private var deviceBanner: String?
    private var readerTask: Task<Void, Never>?
    private var connected = false

    private var openWaiters: [UInt32: CheckedContinuation<UInt32, Error>] = [:]
    private var writeWaiters: [String: CheckedContinuation<Void, Error>] = [:]

    private static let handshakeTimeoutNanoseconds: UInt64 = 20_000_000_000
    private static let tvApprovalTimeoutNanoseconds: UInt64 = 30_000_000_000
    private static let writeTimeoutNanoseconds: UInt64 = 15_000_000_000

    public init(
        transport: any ADBTransport,
        keyStore: any ADBKeyStore,
        authenticator: any ADBAuthenticator = DefaultAuthenticator()
    ) {
        self.transport = TransportBox(transport)
        self.keyStore = keyStore
        self.authenticator = authenticator
    }

    public var banner: String? { deviceBanner }
    public var isConnected: Bool { connected }

    public func connect() async throws {
        ADBLog.info("ADB oturumu başlatılıyor: \(transport.transport.host):\(transport.transport.port)", category: "Session")
        try await transport.transport.connect()

        let bannerData = Data(ADBProtocol.defaultBanner.utf8)
        try await transport.transport.send(
            header: ADBMessageHeader(
                command: .cnxn,
                arg0: ADBProtocol.version,
                arg1: ADBProtocol.maxDataSize
            ),
            payload: bannerData
        )

        try await performHandshake()
        startReader()
        connected = true
        ADBLog.info("ADB oturumu hazır: \(deviceBanner ?? "unknown")", category: "Session")
    }

    public func disconnect() async {
        readerTask?.cancel()
        readerTask = nil
        for (_, waiter) in openWaiters {
            waiter.resume(throwing: ADBClientError.notConnected)
        }
        openWaiters.removeAll()
        for (_, waiter) in writeWaiters {
            waiter.resume(throwing: ADBClientError.notConnected)
        }
        writeWaiters.removeAll()
        for stream in streams.values {
            await stream.markClosed()
        }
        streams.removeAll()
        connected = false
        await transport.transport.disconnect()
    }

    public func openStream(_ destination: String) async throws -> ADBStream {
        let localID = nextLocalID
        nextLocalID &+= 1

        var payload = Data(destination.utf8)
        payload.append(0)

        let stream = ADBStream(localID: localID, destination: destination, session: self)
        streams[localID] = stream

        ADBLog.debug("Servis açılıyor: \(destination) (local=\(localID))", category: "Session")

        let remoteID = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt32, Error>) in
            openWaiters[localID] = continuation
            Task {
                do {
                    try await transport.transport.send(
                        header: ADBMessageHeader(command: .open, arg0: localID, arg1: 0),
                        payload: payload
                    )
                } catch {
                    openWaiters.removeValue(forKey: localID)
                    continuation.resume(throwing: error)
                }
            }
        }

        await stream.setRemoteID(remoteID)
        return stream
    }

    func write(_ data: Data, localID: UInt32, remoteID: UInt32) async throws {
        let key = writeKey(localID: localID, remoteID: remoteID)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.waitForWriteAck(key: key, localID: localID, remoteID: remoteID, data: data)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: Self.writeTimeoutNanoseconds)
                await self.timeoutWriteWaiter(key: key, localID: localID)
                throw ADBClientError.connectionFailed("WRTE zaman aşımı (local=\(localID))")
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func waitForWriteAck(
        key: String,
        localID: UInt32,
        remoteID: UInt32,
        data: Data
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeWaiters[key] = continuation
            Task {
                do {
                    try await transport.transport.send(
                        header: ADBMessageHeader(command: .wrte, arg0: localID, arg1: remoteID),
                        payload: data
                    )
                } catch {
                    if let waiter = writeWaiters.removeValue(forKey: key) {
                        waiter.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func timeoutWriteWaiter(key: String, localID: UInt32) {
        if let waiter = writeWaiters.removeValue(forKey: key) {
            waiter.resume(throwing: ADBClientError.connectionFailed("WRTE zaman aşımı (local=\(localID))"))
        }
    }

    func closeStream(localID: UInt32, remoteID: UInt32) async throws {
        try await transport.transport.send(
            header: ADBMessageHeader(command: .clse, arg0: localID, arg1: remoteID),
            payload: nil
        )
        streams.removeValue(forKey: localID)
    }

    private func performHandshake() async throws {
        while true {
            let message = try await receiveHandshakeMessage(timeoutNanoseconds: Self.handshakeTimeoutNanoseconds)
            switch message.command {
            case .cnxn:
                deviceBanner = String(data: message.payload.filter { $0 != 0 }, encoding: .utf8)
                return

            case .auth:
                try await completeRSAAuthFlow(firstAuth: message)
                return

            case .stls:
                ADBLog.info("TLS yükseltmesi başlatılıyor", category: "Session")
                try await transport.transport.send(
                    header: ADBMessageHeader(command: .stls, arg0: 1, arg1: 0),
                    payload: nil
                )
                let identity = try keyStore.secIdentity()
                try await transport.transport.upgradeToTLS(identity: identity)

            default:
                throw ADBClientError.connectionFailed("Beklenmeyen el sıkışma mesajı: \(message.command)")
            }
        }
    }

    /// iRemoteController / ADBAppFetcher ile birebir aynı akış.
    private func completeRSAAuthFlow(firstAuth: ADBMessage) async throws {
        guard firstAuth.header.arg0 == ADBAuthType.token.rawValue,
              firstAuth.payload.count >= ADBProtocol.tokenSize else {
            throw AuthenticationError.invalidToken
        }

        let token = firstAuth.payload.prefix(ADBProtocol.tokenSize)
        ADBLog.info("Kimlik doğrulama: token imzalanıyor", category: "Session")

        let signature = try keyStore.signToken(Data(token))
        try await transport.transport.send(
            header: ADBMessageHeader(command: .auth, arg0: ADBAuthType.signature.rawValue),
            payload: signature
        )

        let afterSign = try await receiveHandshakeMessage(timeoutNanoseconds: Self.handshakeTimeoutNanoseconds)
        if afterSign.command == .cnxn {
            deviceBanner = String(data: afterSign.payload.filter { $0 != 0 }, encoding: .utf8)
            ADBLog.info("Anahtar TV'de kayıtlı — bağlantı kuruldu", category: "Session")
            return
        }

        guard afterSign.command == .auth else {
            throw AuthenticationError.unexpectedMessage(String(describing: afterSign.command))
        }

        ADBLog.info(
            "Yeni anahtar algılandı (AUTH arg0=\(afterSign.header.arg0)) — public key gönderiliyor",
            category: "Session"
        )
        try await sendPublicKey()

        let afterPublicKey = try await receiveHandshakeMessage(timeoutNanoseconds: Self.tvApprovalTimeoutNanoseconds)
        guard afterPublicKey.command == .cnxn else {
            throw AuthenticationError.awaitingTVApproval
        }

        deviceBanner = String(data: afterPublicKey.payload.filter { $0 != 0 }, encoding: .utf8)
        ADBLog.info("TV onayı alındı — bağlantı kuruldu", category: "Session")
    }

    private func sendPublicKey() async throws {
        let payload = try keyStore.adbPublicKeyWireData()
        ADBLog.info(
            "Public key gönderildi (\(payload.count) bayt). TV ekranında 'USB hata ayıklamaya izin ver' onayını bekleyin…",
            category: "Session"
        )
        try await transport.transport.send(
            header: ADBMessageHeader(command: .auth, arg0: ADBAuthType.rsaPublicKey.rawValue),
            payload: payload
        )
        ADBLog.debug("Pubkey: \(String(data: payload.prefix(48), encoding: .utf8) ?? "?")…", category: "Session")
    }

    private func receiveHandshakeMessage(timeoutNanoseconds: UInt64) async throws -> ADBMessage {
        try await withThrowingTaskGroup(of: ADBMessage.self) { group in
            group.addTask {
                try await self.transport.transport.receiveMessage()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw AuthenticationError.handshakeTimeout
            }
            guard let message = try await group.next() else {
                throw AuthenticationError.handshakeTimeout
            }
            group.cancelAll()
            return message
        }
    }

    private func startReader() {
        readerTask?.cancel()
        readerTask = Task {
            while !Task.isCancelled {
                do {
                    let message = try await transport.transport.receiveMessage()
                    await route(message)
                } catch {
                    ADBLog.warning("Okuyucu döngüsü sonlandı: \(error)", category: "Session")
                    await shutdownStreams()
                    connected = false
                    break
                }
            }
        }
    }

    private func route(_ message: ADBMessage) async {
        switch message.command {
        case .okay:
            let localID = message.header.arg1
            ADBLog.debug(
                "OKAY local=\(localID) remote=\(message.header.arg0) openWaiters=\(openWaiters.count) writeWaiters=\(writeWaiters.count)",
                category: "Session"
            )
            if let waiter = openWaiters.removeValue(forKey: localID) {
                waiter.resume(returning: message.header.arg0)
                return
            }
            let key = writeKey(localID: message.header.arg1, remoteID: message.header.arg0)
            if let waiter = writeWaiters.removeValue(forKey: key) {
                waiter.resume()
            }

        case .wrte:
            let localID = message.header.arg1
            ADBLog.debug(
                "WRTE local=\(localID) remote=\(message.header.arg0) payload=\(message.payload.count)",
                category: "Session"
            )
            if let stream = streams[localID] {
                await stream.append(message.payload)
                try? await transport.transport.send(
                    header: ADBMessageHeader(
                        command: .okay,
                        arg0: localID,
                        arg1: message.header.arg0
                    ),
                    payload: nil
                )
            }

        case .clse:
            let localID = message.header.arg1
            await streams[localID]?.markClosed()
            streams.removeValue(forKey: localID)
            try? await transport.transport.send(
                header: ADBMessageHeader(
                    command: .clse,
                    arg0: localID,
                    arg1: message.header.arg0
                ),
                payload: nil
            )

        default:
            break
        }
    }

    private func shutdownStreams() async {
        for (_, waiter) in openWaiters {
            waiter.resume(throwing: ADBClientError.notConnected)
        }
        openWaiters.removeAll()
        for (_, waiter) in writeWaiters {
            waiter.resume(throwing: ADBClientError.notConnected)
        }
        writeWaiters.removeAll()
        for stream in streams.values {
            await stream.markClosed()
        }
        streams.removeAll()
    }

    private func writeKey(localID: UInt32, remoteID: UInt32) -> String {
        "\(localID)-\(remoteID)"
    }
}
