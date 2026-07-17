import Foundation
import SwiftADBClient

/// Shell protocol version.
public enum ShellProtocolVersion: Sendable {
    case v1
    case v2
}

enum ShellV2 {
    static let stdoutMarker: UInt8 = 1
    static let stderrMarker: UInt8 = 2
    static let exitMarker: UInt8 = 3

    static func destination(for command: String) -> String {
        "shell,v2,raw:\(command)"
    }

    /// ADB shell v2: `[type:1][length:4 LE][payload:length]`
    static func parse(_ data: Data) -> (stdout: Data, stderr: Data, exitCode: Int32?) {
        var stdout = Data()
        var stderr = Data()
        var exitCode: Int32?
        var index = data.startIndex

        while index < data.endIndex {
            let kind = data[index]
            index = data.index(after: index)

            guard index + 4 <= data.endIndex else { break }
            let length = Int(data.readUInt32LE(at: index))
            index = data.index(index, offsetBy: 4)

            guard length >= 0, index + length <= data.endIndex else { break }
            let payload = data.subdata(in: index..<(index + length))
            index = data.index(index, offsetBy: length)

            switch kind {
            case stdoutMarker:
                stdout.append(payload)
            case stderrMarker:
                stderr.append(payload)
            case exitMarker:
                if payload.count >= 4 {
                    exitCode = payload.withUnsafeBytes { $0.load(as: Int32.self).littleEndian }
                } else if payload.count == 1 {
                    exitCode = Int32(payload[0])
                }
            default:
                break
            }
        }

        return (stdout, stderr, exitCode)
    }
}

/// Shell command output.
public struct ShellOutput: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String = "", exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public enum ShellError: Error, Sendable {
    case notConnected
    case commandFailed(String)
    case streamClosed
    case timeout
}

/// ADB shell service.
public protocol ADBShellService: Sendable {
    func execute(_ command: String, protocolVersion: ShellProtocolVersion) async throws -> ShellOutput
    func stream(_ command: String) async throws -> AsyncStream<String>
}

extension ADBShellService {
    public func execute(_ command: String) async throws -> ShellOutput {
        try await execute(command, protocolVersion: .v2)
    }
}

public final class DefaultShellService: ADBShellService, @unchecked Sendable {
    private let client: ADBClient

    public init(client: ADBClient) {
        self.client = client
    }

    public func execute(_ command: String, protocolVersion: ShellProtocolVersion = .v2) async throws -> ShellOutput {
        guard client.device != nil else { throw ShellError.notConnected }

        let destination: String
        switch protocolVersion {
        case .v1:
            destination = "shell:\(command)"
        case .v2:
            destination = ShellV2.destination(for: command)
        }

        let stream = try await client.openStream(destination)
        let data = try await readShellOutput(from: stream, timeout: 30)
        try await stream.close()

        switch protocolVersion {
        case .v1:
            let output = String(data: data, encoding: .utf8) ?? ""
            return ShellOutput(stdout: output.trimmingCharacters(in: .newlines))

        case .v2:
            let parsed = ShellV2.parse(data)
            return ShellOutput(
                stdout: String(data: parsed.stdout, encoding: .utf8) ?? "",
                stderr: String(data: parsed.stderr, encoding: .utf8) ?? "",
                exitCode: parsed.exitCode ?? 0
            )
        }
    }

    public func stream(_ command: String) async throws -> AsyncStream<String> {
        guard client.device != nil else { throw ShellError.notConnected }

        let stream = try await client.openStream(ShellV2.destination(for: command))

        return AsyncStream { continuation in
            Task {
                while !(await stream.isClosed) {
                    if let chunk = await stream.read(), !chunk.isEmpty {
                        let parsed = ShellV2.parse(chunk)
                        if let text = String(data: parsed.stdout, encoding: .utf8), !text.isEmpty {
                            continuation.yield(text)
                        }
                        if let err = String(data: parsed.stderr, encoding: .utf8), !err.isEmpty {
                            continuation.yield(err)
                        }
                    } else {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                }
                try? await stream.close()
                continuation.finish()
            }
        }
    }

    private func readShellOutput(from stream: ADBStream, timeout: TimeInterval) async throws -> Data {
        var result = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let chunk = await stream.read(), !chunk.isEmpty {
                result.append(chunk)
                if ShellV2.parse(result).exitCode != nil {
                    break
                }
            } else if await stream.isClosed {
                break
            } else {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        if result.isEmpty && Date() >= deadline {
            let stillOpen = !(await stream.isClosed)
            if stillOpen {
                throw ShellError.timeout
            }
        }
        return result
    }
}

private extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            $0.load(as: UInt32.self).littleEndian
        }
    }
}
