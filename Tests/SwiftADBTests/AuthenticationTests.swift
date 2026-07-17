import Foundation
import Testing
@testable import SwiftADB

@Test func adbTokenSignRoundtrip() throws {
    let keyStore = InMemoryKeyStore()
    _ = try keyStore.loadOrGenerateKeyPair()
    let token = Data((0..<ADBProtocol.tokenSize).map { _ in UInt8.random(in: 0...255) })

    let signature = try keyStore.signToken(token)
    #expect(signature.count == 256)

    let privateKey = try keyStore.loadOrGenerateKeyPair()
    guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
        Issue.record("Could not retrieve public key")
        return
    }

    var error: Unmanaged<CFError>?
    let verified = SecKeyVerifySignature(
        publicKey,
        .rsaSignatureDigestPKCS1v15SHA1,
        token as CFData,
        signature as CFData,
        &error
    )
    #expect(verified)
}

@Test func adbPublicKeyWireFormat() throws {
    let keyStore = InMemoryKeyStore(identifier: "adb@iOS")
    _ = try keyStore.loadOrGenerateKeyPair()
    let wire = try keyStore.adbPublicKeyWireData()
    let line = try keyStore.adbPublicKeyLine()

    #expect(wire == Data((line + "\n").utf8))
    #expect(line.contains("adb@iOS") || line.contains("test@swiftadb"))
    #expect(wire.count > 700)
    #expect(wire.last == UInt8(ascii: "\n"))
}
