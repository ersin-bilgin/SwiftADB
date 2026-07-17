# SwiftADB iOS Örnek Uygulaması

## Kurulum

1. Xcode'da yeni **iOS App** projesi oluşturun
2. **File → Add Package Dependencies** ile SwiftADB paketini ekleyin
3. Target'a `SwiftADBiOSKit` ürününü bağlayın
4. `Info.plist` dosyanıza `Examples/SwiftADBiOS/Info.plist` içeriğini ekleyin

## App.swift

```swift
import SwiftADBiOSKit
import SwiftUI

@main
struct MyADBApp: App {
    var body: some Scene {
        WindowGroup {
            ADBMainView()
        }
    }
}
```

## Özellikler

- Bonjour ile kablosuz cihaz keşfi
- TCP bağlantı ve shell komutları
- Logcat akışı (Shell sekmesinden sonra genişletilebilir)

## Not

iOS simülatörde gerçek ADB cihazına bağlanmak için Mac'inizin ağıyla aynı Wi-Fi'da olun.
