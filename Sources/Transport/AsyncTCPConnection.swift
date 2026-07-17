import Foundation
import Network

/// Network.framework tabanlı async TCP bağlantısı.
final class AsyncTCPConnection: @unchecked Sendable {
    enum State {
        case disconnected
        case connecting
        case connected
        case failed(Error)
    }

    private let queue = DispatchQueue(label: "com.swiftadb.tcp", qos: .userInitiated)
    private var connection: NWConnection?
    private var state: State = .disconnected
    private let stateLock = NSLock()

    var host: String
    var port: UInt16
    var tlsRequired: Bool
    var secIdentity: SecIdentity?

    init(host: String, port: UInt16, tlsRequired: Bool = false, secIdentity: SecIdentity? = nil) {
        self.host = host
        self.port = port
        self.tlsRequired = tlsRequired
        self.secIdentity = secIdentity
    }

    func connect(timeout: TimeInterval = 10) async throws {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )

        let parameters: NWParameters
        if tlsRequired {
            let tlsOptions = NWProtocolTLS.Options()
            if let secIdentity {
                sec_protocol_options_set_local_identity(
                    tlsOptions.securityProtocolOptions,
                    sec_identity_create(secIdentity)!
                )
            }
            sec_protocol_options_set_verify_block(
                tlsOptions.securityProtocolOptions,
                { _, _, complete in complete(true) },
                queue
            )
            parameters = NWParameters(tls: tlsOptions)
        } else {
            parameters = .tcp
        }
        parameters.allowLocalEndpointReuse = true

        let conn = NWConnection(to: endpoint, using: parameters)
        connection = conn

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            final class ResumeBox: @unchecked Sendable {
                private let lock = NSLock()
                private var resumed = false
                private let continuation: CheckedContinuation<Void, Error>

                init(_ continuation: CheckedContinuation<Void, Error>) {
                    self.continuation = continuation
                }

                func resume(with result: Result<Void, Error>) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }

            let box = ResumeBox(continuation)

            conn.stateUpdateHandler = { [weak self] newState in
                switch newState {
                case .ready:
                    self?.setState(.connected)
                    box.resume(with: .success(()))
                case .failed(let error):
                    self?.setState(.failed(error))
                    box.resume(with: .failure(TransportError.underlying(error.localizedDescription)))
                case .cancelled:
                    self?.setState(.disconnected)
                    box.resume(with: .failure(TransportError.connectionClosed))
                default:
                    break
                }
            }

            self.setState(.connecting)
            conn.start(queue: queue)

            queue.asyncAfter(deadline: .now() + timeout) {
                box.resume(with: .failure(TransportError.timeout))
            }
        }
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        setState(.disconnected)
    }

    func send(_ data: Data) async throws {
        guard case .connected = getState(), let connection else {
            throw TransportError.notConnected
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: TransportError.underlying(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receive(count: Int) async throws -> Data {
        guard case .connected = getState(), connection != nil else {
            throw TransportError.notConnected
        }

        var buffer = Data()
        while buffer.count < count {
            let chunk = try await receiveChunk(minimum: 1, maximum: count - buffer.count)
            if chunk.isEmpty {
                throw TransportError.connectionClosed
            }
            buffer.append(chunk)
        }
        return buffer
    }

    private func receiveChunk(minimum: Int, maximum: Int) async throws -> Data {
        guard let connection else { throw TransportError.notConnected }

        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: minimum, maximumLength: maximum) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: TransportError.underlying(error.localizedDescription))
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(returning: Data())
                    return
                }
                Task {
                    do {
                        let next = try await self.receiveChunk(minimum: minimum, maximum: maximum)
                        continuation.resume(returning: next)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    func upgradeToTLS(identity: SecIdentity) async throws {
        disconnect()
        tlsRequired = true
        secIdentity = identity
        try await connect()
    }

    private func getState() -> State {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state
    }

    private func setState(_ newState: State) {
        stateLock.lock()
        state = newState
        stateLock.unlock()
    }
}
