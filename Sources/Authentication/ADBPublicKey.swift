import Foundation

enum ADBPublicKey {
    static let modulusSize = 256
    static let wordCount = 64

    static func encodeBase64(modulus: Data, exponent: UInt32) -> String {
        encodeBinary(modulus: modulus, exponent: exponent).base64EncodedString()
    }

    /// Android ADB `RSAPublicKey` yapısı — iRemoteController ADBKeyManager ile birebir.
    static func encodeBinary(modulus: Data, exponent: UInt32) -> Data {
        let padded = normalizedModulus(modulus)
        guard padded.count == modulusSize else { return Data() }

        var words = [UInt32](repeating: 0, count: wordCount)
        for index in 0..<wordCount {
            let base = 252 - index * 4
            words[index] =
                (UInt32(padded[base]) << 24) |
                (UInt32(padded[base + 1]) << 16) |
                (UInt32(padded[base + 2]) << 8) |
                UInt32(padded[base + 3])
        }

        let n0inv = montgomeryN0Inv(words[0])
        let rr = montgomeryRSquaredModN(words)

        var data = Data(capacity: (2 + 2 * wordCount + 1) * 4)
        data.appendUInt32LE(UInt32(wordCount))
        data.appendUInt32LE(n0inv)
        words.forEach { data.appendUInt32LE($0) }
        rr.forEach { data.appendUInt32LE($0) }
        data.appendUInt32LE(exponent)
        return data
    }

    static func encodePublicKeyLine(base64Key: String, identifier: String) -> String {
        "\(base64Key) \(identifier)"
    }

    /// AUTH(type=3) wire payload — TV onay diyalogunu tetikler.
    static func encodeWirePayload(line: String) -> Data {
        Data((line + "\n").utf8)
    }

    /// iRemoteController ile aynı wire format: `base64 + " adb@iOS\n"`
    static func encodeWirePayload(base64Key: String, identifier: String = "adb@iOS") -> Data {
        Data((base64Key + " \(identifier)\n").utf8)
    }

    static func parseComponents(fromPublicKeyDER der: Data) -> (modulus: Data, exponent: UInt32)? {
        var index = 0
        guard der.count > 10, der[index] == 0x30 else { return nil }
        index += 1
        index += der.lengthBytes(at: index)

        if der[index] == 0x30 {
            index += 1
            let algLen = der.lengthValue(at: index)
            index += der.lengthBytes(at: index) + algLen
            guard der[index] == 0x03 else { return nil }
            index += 1
            _ = der.lengthValue(at: index)
            index += der.lengthBytes(at: index) + 1
            guard der[index] == 0x30 else { return nil }
            index += 1
            index += der.lengthBytes(at: index)
        }

        guard der[index] == 0x02 else { return nil }
        index += 1
        var modLen = der.lengthValue(at: index)
        index += der.lengthBytes(at: index)
        var modulus = der.subdata(in: index..<(index + modLen))
        index += modLen

        if modulus.first == 0x00 {
            modulus.removeFirst()
            modLen -= 1
        }
        guard modLen <= modulusSize else { return nil }

        guard index < der.count, der[index] == 0x02 else { return nil }
        index += 1
        let expLen = der.lengthValue(at: index)
        index += der.lengthBytes(at: index)
        let exponentData = der.subdata(in: index..<(index + expLen))
        var exponentValue: UInt32 = 0
        for byte in exponentData {
            exponentValue = (exponentValue << 8) | UInt32(byte)
        }

        return (normalizedModulus(modulus), exponentValue)
    }

    static func normalizedModulus(_ modulus: Data) -> Data {
        var bytes = modulus
        if bytes.first == 0x00 {
            bytes.removeFirst()
        }
        guard bytes.count <= modulusSize else { return Data(repeating: 0, count: modulusSize) }
        var padded = Data(repeating: 0, count: modulusSize)
        let offset = modulusSize - bytes.count
        padded.replaceSubrange(offset..<modulusSize, with: bytes)
        return padded
    }

    private static func montgomeryN0Inv(_ n0: UInt32) -> UInt32 {
        var x = n0
        for _ in 0..<4 {
            x = x &* (2 &- n0 &* x)
        }
        return 0 &- x
    }

    private static func montgomeryRSquaredModN(_ words: [UInt32]) -> [UInt32] {
        var result = [UInt32](repeating: 0, count: wordCount)
        result[0] = 1
        for _ in 0..<(wordCount * 32 * 2) {
            doubleModN(&result, words)
        }
        return result
    }

    private static func doubleModN(_ value: inout [UInt32], _ modulus: [UInt32]) {
        var carry: UInt32 = 0
        for index in 0..<wordCount {
            let doubled = UInt64(value[index]) * 2 + UInt64(carry)
            value[index] = UInt32(doubled & 0xffff_ffff)
            carry = UInt32(doubled >> 32)
        }
        if carry != 0 || isGreaterOrEqual(value, modulus) {
            subtractModN(&value, modulus)
        }
    }

    private static func isGreaterOrEqual(_ lhs: [UInt32], _ rhs: [UInt32]) -> Bool {
        for index in stride(from: wordCount - 1, through: 0, by: -1) {
            if lhs[index] > rhs[index] { return true }
            if lhs[index] < rhs[index] { return false }
        }
        return true
    }

    private static func subtractModN(_ value: inout [UInt32], _ modulus: [UInt32]) {
        var borrow: Int64 = 0
        for index in 0..<wordCount {
            let difference = Int64(value[index]) - Int64(modulus[index]) - borrow
            value[index] = UInt32(truncatingIfNeeded: difference)
            borrow = difference < 0 ? 1 : 0
        }
    }
}

private extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: 4))
    }

    func lengthBytes(at offset: Int) -> Int {
        guard offset < count else { return 0 }
        if self[offset] & 0x80 == 0 { return 1 }
        return Int(self[offset] & 0x7f) + 1
    }

    func lengthValue(at offset: Int) -> Int {
        guard offset < count else { return 0 }
        if self[offset] & 0x80 == 0 { return Int(self[offset]) }
        let numBytes = Int(self[offset] & 0x7f)
        var value = 0
        for index in 1...numBytes where offset + index < count {
            value = (value << 8) | Int(self[offset + index])
        }
        return value
    }
}
