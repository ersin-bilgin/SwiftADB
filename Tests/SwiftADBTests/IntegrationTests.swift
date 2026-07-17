import Foundation
import Testing
@testable import SwiftADB

@Test func mockTransportCNXNHandshake() async throws {
    let mock = MockADBTransport()
    let client = ADBClient(keyStore: InMemoryKeyStore())
    try await client.connect(transport: mock)

    let device = client.device
    #expect(device != nil)
    #expect(device?.serial == "ABC123")
    await client.disconnect()
}

@Test func mockTransportShellExecute() async throws {
    let mock = MockADBTransport()
    let response = Data("Hello Mock\n".utf8)
    mock.shellResponses["shell:echo hello"] = response

    let client = ADBClient(keyStore: InMemoryKeyStore())
    try await client.connect(transport: mock)

    let shell = DefaultShellService(client: client)
    let output = try await shell.execute("echo hello", protocolVersion: .v1)
    #expect(output.stdout.contains("Hello Mock"))

    await client.disconnect()
}

@Test func mockTransportRequiresAuthMessage() async throws {
    let mock = MockADBTransport(requireAuth: true)
    try await mock.connect()
    try await mock.send(
        header: ADBMessageHeader(command: .cnxn, arg0: ADBProtocol.version, arg1: ADBProtocol.maxDataSize),
        payload: Data("host::\0".utf8)
    )
    let message = try await mock.receiveMessage()
    #expect(message.command == .auth)
    await mock.disconnect()
}

@Test func shellV2Destination() {
    let destination = "shell,v2,raw:getprop ro.build.version.release"
    #expect(destination.hasPrefix("shell,v2,raw:"))
}

@Test func portForwardSession() {
    let session = PortForwardSession(direction: .remote(localPort: 8080, remotePort: 8080), localPort: 8080)
    #expect(session.localPort == 8080)
}

@Test func adbLogger() {
    ADBLog.logger = ConsoleADBLogger(minimumLevel: .error)
    ADBLog.error("test error")
    #expect(Bool(true))
}
