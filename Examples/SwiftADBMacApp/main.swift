import SwiftADBiOSKit
import SwiftUI

@main
struct SwiftADBMacApp: App {
    var body: some Scene {
        WindowGroup {
            ADBMainView()
                .frame(minWidth: 480, minHeight: 360)
        }
    }
}
