import Foundation

enum SYNCCommand: UInt32 {
    case stat = 0x5441_5453 // STAT
    case lstatV2 = 0x3254_534C // LST2
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
}
