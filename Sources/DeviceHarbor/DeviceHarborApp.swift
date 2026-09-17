import AppKit
import SwiftUI

@main
struct DeviceHarborApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("DeviceHarbor", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 920, minHeight: 620)
        }

        MenuBarExtra("DeviceHarbor", systemImage: "link") {
            MenuBarView()
                .environmentObject(model)
        }
    }
}
