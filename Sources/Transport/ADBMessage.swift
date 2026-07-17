import Foundation

/// ADB protokol mesaj komutları (little-endian fourcc).
public enum ADBCommand: UInt32, Sendable {
    case sync = 0x434e5953 // SYNC
    case cnxn = 0x4e584e43 // CNXN
    case auth = 0x48545541 // AUTH
    case open = 0x4e45504f // OPEN
    case okay = 0x59414b4f // OKAY
    case clse = 0x45534c43 // CLSE
    case wrte = 0x45545257 // WRTE
    case stls = 0x534c5453 // STLS
}

public enum ADBProtocol {
    public static let version: UInt32 = 0x0100_0000
    public static let maxDataSize: UInt32 = 256 * 1024
    public static let tokenSize = 20
    public static let defaultBanner = "host::features=shell_v2"
}

/// ADB mesaj başlığı (24 bayt).
public struct ADBMessageHeader: Sendable, Equatable {
    public let command: ADBCommand
    public let arg0: UInt32
    public let arg1: UInt32
    public let payloadLength: UInt32
    public let checksum: UInt32
    public let magic: UInt32

    public init(
        command: ADBCommand,
        arg0: UInt32 = 0,
        arg1: UInt32 = 0,
        payloadLength: UInt32 = 0,
        checksum: UInt32 = 0,
        magic: UInt32? = nil
    ) {
        self.command = command
        self.arg0 = arg0
        self.arg1 = arg1
        self.payloadLength = payloadLength
        self.checksum = checksum
        self.magic = magic ?? (command.rawValue ^ 0xFFFF_FFFF)
    }

    public static let size = 24
}

/// Tam ADB mesajı (başlık + payload).
public struct ADBMessage: Sendable {
    public let header: ADBMessageHeader
    public let payload: Data

    public init(header: ADBMessageHeader, payload: Data = Data()) {
        self.header = header
        self.payload = payload
    }

    public var command: ADBCommand { header.command }
}

/// Taşıma katmanı hataları.
public enum TransportError: Error, Sendable, Equatable {
    case notConnected
    case connectionClosed
    case invalidMessage
    case checksumMismatch
    case timeout
    case tlsUpgradeFailed
    case underlying(String)
}
