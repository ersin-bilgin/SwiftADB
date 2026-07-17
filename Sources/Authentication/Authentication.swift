import Foundation
import SwiftADBTransport

/// ADB kimlik doğrulama türleri.
public enum ADBAuthType: UInt32, Sendable {
    case token = 1
    case signature = 2
    case rsaPublicKey = 3
}

public enum AuthenticationError: Error, Sendable, CustomStringConvertible {
    case authRejected
    case invalidToken
    case unexpectedMessage(String)
    case keyGenerationFailed
    case signingFailed
    case authorizationRequired
    case handshakeTimeout
    case awaitingTVApproval

    public var description: String {
        switch self {
        case .authRejected:
            return "ADB anahtarı cihaz tarafından reddedildi"
        case .invalidToken:
            return "Geçersiz ADB kimlik doğrulama token'ı"
        case .unexpectedMessage(let message):
            return "Beklenmeyen kimlik doğrulama mesajı: \(message)"
        case .keyGenerationFailed:
            return "ADB anahtarı oluşturulamadı"
        case .signingFailed:
            return "ADB token imzalanamadı"
        case .authorizationRequired:
            return "Cihazda RSA anahtar onayı gerekli. Android TV'de Geliştirici seçenekleri açıkken ekranda 'USB hata ayıklamaya izin ver' diyalogunu onaylayın."
        case .handshakeTimeout:
            return "ADB kimlik doğrulama zaman aşımı. Cihaz yanıt vermedi."
        case .awaitingTVApproval:
            return "TV ekranında 'USB hata ayıklamaya izin ver' onayını kabul edin, ardından testi tekrar çalıştırın."
        }
    }
}

/// ADB kimlik doğrulama akışı.
public protocol ADBAuthenticator: Sendable {
    func authenticate(transport: any ADBTransport, keyStore: any ADBKeyStore) async throws
}

/// Varsayılan kimlik doğrulama — iRemoteController ile aynı RSA akışı.
public final class DefaultAuthenticator: ADBAuthenticator, @unchecked Sendable {
    private static let tvApprovalTimeoutNanoseconds: UInt64 = 30_000_000_000

    public init() {}

    public func authenticate(transport: any ADBTransport, keyStore: any ADBKeyStore) async throws {
        _ = try keyStore.loadOrGenerateKeyPair()

        while true {
            let message = try await transport.receiveMessage()

            switch message.command {
            case .auth:
                try await completeRSAAuthFlow(
                    firstAuth: message,
                    transport: transport,
                    keyStore: keyStore
                )
                return
            case .cnxn:
                return
            default:
                throw AuthenticationError.unexpectedMessage(String(describing: message.command))
            }
        }
    }

    private func completeRSAAuthFlow(
        firstAuth: ADBMessage,
        transport: any ADBTransport,
        keyStore: any ADBKeyStore
    ) async throws {
        guard firstAuth.header.arg0 == ADBAuthType.token.rawValue,
              firstAuth.payload.count >= ADBProtocol.tokenSize else {
            throw AuthenticationError.invalidToken
        }

        let token = firstAuth.payload.prefix(ADBProtocol.tokenSize)
        let signature = try keyStore.signToken(Data(token))
        try await transport.send(
            header: ADBMessageHeader(command: .auth, arg0: ADBAuthType.signature.rawValue),
            payload: signature
        )

        let afterSign = try await transport.receiveMessage()
        if afterSign.command == .cnxn {
            return
        }

        guard afterSign.command == .auth else {
            throw AuthenticationError.unexpectedMessage(String(describing: afterSign.command))
        }

        let publicKeyPayload = try keyStore.adbPublicKeyWireData()
        try await transport.send(
            header: ADBMessageHeader(command: .auth, arg0: ADBAuthType.rsaPublicKey.rawValue),
            payload: publicKeyPayload
        )

        let afterPublicKey = try await receiveWithTimeout(
            transport: transport,
            timeoutNanoseconds: Self.tvApprovalTimeoutNanoseconds
        )
        guard afterPublicKey.command == .cnxn else {
            throw AuthenticationError.awaitingTVApproval
        }
    }

    private func receiveWithTimeout(
        transport: any ADBTransport,
        timeoutNanoseconds: UInt64
    ) async throws -> ADBMessage {
        try await withThrowingTaskGroup(of: ADBMessage.self) { group in
            group.addTask {
                try await transport.receiveMessage()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw AuthenticationError.handshakeTimeout
            }
            guard let message = try await group.next() else {
                throw AuthenticationError.handshakeTimeout
            }
            group.cancelAll()
            return message
        }
    }
}
