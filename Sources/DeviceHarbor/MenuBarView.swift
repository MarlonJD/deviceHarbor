import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.bridgeState.title)
            .foregroundStyle(.secondary)
        Divider()
        Button("Open DeviceHarbor") {
            openWindow(id: "main")
        }
        Button("Refresh Devices") {
            model.refreshDevices()
        }
        if model.bridgeState != .stopped {
            Button("Stop Bridge") {
                model.stopBridge()
            }
        }
        Divider()
        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }
}
