import Foundation
import Testing
@testable import SwiftADB

@Test func messageHeaderSize() {
    #expect(ADBMessageHeader.size == 24)
}

@Test func messageHeaderMagic() {
    let header = ADBMessageHeader(command: .cnxn)
    #expect(header.magic == ADBCommand.cnxn.rawValue ^ 0xFFFF_FFFF)
}

@Test func transferProgressFraction() {
    let progress = TransferProgress(bytesTransferred: 50, totalBytes: 100)
    #expect(progress.fractionCompleted == 0.5)
}

@Test func discoveredDeviceIdentity() {
    let device = DiscoveredDevice(id: "abc123", name: "Pixel", host: "192.168.1.10")
    #expect(device.port == 5555)
    #expect(device.id == "abc123")
}

@Test func deviceFactoryManual() {
    let device = DeviceFactory.manual(host: "10.0.0.5", port: 5555)
    #expect(device.host == "10.0.0.5")
}

@Test func logcatParser() {
    let entry = DefaultLogcatService.parseLine("I/ActivityManager(1234): Starting service")
    #expect(entry?.priority == .info)
    #expect(entry?.tag == "ActivityManager")
    #expect(entry?.pid == 1234)
}

@Test func adbProtocolConstants() {
    #expect(ADBProtocol.version == 0x0100_0000)
    #expect(ADBProtocol.maxDataSize == 256 * 1024)
}

@Test func pairingSessionCreation() {
    let session = PairingSession(host: "192.168.1.1", port: 12345, method: .pairingCode("123456"))
    #expect(session.port == 12345)
}

@Test func swiftADBVersion() {
    #expect(SwiftADBVersion.current == "0.2.0")
}
