import SwiftUI

@main
struct DeviceHarborCompanionApp: App {
    @State private var model = CompanionModel()

    var body: some Scene {
        WindowGroup {
            CompanionContentView()
                .environment(model)
        }
    }
}
