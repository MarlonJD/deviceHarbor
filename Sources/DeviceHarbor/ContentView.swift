import DeviceHarborCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Core Devices") {
                    if model.devices.isEmpty {
                        Label("No devices yet", systemImage: "iphone.slash")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.devices) { device in
                            DeviceRow(device: device)
                                .tag(SidebarSelection.device(device.id))
                        }
                    }
                }

                Section("Saved Bridges") {
                    if model.profiles.isEmpty {
                        Label("No bridge profiles", systemImage: "point.3.connected.trianglepath.dotted")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.profiles) { profile in
                            ProfileRow(profile: profile, state: model.bridgeState)
                                .tag(SidebarSelection.profile(profile.id))
                                .contextMenu {
                                    Button("Delete Profile", role: .destructive) {
                                        model.deleteProfile(profile)
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("DeviceHarbor")
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        model.refreshDevices()
                    } label: {
                        Label("Refresh Devices", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isRefreshing)

                    Button {
                        model.addProfile()
                    } label: {
                        Label("Add Bridge", systemImage: "plus")
                    }
                }
            }
        } detail: {
            switch model.selection {
            case .device(let id):
                if let device = model.devices.first(where: { $0.id == id }) {
                    DeviceDetailView(device: device)
                } else {
                    EmptyDetailView(title: "Device unavailable", systemImage: "iphone.slash")
                }
            case .profile(let id):
                if let profile = model.profiles.first(where: { $0.id == id }) {
                    ProfileDetailView(profile: profile)
                } else {
                    EmptyDetailView(title: "Profile unavailable", systemImage: "externaldrive.badge.questionmark")
                }
            case nil:
                WelcomeView()
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

private struct DeviceRow: View {
    let device: CoreDevice

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .lineLimit(1)
                Text("\(device.platformKind.displayName) · \(device.connectionSummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: device.platformKind == .watchOS ? "applewatch" : "iphone")
        }
    }
}

private struct ProfileRow: View {
    let profile: DeviceProfile
    let state: BridgeState

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName)
                    .lineLimit(1)
                Text("\(profile.platform.displayName) · \(profile.meshProvider.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: state == .stopped ? "network" : "network.badge.shield.half.filled")
        }
    }
}

struct DeviceDetailView: View {
    @EnvironmentObject private var model: AppModel
    let device: CoreDevice
    @State private var showingImporter = false
    @State private var bundleIdentifier = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DetailHeader(
                    title: device.name,
                    subtitle: "\(device.platformKind.displayName) · \(device.operatingSystem.isEmpty ? "OS unknown" : device.operatingSystem)",
                    systemImage: device.platformKind == .watchOS ? "applewatch" : "iphone"
                )

                GroupBox("CoreDevice") {
                    LabeledContent("Identifier", value: device.identifier)
                    LabeledContent("Model", value: device.model)
                    LabeledContent("Transport", value: device.transportType.isEmpty ? "Unknown" : device.transportType)
                    LabeledContent("Tunnel", value: device.tunnelState.isEmpty ? "Unknown" : device.tunnelState)
                    LabeledContent("Pairing", value: device.pairingState.isEmpty ? "Unknown" : device.pairingState)

                    if let advice = device.connectivityAdvice {
                        Label(advice, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }

                    HStack {
                        Button(device.isPaired ? "Refresh Status" : "Pair Device") {
                            model.prepare(device: device)
                        }
                        Spacer()
                    }
                    .padding(.top, 6)
                }

                if let profile = model.profiles.first(where: { $0.deviceIdentifier == device.identifier }) {
                    DeviceActionsView(
                        profile: profile,
                        bundleIdentifier: $bundleIdentifier,
                        showingImporter: $showingImporter
                    )
                } else {
                    ContentUnavailableView(
                        "No bridge profile",
                        systemImage: "network.slash",
                        description: Text("Create a saved bridge profile and point it at this device identifier.")
                    )
                }

                if device.platformKind == .iOS {
                    WatchPairingView(device: device)
                }

                StatusPanel()
            }
            .padding(28)
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first,
                  let profile = model.profiles.first(where: { $0.deviceIdentifier == device.identifier }) else { return }
            let didStart = url.startAccessingSecurityScopedResource()
            defer {
                if didStart { url.stopAccessingSecurityScopedResource() }
            }
            model.installApp(at: url, for: profile)
        }
    }
}

private struct WatchPairingView: View {
    @EnvironmentObject private var model: AppModel
    let device: CoreDevice

    var body: some View {
        GroupBox("watchOS 27 pairing") {
            VStack(alignment: .leading, spacing: 10) {
                Text("The Watch is reached through its paired iPhone and the Xcode 27 CoreDevice graph. A charging puck alone is not a USB data transport.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button(model.isLoadingWatchPairings ? "Reading…" : "Inspect Watch pairings") {
                    model.refreshWatchPairings(for: device)
                }
                .disabled(model.isLoadingWatchPairings)

                if model.watchPairings.isEmpty {
                    Text("No pairing record loaded yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.watchPairings) { pairing in
                        HStack {
                            Image(systemName: "applewatch")
                            VStack(alignment: .leading) {
                                Text(pairing.watchName.isEmpty ? pairing.watchIdentifier : pairing.watchName)
                                Text(pairing.active == true ? "Active pairing" : "Pairing record")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
    }
}

private struct DeviceActionsView: View {
    @EnvironmentObject private var model: AppModel
    let profile: DeviceProfile
    @Binding var bundleIdentifier: String
    @Binding var showingImporter: Bool

    var body: some View {
        GroupBox("Xcode device actions") {
            VStack(alignment: .leading, spacing: 12) {
                Text("These actions call Xcode 27's versioned devicectl JSON/CLI surface. They use the transport currently known to CoreDevice.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Install .app…") {
                        showingImporter = true
                    }
                    Text("signed device app bundle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    TextField("com.example.App", text: $bundleIdentifier)
                        .textFieldStyle(.roundedBorder)
                    Button("Launch") {
                        model.launch(bundleIdentifier: bundleIdentifier, for: profile)
                    }
                    .disabled(bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if !model.lastCommand.isEmpty {
                    Text(model.lastCommand)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

struct ProfileDetailView: View {
    @EnvironmentObject private var model: AppModel
    let profile: DeviceProfile
    @State private var draft: DeviceProfile
    @State private var isCapturing = false
    @State private var captureMessage = ""
    @State private var commonRemoteAddress = ""

    init(profile: DeviceProfile) {
        self.profile = profile
        _draft = State(initialValue: profile)
        _commonRemoteAddress = State(initialValue: profile.services.first?.remoteAddress ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("Display name", text: $draft.displayName)
                TextField("CoreDevice identifier or name", text: $draft.deviceIdentifier)
                if let device = model.devices.first(where: {
                    $0.isPhysical && ($0.platformKind == draft.platform || draft.deviceIdentifier.isEmpty)
                }) {
                    Button("Use connected \(device.name)", systemImage: "link") {
                        draft.deviceIdentifier = device.identifier
                        draft.platform = device.platformKind
                        if draft.displayName == "New Device" || draft.displayName.isEmpty {
                            draft.displayName = device.name
                        }
                    }
                    Text("CoreDevice: \(device.identifier)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Picker("Platform", selection: $draft.platform) {
                    ForEach(DevicePlatform.allCases, id: \.self) { platform in
                        Text(platform.displayName).tag(platform)
                    }
                }
                Picker("Mesh network", selection: $draft.meshProvider) {
                    ForEach(MeshProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                TextField("Local advertised address", text: $draft.advertisedAddress)
                    .help("The Mac address advertised to Xcode; 127.0.0.1 is useful for local tests.")
                TextField("iPhone/Watch private mesh address", text: $commonRemoteAddress)
                    .help("Use the iPhone's Tailscale, ZeroTier, NetBird, or Bluetooth-PAN address.")
                Button("Apply address to all services", systemImage: "arrow.down.right.and.arrow.up.left") {
                    applyCommonRemoteAddress()
                }
                Text("Remote mesh address belongs to the iPhone/Watch side. The local advertised address belongs to this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                DetailHeader(title: draft.displayName, subtitle: "Saved relay profile", systemImage: "network")
            }

            Section("Remote services") {
                ForEach($draft.services) { $service in
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Instance name", text: $service.instanceName)
                        TextField("Bonjour type", text: $service.serviceType)
                        TextField("Remote mesh address", text: $service.remoteAddress)
                        HStack {
                            TextField("Remote port", value: $service.remotePort, format: .number)
                            Text("TCP")
                                .foregroundStyle(.secondary)
                            if draft.services.count > 1 {
                                Button("Remove", role: .destructive) {
                                    draft.services.removeAll { $0.id == service.id }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Button("Add Bonjour service", systemImage: "plus") {
                    draft.services.append(
                        RelayService(
                            instanceName: "Device service",
                            serviceType: "_remoted._tcp",
                            remoteAddress: draft.services.first?.remoteAddress ?? "",
                            remotePort: 49153
                        )
                    )
                }

                Text("Known Xcode 27 device services include _remotepairing._tcp, _remoted._tcp, and _apple-mobdev2._tcp. Add one profile service per captured record.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button(isCapturing ? "Capturing…" : "Capture local records", systemImage: "dot.radiowaves.left.and.right") {
                        isCapturing = true
                        let remoteAddress = draft.services.first?.remoteAddress ?? ""
                        model.captureLocalBonjourServices { outcome in
                            isCapturing = false
                            switch outcome {
                            case .success(let services):
                                guard !services.isEmpty else {
                                    captureMessage = "No matching records found on this local network."
                                    return
                                }
                                draft.services = services.map { $0.makeRelayService(remoteAddress: remoteAddress) }
                                captureMessage = "Loaded \(services.count) record(s); enter the private address if needed, then save."
                            case .failure(let message):
                                captureMessage = message
                            }
                        }
                    }
                    .disabled(isCapturing)
                    if !captureMessage.isEmpty {
                        Text(captureMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                HStack {
                    Button("Save Profile") {
                        applyCommonRemoteAddress()
                        model.updateProfile(draft)
                    }
                    Button(model.bridgeState == .stopped ? "Start Bridge" : "Restart Bridge") {
                        applyCommonRemoteAddress()
                        model.updateProfile(draft)
                        model.startBridge(for: draft)
                    }
                    .disabled(!profileWithCommonAddress.isValid)
                    if model.bridgeState != .stopped {
                        Button("Stop") {
                            model.stopBridge()
                        }
                    }
                    Spacer()
                    Button("Delete", role: .destructive) {
                        model.deleteProfile(draft)
                    }
                }
                StatusPanel()
            }
        }
        .formStyle(.grouped)
        .padding(28)
        .onChange(of: profile) { _, newValue in
            draft = newValue
            commonRemoteAddress = newValue.services.first?.remoteAddress ?? ""
        }
    }

    private var profileWithCommonAddress: DeviceProfile {
        var value = draft
        for index in value.services.indices where value.services[index].remoteAddress.isEmpty {
            value.services[index].remoteAddress = commonRemoteAddress
        }
        return value
    }

    private func applyCommonRemoteAddress() {
        for index in draft.services.indices {
            draft.services[index].remoteAddress = commonRemoteAddress
        }
    }

}

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("DeviceHarbor", systemImage: "network")
        } description: {
            Text("Bridge Xcode 27 device services over a private network. Start by pairing a physical device in Xcode, then create a bridge profile.")
        } actions: {
            Button("Refresh CoreDevice") {
                model.refreshDevices()
            }
            Button("Create Bridge Profile") {
                model.addProfile()
            }
        }
    }
}

struct EmptyDetailView: View {
    let title: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage)
    }
}

struct DetailHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(width: 34, height: 34)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct StatusPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GroupBox("Status") {
            HStack(alignment: .firstTextBaseline) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(model.bridgeState.title)
                    .fontWeight(.medium)
                Text(model.statusMessage)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var statusColor: Color {
        switch model.bridgeState {
        case .stopped: .secondary
        case .starting: .orange
        case .active: .green
        case .failed: .red
        }
    }
}
