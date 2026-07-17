import CryptoKit
import Foundation
import Security
import SwiftADBTransport

/// RSA anahtar çifti yönetimi.
public protocol ADBKeyStore: Sendable {
    var identifier: String { get }
    func loadOrGenerateKeyPair() throws -> SecKey
    func signToken(_ token: Data) throws -> Data
    func adbPublicKeyLine() throws -> String
    func adbPublicKeyPayload() throws -> Data
    func secIdentity() throws -> SecIdentity
}

public extension ADBKeyStore {
    func adbPublicKeyWireData() throws -> Data {
        #if os(macOS)
        return ADBPublicKey.encodeWirePayload(line: try adbPublicKeyLine())
        #else
        let base64 = try adbPublicKeyPayload().base64EncodedString()
        return ADBPublicKey.encodeWirePayload(base64Key: base64, identifier: identifier)
        #endif
    }
}

public enum KeyStoreError: Error, Sendable, CustomStringConvertible {
    case keyGenerationFailed
    case signingFailed
    case exportFailed
    case keyImportFailed(String)
    case identityCreationFailed

    public var description: String {
        switch self {
        case .keyGenerationFailed:
            return "ADB RSA anahtarı oluşturulamadı"
        case .signingFailed:
            return "ADB kimlik doğrulama imzası oluşturulamadı"
        case .exportFailed:
            return "ADB anahtarı dışa aktarılamadı"
        case .keyImportFailed(let detail):
            return "ADB anahtarı içe aktarılamadı: \(detail)"
        case .identityCreationFailed:
            return "TLS kimlik sertifikası oluşturulamadı"
        }
    }
}

/// Dosya tabanlı ADB anahtar deposu.
/// - macOS: `~/.android/adbkey`
/// - iOS/iPadOS: `Application Support/SwiftADB/`
public final class FileKeyStore: ADBKeyStore, @unchecked Sendable {
    public let identifier: String
    private let privateKeyURL: URL
    private let publicKeyURL: URL
    private var cachedKey: SecKey?
    private let lock = NSLock()

    public init(
        directory: URL? = nil,
        identifier: String? = nil
    ) {
        let base = directory ?? Self.defaultKeyDirectory()
        self.privateKeyURL = base.appendingPathComponent("adbkey")
        self.publicKeyURL = base.appendingPathComponent("adbkey.pub")

        if let identifier {
            self.identifier = identifier
        } else if let pub = try? String(contentsOf: publicKeyURL, encoding: .utf8),
                  let suffix = pub.split(separator: " ", maxSplits: 1).last {
            self.identifier = String(suffix)
        } else {
            self.identifier = Self.defaultIdentifier()
        }
    }

    private static func defaultKeyDirectory() -> URL {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".android", isDirectory: true)
        #else
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("SwiftADB", isDirectory: true)
        #endif
    }

    private static func defaultIdentifier() -> String {
        #if os(macOS)
        return "\(ProcessInfo.processInfo.userName)@swiftadb"
        #else
        return "adb@iOS"
        #endif
    }

    public func loadOrGenerateKeyPair() throws -> SecKey {
        lock.lock()
        defer { lock.unlock() }

        if let cachedKey { return cachedKey }

        #if os(macOS)
        if FileManager.default.fileExists(atPath: privateKeyURL.path) {
            let pem = try Data(contentsOf: privateKeyURL)
            if let key = try importPrivateKey(fromPEM: pem) {
                cachedKey = key
                try syncPublicKeyFileIfNeeded(for: key)
                return key
            }
            throw KeyStoreError.keyImportFailed(
                "Geçersiz anahtar dosyası: \(privateKeyURL.path). " +
                "`adb keygen` ile yeniden oluşturmayı deneyin."
            )
        }

        let key = try generateKeyPair()
        try persist(key: key)
        cachedKey = key
        return key
        #else
        if FileManager.default.fileExists(atPath: privateKeyURL.path) {
            let pem = try Data(contentsOf: privateKeyURL)
            if let key = try importPrivateKey(fromPEM: pem) {
                cachedKey = key
                try? syncPublicKeyFileIfNeeded(for: key)
                return key
            }
            throw KeyStoreError.keyImportFailed(
                "Geçersiz anahtar dosyası: \(privateKeyURL.path)"
            )
        }

        if let key = loadKeyFromKeychain() {
            cachedKey = key
            try? syncPublicKeyFileIfNeeded(for: key)
            return key
        }

        removeLegacyKeyFilesIfPresent()
        let key = try generateKeyInKeychain()
        cachedKey = key
        try? syncPublicKeyFileIfNeeded(for: key)
        return key
        #endif
    }

    public func signToken(_ token: Data) throws -> Data {
        let privateKey = try loadOrGenerateKeyPair()
        guard token.count == ADBProtocol.tokenSize else {
            throw KeyStoreError.signingFailed
        }

        // ADB istemcisi RSA_sign(NID_sha1, token, …) kullanır; adbd RSA_verify ile doğrular.
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureDigestPKCS1v15SHA1,
            token as CFData,
            &error
        ) as Data? else {
            throw error?.takeRetainedValue() ?? KeyStoreError.signingFailed
        }
        return signature
    }

    public func adbPublicKeyLine() throws -> String {
        #if os(macOS)
        if let cliLine = try adbCLIPublicKeyLine() {
            return cliLine
        }
        #endif
        let base64 = try adbPublicKeyPayload().base64EncodedString()
        return ADBPublicKey.encodePublicKeyLine(base64Key: base64, identifier: identifier)
    }

    public func adbPublicKeyPayload() throws -> Data {
        #if os(macOS)
        if let cliLine = try adbCLIPublicKeyLine() {
            let base64 = cliLine.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            if let data = Data(base64Encoded: base64) {
                return data
            }
        }
        #endif
        let publicKey = try publicSecKey()
        let (modulus, exponent) = try rsaComponents(from: publicKey)
        return ADBPublicKey.encodeBinary(modulus: modulus, exponent: exponent)
    }

    #if os(macOS)
    private func adbCLIPublicKeyLine() throws -> String? {
        guard let adbPath = try? resolveADBExecutable() else { return nil }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["pubkey", privateKeyURL.path]
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else {
            return nil
        }
        let base64 = output.split(separator: " ", maxSplits: 1).first.map(String.init) ?? output
        return ADBPublicKey.encodePublicKeyLine(base64Key: base64, identifier: identifier)
    }

    private func resolveADBExecutable() throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["adb"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0, !path.isEmpty else {
            throw KeyStoreError.exportFailed
        }
        return path
    }
    #endif

    public func secIdentity() throws -> SecIdentity {
        #if os(macOS)
        let privateKey = try loadOrGenerateKeyPair()
        let certificate = try createSelfSignedCertificate(privateKey: privateKey)
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, certificate, &identity)
        guard status == errSecSuccess, let identity else {
            throw KeyStoreError.identityCreationFailed
        }
        return identity
        #else
        throw KeyStoreError.identityCreationFailed
        #endif
    }

    private func generateKeyPair() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: false,
            ],
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? KeyStoreError.keyGenerationFailed
        }
        return key
    }

    private func publicSecKey() throws -> SecKey {
        let privateKey = try loadOrGenerateKeyPair()
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw KeyStoreError.exportFailed
        }
        return publicKey
    }

    private func rsaComponents(from publicKey: SecKey) throws -> (Data, UInt32) {
        var error: Unmanaged<CFError>?
        guard let der = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw error?.takeRetainedValue() ?? KeyStoreError.exportFailed
        }
        guard let components = ADBPublicKey.parseComponents(fromPublicKeyDER: der) else {
            throw KeyStoreError.exportFailed
        }
        return (components.modulus, components.exponent)
    }

    private func persist(key: SecKey) throws {
        let directory = privateKeyURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pem = try exportPrivateKeyPEM(key)
        try pem.write(to: privateKeyURL, options: .atomic)
        try writePublicKeyFile(for: key)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: privateKeyURL.path
        )
    }

    private func syncPublicKeyFileIfNeeded(for key: SecKey) throws {
        let expected = try adbPublicKeyLine(for: key)
        if FileManager.default.fileExists(atPath: publicKeyURL.path),
           let current = try? String(contentsOf: publicKeyURL, encoding: .utf8),
           current.trimmingCharacters(in: .whitespacesAndNewlines) == expected {
            return
        }
        try writePublicKeyFile(for: key)
    }

    private func writePublicKeyFile(for key: SecKey) throws {
        let line = try adbPublicKeyLine(for: key)
        try line.write(to: publicKeyURL, atomically: true, encoding: .utf8)
    }

    private func adbPublicKeyLine(for key: SecKey) throws -> String {
        #if os(macOS)
        if let cliLine = try adbCLIPublicKeyLine() {
            return cliLine
        }
        #endif
        let publicKey = SecKeyCopyPublicKey(key)
        guard let publicKey else { throw KeyStoreError.exportFailed }
        let (modulus, exponent) = try rsaComponents(from: publicKey)
        let base64 = ADBPublicKey.encodeBinary(modulus: modulus, exponent: exponent).base64EncodedString()
        return ADBPublicKey.encodePublicKeyLine(base64Key: base64, identifier: identifier)
    }

    private func exportPrivateKeyPEM(_ key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw error?.takeRetainedValue() ?? KeyStoreError.exportFailed
        }
        let base64 = data.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let pem = "-----BEGIN RSA PRIVATE KEY-----\n\(base64)\n-----END RSA PRIVATE KEY-----\n"
        guard let pemData = pem.data(using: .utf8) else {
            throw KeyStoreError.exportFailed
        }
        return pemData
    }

    private func importPrivateKey(fromPEM pem: Data) throws -> SecKey? {
        #if os(macOS)
        var format = SecExternalFormat.formatUnknown
        var itemType = SecExternalItemType.itemTypeUnknown
        var items: CFArray?
        let flags: SecItemImportExportFlags = []
        let status = SecItemImport(pem as CFData, nil, &format, &itemType, flags, nil, nil, &items)
        guard status == errSecSuccess, let imported = items as? [AnyObject] else {
            return nil
        }
        for item in imported where CFGetTypeID(item) == SecKeyGetTypeID() {
            return (item as! SecKey)
        }
        return nil
        #else
        guard let pemString = String(data: pem, encoding: .utf8) else { return nil }
        let der: Data?
        if pemString.contains("BEGIN RSA PRIVATE KEY") {
            let lines = pemString
                .replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
                .replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
                .replacingOccurrences(of: "\n", with: "")
            guard let pkcs1 = Data(base64Encoded: lines) else { return nil }
            der = wrapPKCS1ToPKCS8(pkcs1)
        } else if pemString.contains("BEGIN PRIVATE KEY") {
            let lines = pemString
                .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
                .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
                .replacingOccurrences(of: "\n", with: "")
            der = Data(base64Encoded: lines)
        } else {
            return nil
        }
        guard let der else { return nil }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048,
            kSecAttrIsPermanent as String: false,
        ]
        var error: Unmanaged<CFError>?
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error)
        #endif
    }

    private func wrapPKCS1ToPKCS8(_ pkcs1: Data) -> Data {
        let rsaOID = Data([0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00])
        var octetString = Data([0x04])
        octetString.append(encodeLength(pkcs1.count))
        octetString.append(pkcs1)
        let version = Data([0x02, 0x01, 0x00])
        let inner = version + rsaOID + octetString
        var sequence = Data([0x30])
        sequence.append(encodeLength(inner.count))
        sequence.append(inner)
        return sequence
    }

    /// ADB `RSA_private_encrypt` ile uyumlu PKCS#1 v1.5 type-1 padding.
    private func pkcs1PadForADBPrivateEncrypt(token: Data, key: SecKey) throws -> Data {
        let blockSize = SecKeyGetBlockSize(key)
        guard blockSize > token.count + 3 else {
            throw KeyStoreError.signingFailed
        }

        let paddingLength = blockSize - token.count - 3
        var padded = Data([0x00, 0x01])
        padded.append(contentsOf: repeatElement(UInt8(0xFF), count: paddingLength))
        padded.append(0x00)
        padded.append(token)
        return padded
    }

    private func createSelfSignedCertificate(privateKey: SecKey) throws -> SecCertificate {
        #if os(macOS)
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw KeyStoreError.identityCreationFailed
        }

        let name = "CN=ADB,O=SwiftADB,C=US"
        let subject = try certificateName(from: name)
        let serial = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
        let notBefore = Date()
        let notAfter = Calendar.current.date(byAdding: .year, value: 10, to: notBefore)!

        var publicKeyBytes: CFData?
        var error: Unmanaged<CFError>?
        guard SecKeyCopyExternalRepresentation(publicKey, &error) != nil else {
            throw error?.takeRetainedValue() ?? KeyStoreError.identityCreationFailed
        }
        publicKeyBytes = SecKeyCopyExternalRepresentation(publicKey, &error)

        let keyPairAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecAttrIsPermanent as String: false,
        ]

        let privateKeyData = SecKeyCopyExternalRepresentation(privateKey, &error)! as Data
        guard let importedPrivate = SecKeyCreateWithData(
            privateKeyData as CFData,
            keyPairAttributes as CFDictionary,
            &error
        ) else {
            throw error?.takeRetainedValue() ?? KeyStoreError.identityCreationFailed
        }

        guard let importedPublic = SecKeyCreateWithData(
            publicKeyBytes!,
            [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
                kSecAttrKeySizeInBits as String: 2048,
            ] as CFDictionary,
            &error
        ) else {
            throw error?.takeRetainedValue() ?? KeyStoreError.identityCreationFailed
        }

        let publicKeyData = SecKeyCopyExternalRepresentation(importedPublic, &error)! as Data
        let certData = try buildMinimalRSACertificate(
            subject: subject,
            publicKeyData: publicKeyData,
            privateKey: importedPrivate,
            serial: serial,
            notBefore: notBefore,
            notAfter: notAfter
        )

        guard let certificate = SecCertificateCreateWithData(nil, certData as CFData) else {
            throw KeyStoreError.identityCreationFailed
        }
        return certificate
        #else
        throw KeyStoreError.identityCreationFailed
        #endif
    }

    private func certificateName(from string: String) throws -> Data {
        // Minimal DER UTF8String for CN
        let cn = string.replacingOccurrences(of: "CN=", with: "")
        var name = Data([0x30, 0x0D, 0x31, 0x0B, 0x30, 0x09, 0x06, 0x03, 0x55, 0x04, 0x03])
        name.append(UInt8(0x0C))
        name.append(UInt8(cn.utf8.count))
        name.append(contentsOf: cn.utf8)
        return name
    }

    private func buildMinimalRSACertificate(
        subject: Data,
        publicKeyData: Data,
        privateKey: SecKey,
        serial: Data,
        notBefore: Date,
        notAfter: Date
    ) throws -> Data {
        // Self-signed sertifika için basit DER oluşturucu
        let spki = wrapRSAPublicKey(publicKeyData)
        let validity = encodeValidity(notBefore: notBefore, notAfter: notAfter)
        let tbs = encodeSequence(
            encodeInteger(Data([0x02]))
                + encodeInteger(serial)
                + encodeSequence(Data([0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B, 0x05, 0x00]))
                + subject
                + validity
                + subject
                + spki
        )

        var signError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            tbs as CFData,
            &signError
        ) as Data? else {
            throw signError?.takeRetainedValue() ?? KeyStoreError.identityCreationFailed
        }

        let cert = encodeSequence(
            tbs
                + encodeSequence(Data([0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B, 0x05, 0x00]))
                + encodeBitString(signature)
        )
        return cert
    }

    private func wrapRSAPublicKey(_ keyData: Data) -> Data {
        let rsaOID = Data([0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00])
        let bitString = encodeBitString(keyData)
        return encodeSequence(rsaOID + bitString)
    }

    private func encodeValidity(notBefore: Date, notAfter: Date) -> Data {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        let before = encodeUTCTime(formatter.string(from: notBefore))
        let after = encodeUTCTime(formatter.string(from: notAfter))
        return encodeSequence(before + after)
    }

    private func encodeUTCTime(_ string: String) -> Data {
        var data = Data([0x17, UInt8(string.utf8.count)])
        data.append(contentsOf: string.utf8)
        return data
    }

    private func encodeInteger(_ bytes: Data) -> Data {
        var value = bytes
        if value.first ?? 0 >= 0x80 {
            value.insert(0, at: 0)
        }
        var data = Data([0x02, UInt8(value.count)])
        data.append(value)
        return data
    }

    private func encodeBitString(_ bytes: Data) -> Data {
        var data = Data([0x03, UInt8(bytes.count + 1), 0x00])
        data.append(bytes)
        return data
    }

    private func encodeSequence(_ content: Data) -> Data {
        var data = Data([0x30])
        data.append(encodeLength(content.count))
        data.append(content)
        return data
    }

    private func encodeLength(_ length: Int) -> Data {
        if length < 128 {
            return Data([UInt8(length)])
        }
        var value = length
        var bytes = [UInt8]()
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        var data = Data([0x80 | UInt8(bytes.count)])
        data.append(contentsOf: bytes)
        return data
    }

    #if !os(macOS)
    private static let keychainLabel = "com.swiftadb.adbkey.v4"
    private static let legacyKeychainLabels = [
        "com.swiftadb.adb.privatekey.v3",
        "com.swiftadb.adb.privatekey.v2",
        "com.swiftadb.adb.privatekey",
    ]

    private func loadKeyFromKeychain() -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: Self.keychainLabel,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let item else {
            return nil
        }
        return (item as! SecKey)
    }

    private func generateKeyInKeychain() throws -> SecKey {
        deleteKeychainKey()
        for legacy in Self.legacyKeychainLabels {
            SecItemDelete([
                kSecClass as String: kSecClassKey,
                kSecAttrLabel as String: legacy,
            ] as CFDictionary)
            if let tag = legacy.data(using: .utf8) {
                SecItemDelete([
                    kSecClass as String: kSecClassKey,
                    kSecAttrApplicationTag as String: tag,
                ] as CFDictionary)
            }
        }

        let key = try generateEphemeralRSAKey()
        try storePrivateKeyInKeychain(key)
        return key
    }

    private func generateEphemeralRSAKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? KeyStoreError.keyGenerationFailed
        }
        return key
    }

    private func storePrivateKeyInKeychain(_ key: SecKey) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: Self.keychainLabel,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecValueRef as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw KeyStoreError.keyImportFailed("Keychain kaydı başarısız: \(status)")
        }
    }

    private func removeLegacyKeyFilesIfPresent() {
        try? FileManager.default.removeItem(at: privateKeyURL)
        try? FileManager.default.removeItem(at: publicKeyURL)
    }

    /// iOS/iPadOS: Mac `adbkey` dosyasını içe aktarır (TV Kumandası ile aynı anahtar).
    public func replaceStoredKey(withPrivateKeyFile source: URL) throws {
        lock.lock()
        defer { lock.unlock() }

        let pem = try Data(contentsOf: source)
        guard let key = try importPrivateKey(fromPEM: pem) else {
            throw KeyStoreError.keyImportFailed("Seçilen dosya geçerli bir ADB private key değil")
        }

        cachedKey = nil
        deleteKeychainKey()

        let directory = privateKeyURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try pem.write(to: privateKeyURL, options: .atomic)
        try writePublicKeyFile(for: key)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: privateKeyURL.path
        )
        cachedKey = key
    }

    private func deleteKeychainKey() {
        SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: Self.keychainLabel,
        ] as CFDictionary)
    }
    #endif

    public func keySourceSummary() -> String {
        #if os(macOS)
        if FileManager.default.fileExists(atPath: privateKeyURL.path) {
            return "Mac ~/.android/adbkey (adb / TV Kumandası ile aynı)"
        }
        return "Mac — yeni anahtar oluşturulacak"
        #else
        if FileManager.default.fileExists(atPath: privateKeyURL.path) {
            return "İçe aktarılmış adbkey dosyası"
        }
        if loadKeyFromKeychain() != nil {
            return "iOS Keychain (adb@iOS) — ilk bağlantıda TV onayı gerekir"
        }
        return "Otomatik oluşturulacak — TV ekranında onay beklenir"
        #endif
    }
}

/// Bellek içi anahtar deposu (testler için).
public final class InMemoryKeyStore: ADBKeyStore, @unchecked Sendable {
    public let identifier: String
    private let backing = FileKeyStore(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("swiftadb-keys-\(UUID().uuidString)"),
        identifier: "test@swiftadb"
    )

    public init(identifier: String = "test@swiftadb") {
        self.identifier = identifier
    }

    public func loadOrGenerateKeyPair() throws -> SecKey {
        try backing.loadOrGenerateKeyPair()
    }

    public func signToken(_ token: Data) throws -> Data {
        try backing.signToken(token)
    }

    public func adbPublicKeyLine() throws -> String {
        try backing.adbPublicKeyLine()
    }

    public func adbPublicKeyPayload() throws -> Data {
        try backing.adbPublicKeyPayload()
    }

    public func secIdentity() throws -> SecIdentity {
        try backing.secIdentity()
    }
}
