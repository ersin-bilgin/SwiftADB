import Foundation
import SwiftADBTransport

/// An open ADB service stream.
public actor ADBStream {
    public let localID: UInt32
    public private(set) var remoteID: UInt32?
    public let destination: String

    private weak var session: ADBSession?
    private var buffer = Data()
    private var readWaiters: [CheckedContinuation<Data?, Never>] = []
    private var closed = false

    init(localID: UInt32, destination: String, session: ADBSession) {
        self.localID = localID
        self.destination = destination
        self.session = session
    }

    func setRemoteID(_ id: UInt32) {
        remoteID = id
    }

    func append(_ data: Data) {
        guard !closed else { return }
        buffer.append(data)
        let waiters = readWaiters
        readWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: drainBuffer())
        }
    }

    func markClosed() {
        closed = true
        let waiters = readWaiters
        readWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    public var isClosed: Bool { closed }

    public func write(_ data: Data) async throws {
        guard let session, let remoteID else {
            throw ADBClientError.notConnected
        }
        try await session.write(data, localID: localID, remoteID: remoteID)
    }

    public func read(maxLength: Int = 65_536) async -> Data? {
        if !buffer.isEmpty {
            return drainBuffer(maxLength: maxLength)
        }
        if closed { return nil }

        return await withCheckedContinuation { continuation in
            if !buffer.isEmpty {
                continuation.resume(returning: drainBuffer(maxLength: maxLength))
                return
            }
            if closed {
                continuation.resume(returning: nil)
                return
            }
            readWaiters.append(continuation)
        }
    }

    public func readAll(timeout: TimeInterval = 30) async throws -> Data {
        var result = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let chunk = await read(), !chunk.isEmpty {
                result.append(chunk)
            } else if closed {
                break
            } else {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        if result.isEmpty && !closed && Date() >= deadline {
            throw ADBClientError.connectionFailed("Stream read timed out")
        }
        return result
    }

    public func close() async throws {
        guard let session, let remoteID else { return }
        try await session.closeStream(localID: localID, remoteID: remoteID)
        markClosed()
    }

    private func drainBuffer(maxLength: Int = Int.max) -> Data? {
        guard !buffer.isEmpty else { return nil }
        let count = min(maxLength, buffer.count)
        let chunk = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(chunk)
    }
}
