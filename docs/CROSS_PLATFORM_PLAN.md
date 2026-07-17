# SwiftADB — Çoklu Platform Planı

Hedef: **iPhone, iPad, Mac** (ve ileride Apple TV / visionOS) üzerinde tek kod tabanı.

## Mimari

```
┌─────────────────────────────────────────────────────────┐
│  SwiftADBApp (SwiftUI) — iOS / iPadOS / macOS           │
│  TestAppView · DeviceTestRunner · ADBMainView (kit)     │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│  SwiftADBiOSKit — paylaşılan UI + ViewModel             │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│  SwiftADB — Client, Shell, FileSync, Logcat, Pairing      │
└───────────────────────────────────────────────────────────┘
```

## Platform Matrisi

| Özellik | iPhone / iPad | Mac |
|---------|---------------|-----|
| TCP ADB (`host:5555`) | ✅ | ✅ |
| Bonjour keşif | ✅ (Info.plist) | ✅ |
| RSA kimlik doğrulama | ✅ (App Support anahtar) | ✅ (`~/.android/adbkey`) |
| Kablosuz eşleştirme (native) | ✅ | ✅ |
| Sistem `adb pair` | ❌ | ✅ |
| USB (`usbmuxd`) | ❌ | ✅ |
| Shell / FileSync / Logcat | ✅ | ✅ |
| Port forward (localhost) | ⚠️ kısıtlı (iOS sandbox) | ✅ |

## Fazlar

### Faz 1 — Derlenebilir çoklu platform (şimdi)
- [x] `Process` / `adb` CLI yalnızca macOS
- [x] `FileKeyStore` iOS dizini (Application Support)
- [x] `project.yml` → iOS + macOS hedefleri
- [x] Adaptif SwiftUI (iPhone compact / iPad-Mac split)
- [x] iOS `Info.plist` (yerel ağ + Bonjour)

### Faz 2 — iOS anahtar & pairing
- [ ] iOS PEM içe aktarma (`SecKeyCreateWithData` PKCS#8)
- [ ] Keychain tabanlı `SecIdentity` (TLS pairing)
- [ ] `ADBPublicKey.encodeBinary` performans (BigInteger → hızlı modPow)
- [ ] Anahtarları Keychain’e taşıma (isteğe bağlı iCloud Keychain senk)

### Faz 3 — UI birleştirme
- [ ] `SwiftADBTestApp` + `SwiftADBMacApp` → tek **SwiftADBApp**
- [ ] Sekmeler: Keşfet · Bağlan · Shell · Test · Logcat
- [ ] iPad: `NavigationSplitView` üç sütun
- [ ] iPhone: `TabView` + `NavigationStack`

### Faz 4 — iOS özel UX
- [ ] Dosya push/pull: `UIDocumentPicker` / `fileImporter`
- [ ] QR veya manuel IP girişi
- [ ] Arka planda bağlantı uyarıları
- [ ] App Store: yerel ağ izni açıklaması (TR/EN)

### Faz 5 — Genişletme
- [ ] tvOS: yalnızca uzaktan bağlantı (hedef cihaz olarak değil, kontrolcü olarak)
- [ ] visionOS: spatial panel (düşük öncelik)
- [ ] Mac Catalyst (gerekirse; native macOS tercih)

## Xcode Projesi

```
Examples/SwiftADBTestApp/
  SwiftADBTestApp.xcodeproj   ← xcodegen
  project.yml
  Info-iOS.plist
  *.swift
```

**Scheme’ler:** `SwiftADBTestApp (iOS)` · `SwiftADBTestApp (macOS)`

```bash
cd Examples/SwiftADBTestApp && xcodegen generate
open SwiftADBTestApp.xcodeproj
```

## Test Stratejisi

| Katman | macOS | iOS Simulator | Gerçek cihaz |
|--------|-------|---------------|--------------|
| Unit (mock) | `swift test` | CI | — |
| Smoke (TestApp) | ✅ | Ağ yok* | ✅ Wi‑Fi ADB |
| USB | ✅ | — | — |

\* Simülatör yerel ağ / Bonjour kısıtlı; gerçek iPhone/iPad testi önerilir.

## Bilinen Kısıtlar

1. **iOS USB ADB** — Apple API yok; yalnızca kablosuz ADB.
2. **Port forward** — iOS uygulama sandbox’ı localhost dinlemeyi kısıtlar.
3. **Sistem adb** — macOS’a özel; iOS’ta native pairing kullanılır.
4. **RSA onay** — Her platformda cihaz ekranında izin gerekir.
