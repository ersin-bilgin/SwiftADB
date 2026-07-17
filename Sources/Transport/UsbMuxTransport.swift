import Foundation
#if os(macOS)
import Darwin
#endif

/// Android device connected over USB.
public struct UsbDevice: Sendable, Identifiable, Equatable {
    public let id: Int
    public let serial: String
    public let productID: Int
    public let connectionType: String

    public init(id: Int, serial: String, productID: Int, connectionType: String = "USB") {
        self.id = id
        self.serial = serial
        self.productID = productID
        self.connectionType = connectionType
    }
}

public enum UsbMuxError: Error, Sendable {
    case socketUnavailable
    case requestFailed(String)
    case deviceNotFound
    case notSupported
}

#if os(macOS)

/// USB ADB connection via usbmuxd (macOS).
public final class UsbMuxTransport: ADBTransport, @unchecked Sendable {
    public let host: String
    public let port: UInt16

    private let deviceID: Int
    private var socketFD: Int32 = -1
    private var connected = false

    public init(deviceID: Int, port: UInt16 = 5555) {
        self.deviceID = deviceID
        self.host = "usb:\(deviceID)"
        self.port = port
    }

    public var isConnected: Bool {
        get async { connected }
    }

    public func connect() async throws {
        socketFD = try UsbMuxClient.shared.connect(deviceID: deviceID, port: port)
        connected = true
        ADBLog.info("USB connection established: device=\(deviceID) port=\(port)", category: "UsbMux")
    }

    public func disconnect() async {
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        connected = false
    }

    public func send(header: ADBMessageHeader, payload: Data?) async throws {
        guard connected, socketFD >= 0 else { throw TransportError.notConnected }
        let packet = ADBMessageCodec.encode(header: header, payload: payload)
        try write(packet)
    }

    public func receiveHeader() async throws -> ADBMessageHeader {
        let data = try read(count: ADBMessageHeader.size)
        return try ADBMessageCodec.decodeHeader(from: data)
    }

    public func receivePayload(length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        return try read(count: length)
    }

    public func receiveMessage() async throws -> ADBMessage {
        let header = try await receiveHeader()
        let payload = try await receivePayload(length: Int(header.payloadLength))
        try ADBMessageCodec.validatePayload(payload, expectedChecksum: header.checksum)
        return ADBMessage(header: header, payload: payload)
    }

    public func upgradeToTLS(identity: SecIdentity) async throws {
        _ = identity
        throw TransportError.tlsUpgradeFailed
    }

    public func sendRaw(_ data: Data) async throws {
        guard connected else { throw TransportError.notConnected }
        try write(data)
    }

    public func receiveRaw(count: Int) async throws -> Data {
        try read(count: count)
    }

    private func write(_ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let result = Darwin.write(socketFD, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
                if result <= 0 { throw TransportError.connectionClosed }
                sent += result
            }
        }
    }

    private func read(count: Int) throws -> Data {
        var buffer = Data(count: count)
        var received = 0
        try buffer.withUnsafeMutableBytes { ptr in
            while received < count {
                let result = Darwin.read(socketFD, ptr.baseAddress!.advanced(by: received), count - received)
                if result <= 0 { throw TransportError.connectionClosed }
                received += result
            }
        }
        return buffer
    }
}

/// usbmuxd client — device listing and port tunnel.
public final class UsbMuxClient: @unchecked Sendable {
    public static let shared = UsbMuxClient()

    private let socketPath = "/var/run/usbmuxd"

    public func listDevices() throws -> [UsbDevice] {
        let fd = try openSocket()
        defer { close(fd) }

        let tag = UInt32.random(in: 1...UInt32.max)
        let payload = UsbMuxPlist.listDevices(tag: tag)
        try send(fd: fd, payload: payload, tag: tag)

        let response = try receivePlist(fd: fd)
        return UsbMuxPlist.parseDevices(from: response)
    }

    func connect(deviceID: Int, port: UInt16) throws -> Int32 {
        let fd = try openSocket()
        let tag = UInt32.random(in: 1...UInt32.max)
        let payload = UsbMuxPlist.connect(deviceID: deviceID, port: UInt(port), tag: tag)
        try send(fd: fd, payload: payload, tag: tag)

        let response = try receivePlist(fd: fd)
        guard UsbMuxPlist.isSuccess(response) else {
            close(fd)
            throw UsbMuxError.requestFailed("Connect failed")
        }
        return fd
    }

    private func openSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UsbMuxError.socketUnavailable }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let pathPtr = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                strncpy(pathPtr, cstr, 103)
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, size)
            }
        }
        guard result == 0 else {
            close(fd)
            throw UsbMuxError.socketUnavailable
        }
        return fd
    }

    private func send(fd: Int32, payload: Data, tag: UInt32) throws {
        var header = UsbMuxHeader(length: UInt32(16 + payload.count), message: 8, tag: tag)
        var packet = Data()
        packet.append(header.encode())
        packet.append(payload)
        try packet.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
                if n <= 0 { throw UsbMuxError.requestFailed("Write error") }
                sent += n
            }
        }
    }

    private func receivePlist(fd: Int32) throws -> [String: Any] {
        var headerData = Data(count: 16)
        try headerData.withUnsafeMutableBytes { ptr in
            var received = 0
            while received < 16 {
                let n = Darwin.read(fd, ptr.baseAddress!.advanced(by: received), 16 - received)
                if n <= 0 { throw UsbMuxError.requestFailed("Read error") }
                received += n
            }
        }
        let header = UsbMuxHeader.decode(headerData)
        let bodyLength = Int(header.length) - 16
        var body = Data(count: max(0, bodyLength))
        if !body.isEmpty {
            let readCount = body.count
            try body.withUnsafeMutableBytes { ptr in
                var received = 0
                while received < readCount {
                    let n = Darwin.read(fd, ptr.baseAddress!.advanced(by: received), readCount - received)
                    if n <= 0 { throw UsbMuxError.requestFailed("Read error") }
                    received += n
                }
            }
        }
        guard let plist = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else {
            throw UsbMuxError.requestFailed("Invalid plist")
        }
        return plist
    }
}

private struct UsbMuxHeader {
    let length: UInt32
    let version: UInt32 = 1
    let message: UInt32
    let tag: UInt32

    func encode() -> Data {
        var data = Data()
        [length, version, message, tag].forEach { value in
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decode(_ data: Data) -> UsbMuxHeader {
        UsbMuxHeader(
            length: data.readU32LE(0),
            message: data.readU32LE(8),
            tag: data.readU32LE(12)
        )
    }
}

private enum UsbMuxPlist {
    static func listDevices(tag: UInt32) -> Data {
        plist([
            "MessageType": "ListDevices",
            "ClientVersionString": "SwiftADB",
            "ProgName": "SwiftADB",
            "kLibUSBMuxVersion": 3,
        ], tag: tag)
    }

    static func connect(deviceID: Int, port: UInt, tag: UInt32) -> Data {
        plist([
            "MessageType": "Connect",
            "PortNumber": port,
            "DeviceID": deviceID,
        ], tag: tag)
    }

    static func parseDevices(from dict: [String: Any]) -> [UsbDevice] {
        guard let deviceList = dict["DeviceList"] as? [[String: Any]] else { return [] }
        return deviceList.compactMap { entry in
            guard let id = entry["DeviceID"] as? Int,
                  let serial = entry["SerialNumber"] as? String else { return nil }
            let pid = entry["ProductID"] as? Int ?? 0
            let conn = entry["ConnectionType"] as? String ?? "USB"
            return UsbDevice(id: id, serial: serial, productID: pid, connectionType: conn)
        }
    }

    static func isSuccess(_ dict: [String: Any]) -> Bool {
        if let number = dict["Number"] as? Int { return number == 0 }
        return false
    }

    private static func plist(_ body: [String: Any], tag: UInt32) -> Data {
        var payload = try! PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        var header = Data()
        let length = UInt32(16 + payload.count)
        var fields: [UInt32] = [length, 1, 8, tag] // 8 = plist message type
        for var field in fields {
            header.append(Data(bytes: &field, count: 4))
        }
        return header + payload
    }
}

private extension Data {
    func readU32LE(_ offset: Int) -> UInt32 {
        subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    }
}

#else

public final class UsbMuxTransport: ADBTransport, @unchecked Sendable {
    public let host = "usb"
    public let port: UInt16 = 0
    public var isConnected: Bool { get async { false } }
    public func connect() async throws { throw UsbMuxError.notSupported }
    public func disconnect() async {}
    public func send(header: ADBMessageHeader, payload: Data?) async throws { throw UsbMuxError.notSupported }
    public func receiveHeader() async throws -> ADBMessageHeader { throw UsbMuxError.notSupported }
    public func receivePayload(length: Int) async throws -> Data { throw UsbMuxError.notSupported }
    public func receiveMessage() async throws -> ADBMessage { throw UsbMuxError.notSupported }
    public func upgradeToTLS(identity: SecIdentity) async throws { throw UsbMuxError.notSupported }
    public func sendRaw(_ data: Data) async throws { throw UsbMuxError.notSupported }
    public func receiveRaw(count: Int) async throws -> Data { throw UsbMuxError.notSupported }
}

public final class UsbMuxClient: @unchecked Sendable {
    public static let shared = UsbMuxClient()
    public func listDevices() throws -> [UsbDevice] { throw UsbMuxError.notSupported }
}

#endif
