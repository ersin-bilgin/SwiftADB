import Foundation
import SwiftADBClient

public enum FileSyncError: Error, Sendable {
    case notConnected
    case localFileNotFound(String)
    case remotePathInvalid(String)
    case transferFailed(String)
}

/// Dosya aktarım ilerlemesi.
public struct TransferProgress: Sendable {
    public let bytesTransferred: Int64
    public let totalBytes: Int64

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesTransferred) / Double(totalBytes)
    }

    public init(bytesTransferred: Int64, totalBytes: Int64) {
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
    }
}

/// Uzak dosya bilgisi.
public struct RemoteFileStat: Sendable {
    public let mode: UInt32
    public let size: UInt64
    public let mtime: UInt32
}

/// ADB push/pull dosya senkronizasyon servisi.
public protocol ADBFileSyncService: Sendable {
    func stat(remotePath: String) async throws -> RemoteFileStat
    func push(
        localURL: URL,
        remotePath: String,
        onProgress: (@Sendable (TransferProgress) -> Void)?
    ) async throws
    func pull(
        remotePath: String,
        localURL: URL,
        onProgress: (@Sendable (TransferProgress) -> Void)?
    ) async throws
}

public final class DefaultFileSyncService: ADBFileSyncService, @unchecked Sendable {
    private let client: ADBClient
    private let chunkSize = 64 * 1024

    public init(client: ADBClient) {
        self.client = client
    }

    public func stat(remotePath: String) async throws -> RemoteFileStat {
        guard client.device != nil else { throw FileSyncError.notConnected }

        let useStatV2 = client.device?.banner?.contains("stat_v2") == true
        let candidates = statCandidates(for: remotePath)
        var lastError: Error = FileSyncError.remotePathInvalid(remotePath)

        for path in candidates {
            do {
                return try await statOnce(path: path, useStatV2: useStatV2)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func statOnce(path: String, useStatV2: Bool) async throws -> RemoteFileStat {
        let stream = try await client.openStream("sync:")

        let request = useStatV2
            ? SYNCProtocol.command(.lstatV2, path: path)
            : SYNCProtocol.command(.stat, path: path)

        try await stream.write(request)
        let response = try await readSyncResponse(from: stream, timeout: 10)
        try await stream.close()

        switch response.command {
        case .stat:
            guard response.payload.count >= 12 else {
                throw FileSyncError.remotePathInvalid(path)
            }
            let mode = response.payload.readUInt32LE(at: 0)
            let size = UInt64(response.payload.readUInt32LE(at: 4))
            let mtime = response.payload.readUInt32LE(at: 8)
            return RemoteFileStat(mode: mode, size: size, mtime: mtime)

        case .lstatV2, .statV2:
            let fields = try SYNCProtocol.decodeStatV2Record(response.payload, path: path)
            return RemoteFileStat(mode: fields.mode, size: fields.size, mtime: fields.mtime)

        case .fail:
            throw FileSyncError.remotePathInvalid(
                String(data: response.payload, encoding: .utf8) ?? path
            )

        default:
            throw FileSyncError.transferFailed("Beklenmeyen SYNC yanıtı: \(response.command)")
        }
    }

    private func statCandidates(for remotePath: String) -> [String] {
        if remotePath != "/sdcard" {
            return [remotePath]
        }
        return ["/storage/emulated/0", "/sdcard"]
    }

    public func push(
        localURL: URL,
        remotePath: String,
        onProgress: (@Sendable (TransferProgress) -> Void)?
    ) async throws {
        guard client.device != nil else { throw FileSyncError.notConnected }
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            throw FileSyncError.localFileNotFound(localURL.path)
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let fileSize = attrs[.size] as? Int64 ?? 0
        let fileData = try Data(contentsOf: localURL)
        let mode: UInt32 = 33272 // 0100664
        let remote = "\(remotePath),\(mode)"

        let stream = try await client.openStream("sync:")
        defer { Task { try? await stream.close() } }

        try await stream.write(SYNCProtocol.command(.send, path: remote))

        var offset = 0
        while offset < fileData.count {
            let end = min(offset + chunkSize, fileData.count)
            try await stream.write(SYNCProtocol.dataChunk(fileData.subdata(in: offset..<end)))
            offset = end
            onProgress?(TransferProgress(bytesTransferred: Int64(offset), totalBytes: fileSize))
        }

        try await stream.write(SYNCProtocol.done())
        let response = try await readSyncResponse(from: stream, timeout: 15)
        if response.command == .fail {
            throw FileSyncError.transferFailed(String(data: response.payload, encoding: .utf8) ?? "Push başarısız")
        }
    }

    public func pull(
        remotePath: String,
        localURL: URL,
        onProgress: (@Sendable (TransferProgress) -> Void)?
    ) async throws {
        guard client.device != nil else { throw FileSyncError.notConnected }

        let remoteStat = try await stat(remotePath: remotePath)
        let stream = try await client.openStream("sync:")
        defer { Task { try? await stream.close() } }

        try await stream.write(SYNCProtocol.command(.recv, path: remotePath))

        var fileData = Data()
        var buffer = Data()
        let total = Int64(remoteStat.size)

        while !(await stream.isClosed) {
            if let chunk = await stream.read(), !chunk.isEmpty {
                buffer.append(chunk)
            } else {
                try await Task.sleep(nanoseconds: 20_000_000)
                if await stream.isClosed { break }
                continue
            }

            while buffer.count >= 8 {
                guard let (command, length, payload, consumed) = SYNCProtocol.parseCommand(from: buffer) else {
                    break
                }
                buffer.removeFirst(consumed)

                switch command {
                case .data:
                    fileData.append(payload)
                    onProgress?(TransferProgress(bytesTransferred: Int64(fileData.count), totalBytes: total))

                case .done:
                    try fileData.write(to: localURL, options: .atomic)
                    return

                case .fail:
                    throw FileSyncError.transferFailed(String(data: payload, encoding: .utf8) ?? "Pull başarısız")

                default:
                    _ = length
                }
            }
        }

        if !fileData.isEmpty {
            try fileData.write(to: localURL, options: .atomic)
        } else {
            throw FileSyncError.transferFailed("Pull tamamlanamadı")
        }
    }

    private func readSyncResponse(from stream: ADBStream, timeout: TimeInterval) async throws -> (command: SYNCCommand, payload: Data) {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let chunk = await stream.read(), !chunk.isEmpty {
                buffer.append(chunk)
            }
            if let (command, payload, consumed) = SYNCProtocol.parseResponse(from: buffer) {
                buffer.removeFirst(consumed)
                return (command, payload)
            }
            if await stream.isClosed, !buffer.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw FileSyncError.transferFailed("SYNC yanıt zaman aşımı")
    }
}

private extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            $0.load(as: UInt32.self).littleEndian
        }
    }

    func readUInt64LE(at offset: Int) -> UInt64 {
        subdata(in: offset..<(offset + 8)).withUnsafeBytes {
            $0.load(as: UInt64.self).littleEndian
        }
    }

    func readInt64LE(at offset: Int) -> Int64 {
        subdata(in: offset..<(offset + 8)).withUnsafeBytes {
            $0.load(as: Int64.self).littleEndian
        }
    }
}
