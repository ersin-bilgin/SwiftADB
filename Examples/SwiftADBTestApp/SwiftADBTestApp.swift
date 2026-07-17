import SwiftUI

@main
struct SwiftADBTestApp: App {
    var body: some Scene {
        WindowGroup {
            TestAppView()
                #if os(macOS)
                .frame(minWidth: 720, minHeight: 480)
                #endif
        }
    }
}
