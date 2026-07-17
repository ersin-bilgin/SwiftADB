import SwiftUI
import SwiftADB

@MainActor
public final class ADBViewModel: ObservableObject {
    @Published public var devices: [DiscoveredDevice] = []
    @Published public var usbDevices: [UsbDevice] = []
    @Published public var connectedDevice: ADBDevice?
    @Published public var shellOutput: String = ""
    @Published public var logLines: [String] = []
    @Published public var statusMessage: String = "Not connected"
    @Published public var isBusy = false

    public let client = ADBClient()

    public init() {
        AppLogStore.shared.install(minimumLevel: .info)
    }

    public func discover() async {
        isBusy = true
        defer { isBusy = false }
        statusMessage = "Searching for devices..."

        var found: [DiscoveredDevice] = []
        let discoverer = BonjourDeviceDiscoverer()
        let stream = try? await discoverer.startBrowsing()

        let task = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await discoverer.stopBrowsing()
        }

        if let stream {
            for await device in stream {
                found.append(device)
            }
        }
        task.cancel()

        #if os(macOS)
        if let usb = try? UsbMuxClient.shared.listDevices() {
            usbDevices = usb
        }
        #endif

        devices = found
        statusMessage = "\(found.count) network device(s), \(usbDevices.count) USB device(s) found"
    }

    public func connect(host: String, port: UInt16 = 5555) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await client.connect(host: host, port: port)
            connectedDevice = client.device
            statusMessage = "Connected: \(connectedDevice?.serial ?? host)"
        } catch {
            statusMessage = "Connection error: \(error)"
        }
    }

    public func connectUSB(deviceID: Int) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await client.connectUSB(deviceID: deviceID)
            connectedDevice = client.device
            statusMessage = "USB connected: \(connectedDevice?.serial ?? "")"
        } catch {
            statusMessage = "USB error: \(error)"
        }
    }

    public func disconnect() async {
        await client.disconnect()
        connectedDevice = nil
        statusMessage = "Disconnected"
    }

    public func runShell(_ command: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let shell = DefaultShellService(client: client)
            let output = try await shell.execute(command)
            shellOutput = output.stdout
            if !output.stderr.isEmpty {
                shellOutput += "\n[stderr]\n\(output.stderr)"
            }
            shellOutput += "\n[exit: \(output.exitCode)]"
            statusMessage = "Shell completed"
        } catch {
            statusMessage = "Shell error: \(error)"
        }
    }

    public func startLogcat() async {
        do {
            let logcat = DefaultLogcatService(client: client)
            let stream = try await logcat.stream(filter: nil)
            for await entry in stream {
                logLines.append("[\(entry.priority.rawValue)/\(entry.tag)] \(entry.message)")
                if logLines.count > 200 { logLines.removeFirst() }
            }
        } catch {
            statusMessage = "Logcat error: \(error)"
        }
    }
}

public struct ADBDeviceListView: View {
    @ObservedObject private var viewModel: ADBViewModel

    public init(viewModel: ADBViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        List {
            Section("Network Devices") {
                ForEach(viewModel.devices) { device in
                    Button("\(device.name) — \(device.host):\(device.port)") {
                        Task { await viewModel.connect(host: device.host, port: device.port) }
                    }
                }
            }

            #if os(macOS)
            Section("USB Devices") {
                ForEach(viewModel.usbDevices) { device in
                    Button("\(device.serial) (id=\(device.id))") {
                        Task { await viewModel.connectUSB(deviceID: device.id) }
                    }
                }
            }
            #endif
        }
        .navigationTitle("Devices")
    }
}

public struct ADBShellView: View {
    @ObservedObject private var viewModel: ADBViewModel
    @State private var command = "getprop ro.product.model"

    public init(viewModel: ADBViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Command", text: $command)
                .textFieldStyle(.roundedBorder)

            Button("Run") {
                Task { await viewModel.runShell(command) }
            }
            .disabled(viewModel.connectedDevice == nil || viewModel.isBusy)

            ScrollView {
                Text(viewModel.shellOutput.isEmpty ? "No output" : viewModel.shellOutput)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .navigationTitle("Shell")
    }
}

public struct ADBMainView: View {
    @StateObject private var viewModel = ADBViewModel()

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(viewModel.statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Discover") { Task { await viewModel.discover() } }
                    Button("Disconnect") { Task { await viewModel.disconnect() } }
                        .disabled(viewModel.connectedDevice == nil)
                }

                NavigationLink("Devices") {
                    ADBDeviceListView(viewModel: viewModel)
                }
                NavigationLink("Shell") {
                    ADBShellView(viewModel: viewModel)
                }
            }
            .padding()
            .navigationTitle("SwiftADB")
        }
    }
}

#if os(iOS)
/// iOS app entry point — use as `@main` in an Xcode iOS project.
public struct SwiftADBiOSApp: App {
    public init() {}

    public var body: some Scene {
        WindowGroup {
            ADBMainView()
        }
    }
}
#endif
