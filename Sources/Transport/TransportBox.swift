import Foundation

/// Tip silinmiş ADB transport sarmalayıcısı.
public final class TransportBox: @unchecked Sendable {
    public let transport: any ADBTransport

    public init(_ transport: any ADBTransport) {
        self.transport = transport
    }
}
