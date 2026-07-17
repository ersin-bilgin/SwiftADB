import Foundation

enum SYNCCommand: UInt32 {
    case stat = 0x5441_5453 // STAT
    case lstatV2 = 0x3254_534C // LST2
    case statV2 = 0x3241_5453 // STA2
    case list = 0x5453_494C // LIST
    case send = 0x444E_4553 // SEND
    case recv = 0x5643_4552 // RECV
    case data = 0x4154_4144 // DATA
    case done = 0x454E_4F44 // DONE
    case okay = 0x5941_4B4F // OKAY
    case fail = 0x4C4C_4146 // FAIL
}

enum SYNCProtocol {
    static func command(_ id: SYNCCommand, path: String) -> Data {
        var data = Data()
        var cmd = id.rawValue.littleEndian
        withUnsafeBytes(of: &cmd) { data.append(contentsOf: $0) }
        var length = UInt32(path.utf8.count).littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(contentsOf: path.utf8)
        return data
    }

    static func dataChunk(_ payload: Data) -> Data {
        var data = Data()
        var cmd = SYNCCommand.data.rawValue.littleEndian
        withUnsafeBytes(of: &cmd) { data.append(contentsOf: $0) }
        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    static func done() -> Data {
        var data = Data()
        var cmd = SYNCCommand.done.rawValue.littleEndian
        withUnsafeBytes(of: &cmd) { data.append(contentsOf: $0) }
        var length = UInt32(0).littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        return data
    }

    static func parseCommand(from data: Data) -> (SYNCCommand, UInt32, Data, Int)? {
        guard data.count >= 8 else { return nil }
        let cmdRaw = data.readUInt32LE(at: 0)
        let length = data.readUInt32LE(at: 4)
        let total = 8 + Int(length)
        guard data.count >= total, let cmd = SYNCCommand(rawValue: cmdRaw) else { return nil }
        let payload = data.subdata(in: 8..<total)
        return (cmd, length, payload, total)
    }

    static let statV2RecordSize = 72

    /// LST2/STA2 flat stat_v2 record (72 bytes).
    static func parseStatV2Record(from data: Data) -> (SYNCCommand, Data, Int)? {
        guard data.count >= statV2RecordSize else { return nil }
        let id = data.readUInt32LE(at: 0)
        switch id {
        case SYNCCommand.lstatV2.rawValue:
            return (.lstatV2, data.subdata(in: 0..<statV2RecordSize), statV2RecordSize)
        case SYNCCommand.statV2.rawValue:
            return (.statV2, data.subdata(in: 0..<statV2RecordSize), statV2RecordSize)
        default:
            return nil
        }
    }

    /// Parses STAT v1 (20 bytes) and LST2 v2 (72-byte flat struct) responses.
    static func parseResponse(from data: Data) -> (SYNCCommand, Data, Int)? {
        if let record = parseStatV2Record(from: data) {
            return record
        }

        guard data.count >= 8 else { return nil }
        let cmdRaw = data.readUInt32LE(at: 0)
        guard let cmd = SYNCCommand(rawValue: cmdRaw) else { return nil }

        switch cmd {
        case .stat:
            if data.count >= 20 {
                return (cmd, data.subdata(in: 8..<20), 20)
            }
            if let (command, _, payload, consumed) = parseCommand(from: data) {
                return (command, payload, consumed)
            }
            return nil

        default:
            if let (command, _, payload, consumed) = parseCommand(from: data) {
                return (command, payload, consumed)
            }
            return nil
        }
    }

    static func decodeStatV2Record(_ record: Data, path: String) throws -> (mode: UInt32, size: UInt64, mtime: UInt32) {
        guard record.count >= statV2RecordSize else {
            throw FileSyncError.remotePathInvalid(path)
        }
        let errorCode = record.readUInt32LE(at: 4)
        guard errorCode == 0 else {
            throw FileSyncError.remotePathInvalid("\(path) (errno \(errorCode))")
        }
        return (
            mode: record.readUInt32LE(at: 24),
            size: record.readUInt64LE(at: 40),
            mtime: UInt32(clamping: Int(record.readInt64LE(at: 56)))
        )
    }

    static func readCommand(from data: Data) -> (SYNCCommand, UInt32, Data)? {
        guard let (cmd, length, payload, _) = parseCommand(from: data) else { return nil }
        return (cmd, length, payload)
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
