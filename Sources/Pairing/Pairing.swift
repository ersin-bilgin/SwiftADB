import Foundation
import SwiftADBAuthentication
import SwiftADBTransport
public enum PairingMethod: Sendable {
    case pairingCode(String)
}

/// Eşleştirme oturumu bilgisi.
public struct PairingSession: Sendable {
    public let host: String
    public let port: UInt16
    public let method: PairingMethod

    public init(host: String, port: UInt16, method: PairingMethod) {
        self.host = host
        self.port = port
        self.method = method
    }
}

public enum PairingError: Error, Sendable {
    case invalidCode
    case sessionExpired
    case pairingFailed(String)
    case adbToolNotFound
}

/// Kablosuz ADB eşleştirme protokolü.
public protocol ADBPairingClient: Sendable {
    func pair(session: PairingSession, keyStore: any ADBKeyStore) async throws
}

/// Sistem `adb pair` aracını kullanan eşleştirme istemcisi (macOS).
#if os(macOS)
public final class SystemPairingClient: ADBPairingClient, @unchecked Sendable {
    public let adbPath: String

    public init(adbPath: String? = nil) {
        self.adbPath = adbPath ?? Self.findADBPath() ?? "adb"
    }

    public func pair(session: PairingSession, keyStore: any ADBKeyStore) async throws {
        _ = keyStore
        guard case .pairingCode(let code) = session.method else {
            throw PairingError.invalidCode
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["pair", "\(session.host):\(session.port)", code]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            if output.lowercased().contains("incorrect") || output.lowercased().contains("wrong") {
                throw PairingError.invalidCode
            }
            throw PairingError.pairingFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    fileprivate static func findADBPath() -> String? {
        let candidates = [
            "/usr/local/bin/adb",
            "/opt/homebrew/bin/adb",
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func findADBPathForClient() -> String? {
        findADBPath()
    }
}
#else
public final class SystemPairingClient: ADBPairingClient, @unchecked Sendable {
    public init(adbPath: String? = nil) {}

    public func pair(session: PairingSession, keyStore: any ADBKeyStore) async throws {
        _ = session
        _ = keyStore
        throw PairingError.adbToolNotFound
    }

    static func findADBPathForClient() -> String? { nil }
}
#endif

/// Eşleştirme istemcisi — önce sistem adb, gerekirse native deneme.
public final class DefaultPairingClient: ADBPairingClient, @unchecked Sendable {
    private let systemClient: SystemPairingClient

    public init(systemClient: SystemPairingClient = SystemPairingClient()) {
        self.systemClient = systemClient
    }

    public func pair(session: PairingSession, keyStore: any ADBKeyStore) async throws {
        guard case .pairingCode(let code) = session.method else {
            throw PairingError.invalidCode
        }

        do {
            try await pairNative(session: session, code: code, keyStore: keyStore)
            ADBLog.info("Native pairing başarılı: \(session.host):\(session.port)", category: "Pairing")
            return
        } catch {
            ADBLog.warning("Native pairing başarısız, sistem adb deneniyor: \(error)", category: "Pairing")
        }

        #if os(macOS)
        if let path = SystemPairingClient.findADBPathForClient() {
            let client = SystemPairingClient(adbPath: path)
            try await client.pair(session: session, keyStore: keyStore)
            return
        }
        #endif

        #if os(macOS)
        let failureMessage = "Eşleştirme başarısız. Android SDK platform-tools kurulu olduğundan emin olun."
        #else
        let failureMessage = "Eşleştirme başarısız. iOS'ta yalnızca native pairing desteklenir."
        #endif
        throw PairingError.pairingFailed(failureMessage)
    }

    private func pairNative(session: PairingSession, code: String, keyStore: any ADBKeyStore) async throws {
        let identity = try keyStore.secIdentity()
        let transport = TCPTransport(
            host: session.host,
            port: session.port,
            tlsRequired: true,
            secIdentity: identity
        )
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let password = Data(code.utf8)
        let ourMsg = PairingAuthContext.generateMessage(password: password, isClient: true)

        let outHeader = PairingPacketHeader(type: .spake2Msg, payloadSize: UInt32(ourMsg.count))
        try await transport.sendRaw(outHeader.encode() + ourMsg)

        let headerData = try await transport.receiveRaw(count: PairingConstants.headerSize)
        let header = try PairingPacketHeader.decode(from: headerData)
        guard header.type == .spake2Msg else {
            throw PairingError.pairingFailed("SPAKE2 mesajı bekleniyordu")
        }
        let theirMsg = try await transport.receiveRaw(count: Int(header.payloadSize))

        let keyMaterial = PairingAuthContext.deriveKeyMaterial(
            password: password,
            ourMsg: ourMsg,
            theirMsg: theirMsg,
            isClient: true
        )

        let peerInfo = PeerInfo(type: .adbRSAPublicKey, data: try keyStore.adbPublicKeyPayload())
        let encrypted = try PairingCipher.encrypt(keyMaterial: keyMaterial, plaintext: peerInfo.encode())

        let peerHeader = PairingPacketHeader(type: .peerInfo, payloadSize: UInt32(encrypted.count))
        try await transport.sendRaw(peerHeader.encode() + encrypted)

        let peerHeaderData = try await transport.receiveRaw(count: PairingConstants.headerSize)
        let peerPacketHeader = try PairingPacketHeader.decode(from: peerHeaderData)
        guard peerPacketHeader.type == .peerInfo else {
            throw PairingError.pairingFailed("PeerInfo bekleniyordu")
        }
        _ = try await transport.receiveRaw(count: Int(peerPacketHeader.payloadSize))
    }
}
