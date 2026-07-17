import Foundation
import SwiftADB

struct DeviceTestResult: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let passed: Bool
    let detail: String
    let duration: TimeInterval
}

enum DeviceTestRunner {
    static func runAll(
        host: String,
        port: UInt16,
        keyStore: FileKeyStore = FileKeyStore(),
        existingClient: ADBClient? = nil,
        onResult: (@MainActor @Sendable (DeviceTestResult) -> Void)? = nil
    ) async -> [DeviceTestResult] {
        var results: [DeviceTestResult] = []
        let client = existingClient ?? ADBClient(keyStore: keyStore)
        let ownsClient = existingClient == nil

        func append(_ result: DeviceTestResult) async {
            results.append(result)
            await onResult?(result)
        }

        if ownsClient {
            await append(await measure("Connection") {
                try await client.connect(host: host, port: port)
                guard client.device != nil else {
                    throw TestFailure("Could not retrieve device info")
                }
                return client.device?.serial ?? host
            })
        } else {
            await append(DeviceTestResult(
                name: "Connection",
                passed: client.device != nil,
                detail: client.device?.model ?? client.device?.serial ?? "Existing session",
                duration: 0
            ))
        }

        guard results.last?.passed == true else {
            if ownsClient { await client.disconnect() }
            return results
        }

        await append(await measure("Shell — model") {
            let shell = DefaultShellService(client: client)
            let output = try await shell.execute("getprop ro.product.model")
            let model = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { throw TestFailure("Empty model output") }
            return model
        })

        await append(await measure("Shell — echo") {
            let shell = DefaultShellService(client: client)
            let output = try await shell.execute("echo swiftadb-test")
            guard output.stdout.contains("swiftadb-test") else {
                throw TestFailure("Unexpected echo output: \(output.stdout)")
            }
            return "exit \(output.exitCode)"
        })

        await append(await measure("FileSync — stat") {
            let sync = DefaultFileSyncService(client: client)
            let info = try await sync.stat(remotePath: "/storage/emulated/0")
            return "mode=\(info.mode) size=\(info.size)"
        })

        await append(await measure("Banner") {
            guard let banner = client.device?.banner, !banner.isEmpty else {
                throw TestFailure("No banner")
            }
            return banner
        })

        if ownsClient {
            await client.disconnect()
        }
        await append(DeviceTestResult(
            name: "Disconnect",
            passed: true,
            detail: ownsClient ? "Session closed" : "Session left open",
            duration: 0
        ))
        return results
    }

    private static func measure(
        _ name: String,
        _ operation: () async throws -> String
    ) async -> DeviceTestResult {
        let start = ContinuousClock.now
        do {
            let detail = try await operation()
            let duration = start.duration(to: .now).timeInterval
            return DeviceTestResult(name: name, passed: true, detail: detail, duration: duration)
        } catch {
            let duration = start.duration(to: .now).timeInterval
            return DeviceTestResult(name: name, passed: false, detail: String(describing: error), duration: duration)
        }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
