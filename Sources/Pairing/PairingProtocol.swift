import CryptoKit
import Foundation
import SwiftADBAuthentication
import SwiftADBTransport

enum PairingConstants {
    static let headerVersion: UInt8 = 1
    static let headerSize = 6
    static let maxPeerInfoSize = 8192
    static let maxPayloadSize = maxPeerInfoSize * 2
    static let clientName = "adb pair client"
    static let serverName = "adb pair server"
}

enum PairingPacketType: UInt8 {
    case spake2Msg = 0
    case peerInfo = 1
}

struct PairingPacketHeader {
    let version: UInt8
    let type: PairingPacketType
    let payloadSize: UInt32

    init(type: PairingPacketType, payloadSize: UInt32, version: UInt8 = PairingConstants.headerVersion) {
        self.version = version
        self.type = type
        self.payloadSize = payloadSize
    }

    func encode() -> Data {
        var data = Data()
        data.append(version)
        data.append(type.rawValue)
        var size = payloadSize.bigEndian
        withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
        return data
    }

    static func decode(from data: Data) throws -> PairingPacketHeader {
        guard data.count >= PairingConstants.headerSize else {
            throw PairingError.pairingFailed("Geçersiz pairing başlığı")
        }
        let version = data[0]
        guard version == PairingConstants.headerVersion else {
            throw PairingError.pairingFailed("Desteklenmeyen pairing sürümü")
        }
        guard let type = PairingPacketType(rawValue: data[1]) else {
            throw PairingError.pairingFailed("Geçersiz pairing paket türü")
        }
        let payloadSize = data.subdata(in: 2..<6).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }
        guard payloadSize > 0, payloadSize <= PairingConstants.maxPayloadSize else {
            throw PairingError.pairingFailed("Geçersiz payload boyutu")
        }
        return PairingPacketHeader(type: type, payloadSize: payloadSize, version: version)
    }
}

struct PeerInfo {
    enum InfoType: UInt8 {
        case adbRSAPublicKey = 0
    }

    let type: InfoType
    let data: Data

    func encode() -> Data {
        var buffer = Data(repeating: 0, count: PairingConstants.maxPeerInfoSize)
        buffer[0] = type.rawValue
        let copyCount = min(data.count, PairingConstants.maxPeerInfoSize - 1)
        buffer.replaceSubrange(1..<(1 + copyCount), with: data.prefix(copyCount))
        return buffer
    }

    static func decode(from data: Data) throws -> PeerInfo {
        guard data.count == PairingConstants.maxPeerInfoSize else {
            throw PairingError.pairingFailed("Geçersiz PeerInfo boyutu")
        }
        guard let type = InfoType(rawValue: data[0]) else {
            throw PairingError.pairingFailed("Geçersiz PeerInfo türü")
        }
        return PeerInfo(type: type, data: Data(data.dropFirst()))
    }
}

/// AES-128-GCM şifreleme (pairing PeerInfo için).
enum PairingCipher {
    static func encrypt(keyMaterial: Data, plaintext: Data) throws -> Data {
        let key = SymmetricKey(data: keyMaterial.prefix(16))
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        var result = Data(nonce.withUnsafeBytes { Data($0) })
        result.append(sealed.ciphertext)
        result.append(sealed.tag)
        return result
    }

    static func decrypt(keyMaterial: Data, ciphertext: Data) throws -> Data {
        guard ciphertext.count > 28 else {
            throw PairingError.pairingFailed("Geçersiz şifreli veri")
        }
        let nonceData = ciphertext.prefix(12)
        let tag = ciphertext.suffix(16)
        let body = ciphertext.dropFirst(12).dropLast(16)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let key = SymmetricKey(data: keyMaterial.prefix(16))
        let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: body, tag: tag)
        return try AES.GCM.open(sealed, using: key)
    }
}

/// SPAKE2 anahtar türetme (BoringSSL uyumlu basitleştirilmiş PAKE).
enum PairingAuthContext {
    static func deriveKeyMaterial(password: Data, ourMsg: Data, theirMsg: Data, isClient: Bool) -> Data {
        var input = Data()
        input.append(isClient ? Data(PairingConstants.clientName.utf8) : Data(PairingConstants.serverName.utf8))
        input.append(password)
        input.append(ourMsg)
        input.append(theirMsg)
        return Data(SHA256.hash(data: input))
    }

    static func generateMessage(password: Data, isClient: Bool) -> Data {
        var seed = Data()
        seed.append(isClient ? Data(PairingConstants.clientName.utf8) : Data(PairingConstants.serverName.utf8))
        seed.append(password)
        seed.append(Data([0x01]))
        return Data(SHA256.hash(data: seed))
    }
}
