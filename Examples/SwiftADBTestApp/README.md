# SwiftADBTestApp

Gerçek ADB cihazlarına karşı uçtan uca smoke testleri çalıştıran macOS uygulaması.

## Testler

1. **Bağlantı** — TCP, kimlik doğrulama, CNXN el sıkışması
2. **Shell — model** — `getprop ro.product.model`
3. **Shell — echo** — `echo swiftadb-test`
4. **FileSync — stat** — `/sdcard` dosya bilgisi
5. **Banner** — cihaz banner metni

## Çalıştırma

### Xcode (önerilen)

```bash
open Examples/SwiftADBTestApp/SwiftADBTestApp.xcodeproj
```

| Scheme | Platform |
|--------|----------|
| **SwiftADBTestApp (iOS)** | iPhone / iPad |
| **SwiftADBTestApp (macOS)** | Mac |

Çoklu platform planı: `docs/CROSS_PLATFORM_PLAN.md`

## Varsayılan cihaz

- Host: `192.168.1.8`
- Port: `5555`

Android TV / cihazda RSA anahtar onayı gerekebilir. Diyalog görünmezse kablosuz hata ayıklamayı yeniden etkinleştirin.

## Gereksinimler

- macOS 13+
- Aynı ağda ADB over TCP etkin cihaz (`adb tcpip 5555` veya TV kablosuz hata ayıklama)
