import SwiftUI
#if os(iOS)
import UIKit
#endif
import SwiftADB
import SwiftADBiOSKit

private enum ConnectionPhase: Equatable {
    case idle
    case connecting
    case awaitingTVApproval
    case connected(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return "Not connected"
        case .connecting:
            return "Connecting…"
        case .awaitingTVApproval:
            return "Waiting for TV approval (30 s)"
        case .connected(let detail):
            return "Connected — \(detail)"
        case .failed(let message):
            return message
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .connecting, .awaitingTVApproval:
            return true
        default:
            return false
        }
    }
}

struct TestAppView: View {
    @StateObject private var logStore = AppLogStore.shared
    #if os(iOS)
    @StateObject private var localNetwork = LocalNetworkPermission()
    #endif
    @State private var keyStore = FileKeyStore()
    @State private var client = ADBClient()
    @State private var keySource = ""
    @State private var host = "192.168.1.8"
    @State private var port = "5555"
    @State private var connectionPhase: ConnectionPhase = .idle
    @State private var isRunningTests = false
    @State private var results: [DeviceTestResult] = []
    @State private var status = "Ready"
    @State private var selectedTab = 0
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var isBusy: Bool {
        connectionPhase.isBusy || isRunningTests
    }

    var body: some View {
        Group {
            if sizeClass == .compact {
                compactLayout
            } else {
                regularLayout
            }
        }
        .onAppear {
            logStore.install(minimumLevel: .debug)
            refreshKeyStore()
            #if os(iOS)
            Task { await localNetwork.refresh() }
            #endif
        }
    }

    private var regularLayout: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            TabView(selection: $selectedTab) {
                resultsPanel
                    .tabItem { Label("Results", systemImage: "checklist") }
                    .tag(0)
                logPanel
                    .tabItem { Label("Log", systemImage: "text.alignleft") }
                    .tag(1)
            }
        }
    }

    private var compactLayout: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sidebar
                Picker("", selection: $selectedTab) {
                    Text("Results").tag(0)
                    Text("Log").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                if selectedTab == 0 {
                    resultsPanel
                } else {
                    logPanel
                }
            }
            .navigationTitle("SwiftADB Test")
        }
    }

    private var sidebar: some View {
        Form {
            Section("Target Device") {
                TextField("Host", text: $host)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                    .disabled(isBusy)
                TextField("Port", text: $port)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .disabled(isBusy)
            }

            Section {
                Button {
                    Task { await connectToTV() }
                } label: {
                    Label(
                        connectionPhase.isBusy ? "Connecting…" : "Connect to TV",
                        systemImage: "tv.and.mediabox"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isBusy || host.isEmpty)

                if connectionPhase.isConnected {
                    Button("Disconnect", role: .destructive) {
                        Task { await disconnectFromTV() }
                    }
                    .disabled(isRunningTests)
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: connectionIcon)
                        .foregroundStyle(connectionColor)
                    Text(connectionPhase.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                #if os(iOS)
                if connectionPhase == .awaitingTVApproval {
                    Label(
                        "On the TV, approve the \"Allow USB debugging\" dialog.",
                        systemImage: "hand.tap.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                #endif
            } header: {
                Text("Connection")
            } footer: {
                #if os(iOS)
                Text("The key is generated automatically. The first connection requires approval on the TV; you do not need to import an adbkey.")
                #else
                Text("Uses Mac ~/.android/adbkey. If the key is registered on the TV, no approval dialog appears.")
                #endif
            }

            #if os(iOS)
            Section("Local Network") {
                Label(localNetwork.status.label, systemImage: "wifi")
                    .font(.caption)
                    .foregroundStyle(localNetwork.status == .denied ? .red : .secondary)
                if localNetwork.status == .denied {
                    Text(LocalNetworkPermission.settingsHint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } else {
                    Text("iOS local network permission is required to reach the TV. A permission prompt may appear on first launch.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            #endif

            Section("ADB Key") {
                Text(keySource)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Tests") {
                Button(isRunningTests ? "Running tests…" : "Run All Tests") {
                    Task { await runTests() }
                }
                .disabled(isBusy || host.isEmpty)

                Button("Clear") {
                    results = []
                    if !connectionPhase.isConnected {
                        status = "Ready"
                    }
                }
                .disabled(isBusy)

                Button("Clear logs") {
                    logStore.clear()
                }
            }

            Section("Status") {
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("SwiftADB \(SwiftADBVersion.current)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        .frame(minWidth: 280)
        #endif
        .navigationTitle("Device Tests")
    }

    private var connectionIcon: String {
        switch connectionPhase {
        case .idle:
            return "tv.slash"
        case .connecting, .awaitingTVApproval:
            return "arrow.triangle.2.circlepath"
        case .connected:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var connectionColor: Color {
        switch connectionPhase {
        case .idle:
            return .secondary
        case .connecting, .awaitingTVApproval:
            return .orange
        case .connected:
            return .green
        case .failed:
            return .red
        }
    }

    private var resultsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if results.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checklist")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No test results")
                        .font(.title2)
                    Text("Tap \"Connect to TV\" first, then run the tests.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results) { result in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.passed ? .green : .red)
                            .font(.title3)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.name)
                                .font(.headline)
                            Text(result.detail)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.2f s", result.duration))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Results")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if !results.isEmpty {
                    let passed = results.filter(\.passed).count
                    Text("\(passed)/\(results.count) passed")
                        .foregroundStyle(passed == results.count ? .green : .orange)
                }
            }
        }
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if logStore.entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No log entries")
                        .font(.title2)
                    Text("Authentication steps appear here after you tap Connect to TV.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(logStore.entries.enumerated()), id: \.offset) { index, entry in
                            Text(logStore.formattedLine(entry))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(color(for: entry.level))
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .onChange(of: logStore.entries.count) { count in
                        if count > 0 {
                            proxy.scrollTo(count - 1, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .navigationTitle("Log")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Text("\(logStore.entries.count) lines")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func color(for level: ADBLogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func connectToTV() async {
        guard let portValue = UInt16(port) else {
            connectionPhase = .failed("Invalid port")
            status = "Invalid port"
            return
        }

        await disconnectFromTV()
        selectedTab = 1
        connectionPhase = .connecting
        status = "Connecting to \(host):\(portValue)…"
        ADBLog.info("TV connection started: \(host):\(portValue)", category: "TestApp")

        #if os(iOS)
        await localNetwork.refresh()
        if localNetwork.status == .denied {
            connectionPhase = .failed("Local network permission denied")
            status = "Open Settings → Local Network → SwiftADB Test"
            ADBLog.error("Local network permission missing — cannot reach TV", category: "TestApp")
            return
        }
        #endif

        keyStore = FileKeyStore()
        keySource = keyStore.keySourceSummary()
        client = ADBClient(keyStore: keyStore)

        do {
            try await client.connect(host: host, port: portValue)

            let model = client.device?.model ?? client.device?.serial ?? host
            connectionPhase = .connected(model)
            status = "Connected to TV"
            ADBLog.info("TV connection succeeded: \(model)", category: "TestApp")
        } catch {
            let message = String(describing: error)
            if message.contains("awaitingTVApproval") || message.contains("TV screen") {
                connectionPhase = .failed("TV approval timed out — try again")
                status = "Approve on the TV and reconnect"
            } else {
                connectionPhase = .failed(message)
                status = "Connection error"
            }
            ADBLog.error("TV connection failed: \(message)", category: "TestApp")
            await client.disconnect()
        }
    }

    private func disconnectFromTV() async {
        await client.disconnect()
        connectionPhase = .idle
        if !isRunningTests {
            status = "Disconnected"
        }
    }

    private func runTests() async {
        guard let portValue = UInt16(port) else {
            status = "Invalid port"
            return
        }

        isRunningTests = true
        results = []

        if !connectionPhase.isConnected {
            await connectToTV()
            guard connectionPhase.isConnected else {
                isRunningTests = false
                return
            }
        }

        status = "Running tests…"
        ADBLog.info("Tests started", category: "TestApp")

        let output = await DeviceTestRunner.runAll(
            host: host,
            port: portValue,
            keyStore: keyStore,
            existingClient: client,
            onResult: { result in
                results.append(result)
            }
        )
        results = output
        selectedTab = 0

        let passed = output.filter(\.passed).count
        if passed == output.count {
            status = "All tests passed (\(passed)/\(output.count))"
        } else {
            status = "Some tests failed (\(passed)/\(output.count))"
        }
        isRunningTests = false
    }

    private func refreshKeyStore() {
        keyStore = FileKeyStore()
        keySource = keyStore.keySourceSummary()
    }
}
