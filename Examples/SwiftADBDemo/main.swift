import Foundation
import SwiftADB

@main
struct SwiftADBDemo {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())

        guard let command = args.first else {
            printUsage()
            return
        }

        let client = ADBClient()
        ADBLog.logger = ConsoleADBLogger(minimumLevel: .info)

        do {
            switch command {
            case "discover":
                try await runDiscover()
            case "usb":
                try await runUSB(args: args, client: client)
            case "pair":
                try await runPair(args: args, client: client)
            case "connect":
                try await runConnect(args: args, client: client)
            case "shell":
                try await runShell(args: args, client: client)
            case "push":
                try await runPush(args: args, client: client)
            case "pull":
                try await runPull(args: args, client: client)
            case "stat":
                try await runStat(args: args, client: client)
            case "logcat":
                try await runLogcat(args: args, client: client)
            case "forward":
                try await runForward(args: args, client: client)
            case "devices":
                try await runDevices(args: args, client: client)
            case "keys":
                try runKeys()
            case "connect-newkey":
                try await runConnectNewKey(args: args)
            case "keys-compare":
                try runKeysCompare()
            default:
                print("Unknown command: \(command)")
                printUsage()
            }
        } catch {
            fputs("Error: \(error)\n", stderr)
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        SwiftADBDemo — SwiftADB test tool

        Usage:
          swift run SwiftADBDemo discover
          swift run SwiftADBDemo usb [connect <deviceID>]
          swift run SwiftADBDemo pair <host> <port> <code>
          swift run SwiftADBDemo connect <host> [port]
          swift run SwiftADBDemo devices <host> [port]
          swift run SwiftADBDemo shell <host> [port] <command>
          swift run SwiftADBDemo push <host> <local> <remote> [port]
          swift run SwiftADBDemo pull <host> <remote> <local> [port]
          swift run SwiftADBDemo stat <host> <remotePath> [port]
          swift run SwiftADBDemo logcat <host> [port]
          swift run SwiftADBDemo forward <host> <localPort> <remotePort> [port]

        Example:
          swift run SwiftADBDemo connect 192.168.1.42 5555
          swift run SwiftADBDemo keys
          swift run SwiftADBDemo shell 192.168.1.42 5555 "getprop ro.product.model"
        """)
    }

    static func runUSB(args: [String], client: ADBClient) async throws {
        if args.count >= 3, args[1] == "connect", let deviceID = Int(args[2]) {
            try await client.connectUSB(deviceID: deviceID)
            if let device = client.device {
                print("USB connected: \(device.serial)")
            }
            await client.disconnect()
            return
        }

        #if os(macOS)
        let devices = try UsbMuxClient.shared.listDevices()
        if devices.isEmpty {
            print("No USB devices found.")
        } else {
            for device in devices {
                print("• id=\(device.id) serial=\(device.serial) pid=\(device.productID)")
            }
        }
        #else
        print("USB listing is only supported on macOS.")
        #endif
    }

    static func runDiscover() async throws {
        print("Searching for ADB devices (_adb._tcp)...")
        let discoverer = BonjourDeviceDiscoverer()
        let stream = try await discoverer.startBrowsing()

        let timeout = Task {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            await discoverer.stopBrowsing()
        }

        for await device in stream {
            print("• \(device.name) — \(device.host):\(device.port)")
        }

        timeout.cancel()
    }

    static func runPair(args: [String], client: ADBClient) async throws {
        guard args.count >= 4 else {
            print("Usage: pair <host> <port> <code>")
            return
        }
        let host = args[1]
        guard let port = UInt16(args[2]) else { throw DemoError.invalidPort }
        let code = args[3]
        print("Pairing: \(host):\(port)...")
        try await client.pair(host: host, port: port, code: code)
        print("Pairing succeeded.")
    }

    static func runConnect(args: [String], client: ADBClient) async throws {
        let (host, port) = try parseHostPort(args: args, commandIndex: 1)
        print("Connecting: \(host):\(port)...")
        try await client.connect(host: host, port: port)
        if let device = client.device {
            print("Connected: \(device.serial) \(device.model ?? "")")
            if let banner = device.banner {
                print("Banner: \(banner)")
            }
        }
        await client.disconnect()
    }

    static func runConnectNewKey(args: [String]) async throws {
        let (host, port) = try parseHostPort(args: args, commandIndex: 1)
        ADBLog.logger = ConsoleADBLogger(minimumLevel: .debug)
        let keyStore = InMemoryKeyStore(identifier: "adb@iOS")
        _ = try keyStore.loadOrGenerateKeyPair()
        let wire = try keyStore.adbPublicKeyWireData()
        print("New key pubkey wire: \(wire.count) bytes")
        print(String(data: wire.prefix(60), encoding: .utf8) ?? "?")
        let client = ADBClient(keyStore: keyStore)
        print("Connecting (new key): \(host):\(port)...")
        try await client.connect(host: host, port: port)
        if let device = client.device {
            print("Connected: \(device.serial) \(device.model ?? "")")
        }
        await client.disconnect()
    }

    static func runKeysCompare() throws {
        let adbPath = resolveADBPath()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftadb-keycmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let keyPath = tmp.appendingPathComponent("adbkey")

        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: adbPath)
        keygen.arguments = ["keygen", keyPath.path]
        try keygen.run()
        keygen.waitUntilExit()
        guard keygen.terminationStatus == 0 else {
            throw DemoError.commandFailed("adb keygen")
        }

        let pubkey = Process()
        let pipe = Pipe()
        pubkey.executableURL = URL(fileURLWithPath: adbPath)
        pubkey.arguments = ["pubkey", keyPath.path]
        pubkey.standardOutput = pipe
        try pubkey.run()
        pubkey.waitUntilExit()
        let adbLine = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let adbB64 = adbLine.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""

        let store = FileKeyStore(directory: tmp, identifier: "adb@test")
        _ = try store.loadOrGenerateKeyPair()
        let swiftLine = try store.adbPublicKeyLine()
        let swiftB64 = swiftLine.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""

        print("adb b64 len: \(adbB64.count)")
        print("Swift b64 len: \(swiftB64.count)")
        print("Match: \(adbB64 == swiftB64)")
        if adbB64 != swiftB64 {
            print("adb:   \(adbB64.prefix(48))…")
            print("Swift: \(swiftB64.prefix(48))…")
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    static func resolveADBPath() -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["adb"]
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? "/usr/bin/adb" : path
    }

    static func runKeys() throws {
        let keyStore = FileKeyStore()
        let keyPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".android/adbkey")
        let pubPath = keyPath.deletingLastPathComponent().appendingPathComponent("adbkey.pub")

        print("SwiftADB version: \(SwiftADBVersion.current)")
        print("Key file: \(keyPath.path)")
        print("Key exists: \(FileManager.default.fileExists(atPath: keyPath.path))")

        let line = try keyStore.adbPublicKeyLine()
        let swiftB64 = line.split(separator: " ").first.map(String.init) ?? ""
        if FileManager.default.fileExists(atPath: pubPath.path),
           let filePub = try? String(contentsOf: pubPath, encoding: .utf8) {
            let fileB64 = filePub.split(separator: " ").first.map(String.init) ?? ""
            print("Pubkey matches adb: \(swiftB64 == fileB64)")
            if swiftB64 != fileB64 {
                print("  Swift:  \(swiftB64.prefix(48))…")
                print("  adbkey: \(fileB64.prefix(48))…")
            }
        }

        let token = Data(repeating: 0xAB, count: ADBProtocol.tokenSize)
        let signature = try keyStore.signToken(token)
        print("Signature length: \(signature.count) bytes (expected: 256)")

        #if os(macOS)
        let tempDir = FileManager.default.temporaryDirectory
        let tokenURL = tempDir.appendingPathComponent("swiftadb-token.bin")
        let sigURL = tempDir.appendingPathComponent("swiftadb-openssl.sig")
        try token.write(to: tokenURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "dgst", "-sha1", "-sign", keyPath.path,
            "-out", sigURL.path, tokenURL.path,
        ]
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0,
           let opensslSig = try? Data(contentsOf: sigURL) {
            print("Same as OpenSSL signature: \(signature == opensslSig)")
            if signature != opensslSig {
                print("  Swift:   \(signature.prefix(12).map { String(format: "%02x", $0) }.joined())…")
                print("  OpenSSL: \(opensslSig.prefix(12).map { String(format: "%02x", $0) }.joined())…")
            }
        } else {
            print("OpenSSL comparison unavailable (openssl rsautl)")
        }
        #endif
    }

    static func runDevices(args: [String], client: ADBClient) async throws {
        let (host, port) = try parseHostPort(args: args, commandIndex: 1)
        try await client.connect(host: host, port: port)
        defer { Task { await client.disconnect() } }

        if let device = client.device {
            print("serial\t\(device.serial)")
            print("model\t\(device.model ?? "-")")
            print("host\t\(device.host):\(device.port)")
        }
    }

    static func runShell(args: [String], client: ADBClient) async throws {
        guard args.count >= 3 else {
            print("Usage: shell <host> [port] <command>")
            return
        }

        let host = args[1]
        let (port, commandStart): (UInt16, Int)
        if args.count >= 4, let parsedPort = UInt16(args[2]) {
            port = parsedPort
            commandStart = 3
        } else {
            port = 5555
            commandStart = 2
        }

        let command = args[commandStart...].joined(separator: " ")
        try await client.connect(host: host, port: port)
        defer { Task { await client.disconnect() } }

        let shell = DefaultShellService(client: client)
        let output = try await shell.execute(command)
        print(output.stdout)
        if !output.stderr.isEmpty {
            fputs(output.stderr, stderr)
        }
    }

    static func runPush(args: [String], client: ADBClient) async throws {
        guard args.count >= 4 else {
            print("Usage: push <host> <local> <remote> [port]")
            return
        }
        let host = args[1]
        let local = URL(fileURLWithPath: args[2])
        let remote = args[3]
        let port = args.count >= 5 ? (UInt16(args[4]) ?? 5555) : 5555

        try await client.connect(host: host, port: port)
        defer { Task { await client.disconnect() } }

        let sync = DefaultFileSyncService(client: client)
        try await sync.push(localURL: local, remotePath: remote) { progress in
            let percent = Int(progress.fractionCompleted * 100)
            print("\rTransfer: %\(percent)", terminator: "")
        }
        print("\nPush completed.")
    }

    static func runPull(args: [String], client: ADBClient) async throws {
        guard args.count >= 4 else {
            print("Usage: pull <host> <remote> <local> [port]")
            return
        }
        let host = args[1]
        let remote = args[2]
        let local = URL(fileURLWithPath: args[3])
        let port = args.count >= 5 ? (UInt16(args[4]) ?? 5555) : 5555

        try await client.connect(host: host, port: port)
        defer { Task { await client.disconnect() } }

        let sync = DefaultFileSyncService(client: client)
        try await sync.pull(remotePath: remote, localURL: local) { progress in
            let percent = Int(progress.fractionCompleted * 100)
            print("\rTransfer: %\(percent)", terminator: "")
        }
        print("\nPull completed.")
    }

    static func runStat(args: [String], client: ADBClient) async throws {
        guard args.count >= 3 else {
            print("Usage: stat <host> <remotePath> [port]")
            return
        }
        let host = args[1]
        let remote = args[2]
        let port = args.count >= 4 ? (UInt16(args[3]) ?? 5555) : 5555

        ADBLog.logger = ConsoleADBLogger(minimumLevel: .debug)
        try await client.connect(host: host, port: port)
        defer { Task { await client.disconnect() } }

        let sync = DefaultFileSyncService(client: client)
        let info = try await sync.stat(remotePath: remote)
        print("mode=\(info.mode) size=\(info.size) mtime=\(info.mtime)")
    }

    static func runLogcat(args: [String], client: ADBClient) async throws {
        let (host, port) = try parseHostPort(args: args, commandIndex: 1)
        try await client.connect(host: host, port: port)
        defer { Task { await client.disconnect() } }

        print("Logcat stream started (Ctrl+C to stop)...")
        let logcat = DefaultLogcatService(client: client)
        let stream = try await logcat.stream(filter: nil)

        for await entry in stream {
            print("[\(entry.priority.rawValue)/\(entry.tag)(\(entry.pid))] \(entry.message)")
        }
    }

    static func runForward(args: [String], client: ADBClient) async throws {
        guard args.count >= 4 else {
            print("Usage: forward <host> <localPort> <remotePort> [port]")
            return
        }
        let host = args[1]
        guard let localPort = UInt16(args[2]), let remotePort = UInt16(args[3]) else {
            throw DemoError.invalidPort
        }
        let port = args.count >= 5 ? (UInt16(args[4]) ?? 5555) : 5555

        try await client.connect(host: host, port: port)
        let forward = DefaultPortForwardService(client: client)
        let session = try await forward.forward(.local(localPort: localPort, remotePort: remotePort))
        print("Port forwarding active: localhost:\(localPort) → device:\(remotePort)")
        print("Press Ctrl+C to stop")

        try await Task.sleep(nanoseconds: 3600_000_000_000)
        try await forward.remove(session)
    }

    static func parseHostPort(args: [String], commandIndex: Int) throws -> (String, UInt16) {
        guard args.count > commandIndex else {
            throw DemoError.missingHost
        }
        let host = args[commandIndex]
        if args.count > commandIndex + 1, let port = UInt16(args[commandIndex + 1]) {
            return (host, port)
        }
        return (host, 5555)
    }
}

enum DemoError: Error, CustomStringConvertible {
    case missingHost
    case invalidPort
    case commandFailed(String)

    var description: String {
        switch self {
        case .missingHost: return "Host address required"
        case .invalidPort: return "Invalid port"
        case .commandFailed(let cmd): return "Command failed: \(cmd)"
        }
    }
}
