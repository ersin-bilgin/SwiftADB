# SwiftADB

Pure Swift ADB (Android Debug Bridge) kütüphanesi. TCP, TLS, USB ve kablosuz ADB protokollerini destekler.

## Özellikler

- **Transport** — `NWConnection` TCP/TLS, ADB mesaj serileştirme
- **Authentication** — RSA-2048 anahtar, Android pubkey formatı, AUTH döngüsü
- **Client** — CNXN/STLS el sıkışması, servis yönetimi (OPEN/OKAY/WRTE/CLSE)
- **DeviceDiscovery** — Bonjour `_adb._tcp` keşfi
- **Pairing** — Kablosuz eşleştirme (sistem `adb pair` + native fallback)
- **Shell** — Shell v1/v2 (stdout, stderr, exit code)
- **FileSync** — push/pull, STAT
- **PortForward** — local ve reverse port yönlendirme
- **Logcat** — Log akışı ve parse
- **USB** — macOS `usbmuxd` desteği
- **SwiftADBiOSKit** — SwiftUI örnek arayüz

## Gereksinimler

- Swift 6.0+
- macOS 13+ / iOS 16+
- Kablosuz eşleştirme için Android SDK `platform-tools` (opsiyonel)

## Kurulum

```swift
dependencies: [
    .package(path: "../SwiftAdb")
]
```

```swift
import SwiftADB
```

## Hızlı Başlangıç

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

## Cihaz Test Uygulaması

Gerçek cihaza karşı smoke testleri (bağlantı, shell, filesync):

```bash
open Examples/SwiftADBTestApp/SwiftADBTestApp.xcodeproj
```

veya `swift run SwiftADBTestApp`

Varsayılan hedef: `192.168.1.8:5555` — ayrıntılar için `Examples/SwiftADBTestApp/README.md`.

## iOS Entegrasyonu

1. Xcode'da iOS App projesi oluşturun
2. SwiftADB paketini ekleyin
3. `SwiftADBiOSKit` import edin
4. `Info.plist` ekleyin:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>ADB cihazlarını keşfetmek için yerel ağ erişimi gerekir.</string>
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
        WindowGroup { ADBMainView() }
    }
}
```

## USB Bağlantı (macOS)

```swift
let usbDevices = try UsbMuxClient.shared.listDevices()
try await client.connectUSB(deviceID: usbDevices[0].id)
```

## Modüller

| Modül | Açıklama |
|-------|----------|
| `SwiftADB` | Umbrella (tüm modüller) |
| `SwiftADBTransport` | TCP, USB, mock transport |
| `SwiftADBAuthentication` | RSA kimlik doğrulama |
| `SwiftADBClient` | Ana istemci |
| `SwiftADBShell` | Shell servisi |
| `SwiftADBFileSync` | Dosya aktarımı |
| `SwiftADBPortForward` | Port yönlendirme |
| `SwiftADBLogcat` | Logcat |
| `SwiftADBiOSKit` | SwiftUI bileşenleri |

## Test

```bash
swift test
```

## Lisans

Apache 2.0
# SwiftADB
