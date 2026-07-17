# SwiftADB

A pure Swift implementation of ADB (Android Debug Bridge). Supports TCP, TLS, USB, and Wireless ADB protocols.

## Features

- **Transport** — `NWConnection`-based TCP/TLS transport and ADB message serialization
- **Authentication** — RSA-2048 key generation, Android public key format, AUTH handshake
- **Client** — CNXN/STLS handshake, service management (OPEN/OKAY/WRTE/CLSE)
- **Device Discovery** — Bonjour `_adb._tcp` service discovery
- **Pairing** — Wireless pairing (`adb pair` integration with native fallback)
- **Shell** — Shell v1/v2 support (stdout, stderr, exit code)
- **FileSync** — File push/pull and STAT operations
- **Port Forwarding** — Local and reverse port forwarding
- **Logcat** — Real-time log streaming and parsing
- **USB** — macOS `usbmuxd` support
- **SwiftADBiOSKit** — Sample SwiftUI interface

## Requirements

- Swift 6.0+
- macOS 13+ / iOS 16+
- Android SDK Platform Tools (optional, required only for wireless pairing)

## Installation

```swift
dependencies: [
    .package(path: "../SwiftADB")
]
```

```swift
import SwiftADB
```

## Quick Start

```swift
let client = ADBClient()
ADBLog.logger = ConsoleADBLogger(minimumLevel: .info)

try await client.connect(host: "192.168.1.42", port: 5555)

let shell = DefaultShellService(client: client)
let output = try await shell.execute("getprop ro.product.model")
print(output.stdout, output.exitCode)

await client.disconnect()
```

## CLI Demo

```bash
swift run SwiftADBDemo discover
swift run SwiftADBDemo connect 192.168.1.42 5555
swift run SwiftADBDemo shell 192.168.1.42 5555 "getprop ro.product.model"
swift run SwiftADBDemo push 192.168.1.42 ./local.txt /sdcard/local.txt
swift run SwiftADBDemo logcat 192.168.1.42 5555
```

## macOS GUI

```bash
swift run SwiftADBMacApp
```

## Device Test Application

Smoke tests against a real Android device (connection, shell, FileSync):

```bash
open Examples/SwiftADBTestApp/SwiftADBTestApp.xcodeproj
```

or

```bash
swift run SwiftADBTestApp
```

Default target device: `192.168.1.8:5555`.

See `Examples/SwiftADBTestApp/README.md` for configuration details.

## iOS Integration

1. Create an iOS app project in Xcode.
2. Add the SwiftADB package.
3. Import `SwiftADBiOSKit`.
4. Add the following entries to your `Info.plist`:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Local network access is required to discover ADB devices.</string>

<key>NSBonjourServices</key>
<array>
    <string>_adb._tcp</string>
    <string>_adb-tls-pairing._tcp</string>
</array>
```

```swift
import SwiftADBiOSKit

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ADBMainView()
        }
    }
}
```

## USB Connection (macOS)

```swift
let usbDevices = try UsbMuxClient.shared.listDevices()
try await client.connectUSB(deviceID: usbDevices[0].id)
```

## Modules

| Module | Description |
|---------|-------------|
| `SwiftADB` | Umbrella package (includes all modules) |
| `SwiftADBTransport` | TCP, USB, and mock transport |
| `SwiftADBAuthentication` | RSA authentication |
| `SwiftADBClient` | Core ADB client |
| `SwiftADBShell` | Shell service |
| `SwiftADBFileSync` | File transfer |
| `SwiftADBPortForward` | Port forwarding |
| `SwiftADBLogcat` | Logcat streaming |
| `SwiftADBiOSKit` | SwiftUI components |

## Testing

```bash
swift test
```

## License

Apache License 2.0
