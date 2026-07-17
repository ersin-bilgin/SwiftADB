import Foundation
import SwiftADBTransport

/// ADB authentication types.
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
            return "ADB key rejected by device"
        case .invalidToken:
            return "Invalid ADB authentication token"
        case .unexpectedMessage(let message):
            return "Unexpected authentication message: \(message)"
        case .keyGenerationFailed:
            return "Failed to generate ADB key"
        case .signingFailed:
            return "Failed to sign ADB token"
        case .authorizationRequired:
            return "RSA key approval required on device. On Android TV with Developer options enabled, approve the 'Allow USB debugging' dialog on screen."
        case .handshakeTimeout:
            return "ADB authentication timed out. The device did not respond."
        case .awaitingTVApproval:
            return "Accept 'Allow USB debugging' on the TV screen, then run the test again."
        }
    }
}

/// ADB authentication flow.
public protocol ADBAuthenticator: Sendable {
    func authenticate(transport: any ADBTransport, keyStore: any ADBKeyStore) async throws
}

/// Default authentication — same RSA flow as iRemoteController.
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
