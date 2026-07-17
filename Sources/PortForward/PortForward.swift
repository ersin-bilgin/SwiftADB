import Foundation
import Network
import SwiftADBClient
import SwiftADBTransport

/// Port forwarding direction.
public enum PortForwardDirection: Sendable {
    case local(localPort: UInt16, remotePort: UInt16)
    case remote(localPort: UInt16, remotePort: UInt16)
}

/// Active port forwarding session.
public struct PortForwardSession: Sendable, Identifiable {
    public let id: UUID
    public let direction: PortForwardDirection
    public let localPort: UInt16

    public init(id: UUID = UUID(), direction: PortForwardDirection, localPort: UInt16) {
        self.id = id
        self.direction = direction
        self.localPort = localPort
    }
}

public enum PortForwardError: Error, Sendable {
    case notConnected
    case portInUse(UInt16)
    case forwardFailed(String)
}

/// ADB port forwarding service.
public protocol ADBPortForwardService: Sendable {
    func forward(_ direction: PortForwardDirection) async throws -> PortForwardSession
    func remove(_ session: PortForwardSession) async throws
    func list() async throws -> [PortForwardSession]
}

private actor PortForwardRegistry {
    private var sessions: [UUID: (session: PortForwardSession, listener: NWListener?)] = [:]

    func add(_ session: PortForwardSession, listener: NWListener?) {
        sessions[session.id] = (session, listener)
    }

    func remove(_ id: UUID) -> NWListener? {
        sessions.removeValue(forKey: id)?.listener
    }

    func allSessions() -> [PortForwardSession] {
        sessions.values.map(\.session)
    }
}

public final class DefaultPortForwardService: ADBPortForwardService, @unchecked Sendable {
    private let client: ADBClient
    private let registry = PortForwardRegistry()

    public init(client: ADBClient) {
        self.client = client
    }

    public func forward(_ direction: PortForwardDirection) async throws -> PortForwardSession {
        guard client.device != nil else { throw PortForwardError.notConnected }

        switch direction {
        case .local(let localPort, let remotePort):
            return try await forwardLocal(localPort: localPort, remotePort: remotePort)
        case .remote(let localPort, let remotePort):
            return try await forwardRemote(localPort: localPort, remotePort: remotePort)
        }
    }

    public func remove(_ session: PortForwardSession) async throws {
        let listener = await registry.remove(session.id)
        listener?.cancel()
    }

    public func list() async throws -> [PortForwardSession] {
        guard client.device != nil else { throw PortForwardError.notConnected }
        return await registry.allSessions()
    }

    private func forwardLocal(localPort: UInt16, remotePort: UInt16) async throws -> PortForwardSession {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: localPort)!)
        } catch {
            throw PortForwardError.portInUse(localPort)
        }

        let session = PortForwardSession(
            direction: .local(localPort: localPort, remotePort: remotePort),
            localPort: localPort
        )
        await registry.add(session, listener: listener)

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.relay(connection: connection, remotePort: remotePort) }
        }
        listener.start(queue: DispatchQueue(label: "com.swiftadb.forward.\(localPort)"))
        ADBLog.info("Local forward: :\(localPort) → device:\(remotePort)", category: "PortForward")
        return session
    }

    private func forwardRemote(localPort: UInt16, remotePort: UInt16) async throws -> PortForwardSession {
        let spec = "tcp:\(remotePort);tcp:\(localPort)"
        let stream = try await client.openStream("reverse:forward:\(spec)")
        defer { Task { try? await stream.close() } }

        let session = PortForwardSession(
            direction: .remote(localPort: localPort, remotePort: remotePort),
            localPort: localPort
        )
        await registry.add(session, listener: nil)
        ADBLog.info("Reverse forward kuruldu: device:\(remotePort) → host:\(localPort)", category: "PortForward")
        return session
    }

    private func relay(connection: NWConnection, remotePort: UInt16) async {
        do {
            let stream = try await client.openStream("tcp:\(remotePort)")
            connection.start(queue: .global())

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { state in
                    if case .ready = state { continuation.resume() }
                    else if case .failed(let error) = state { continuation.resume(throwing: error) }
                }
            }

            async let c2d: Void = pump(from: connection, to: stream)
            async let d2c: Void = pump(from: stream, to: connection)
            _ = try await (c2d, d2c)
        } catch {
            connection.cancel()
        }
    }

    private func pump(from connection: NWConnection, to stream: ADBStream) async throws {
        while !(await stream.isClosed) {
            let data = try await receive(from: connection)
            if data.isEmpty { break }
            try await stream.write(data)
        }
    }

    private func pump(from stream: ADBStream, to connection: NWConnection) async throws {
        while !(await stream.isClosed) {
            guard let data = await stream.read(), !data.isEmpty else {
                try await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            try await send(data, to: connection)
        }
    }

    private func receive(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }
        }
    }

    private func send(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}
