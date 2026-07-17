import Foundation

enum ADBMessageCodec {
    static func payloadChecksum(_ payload: Data) -> UInt32 {
        payload.reduce(UInt32(0)) { $0 + UInt32($1) }
    }

    static func encode(header: ADBMessageHeader, payload: Data?) -> Data {
        let body = payload ?? Data()
        // Compatible with platform-tools / iRemoteController — modern ADB does not use checksums.
        let resolvedHeader = ADBMessageHeader(
            command: header.command,
            arg0: header.arg0,
            arg1: header.arg1,
            payloadLength: UInt32(body.count),
            checksum: 0,
            magic: header.magic
        )

        var data = Data(capacity: ADBMessageHeader.size + body.count)
        data.appendUInt32LE(resolvedHeader.command.rawValue)
        data.appendUInt32LE(resolvedHeader.arg0)
        data.appendUInt32LE(resolvedHeader.arg1)
        data.appendUInt32LE(resolvedHeader.payloadLength)
        data.appendUInt32LE(resolvedHeader.checksum)
        data.appendUInt32LE(resolvedHeader.magic)
        data.append(body)
        return data
    }

    static func decodeHeader(from data: Data) throws -> ADBMessageHeader {
        guard data.count >= ADBMessageHeader.size else {
            throw TransportError.invalidMessage
        }

        let commandRaw = data.readUInt32LE(at: 0)
        guard let command = ADBCommand(rawValue: commandRaw) else {
            throw TransportError.invalidMessage
        }

        let arg0 = data.readUInt32LE(at: 4)
        let arg1 = data.readUInt32LE(at: 8)
        let payloadLength = data.readUInt32LE(at: 12)
        let checksum = data.readUInt32LE(at: 16)
        let magic = data.readUInt32LE(at: 20)

        guard magic == commandRaw ^ 0xFFFF_FFFF else {
            throw TransportError.invalidMessage
        }

        return ADBMessageHeader(
            command: command,
            arg0: arg0,
            arg1: arg1,
            payloadLength: payloadLength,
            checksum: checksum,
            magic: magic
        )
    }

    static func validatePayload(_ payload: Data, expectedChecksum: UInt32) throws {
        guard expectedChecksum != 0 else { return }
        guard payloadChecksum(payload) == expectedChecksum else {
            throw TransportError.checksumMismatch
        }
    }
}

extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        precondition(offset + 4 <= count)
        return subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            $0.load(as: UInt32.self).littleEndian
        }
    }
}
