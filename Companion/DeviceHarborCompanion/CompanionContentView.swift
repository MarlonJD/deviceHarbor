import SwiftUI

struct CompanionContentView: View {
    @Environment(CompanionModel.self) private var model

    var body: some View {
        NavigationStack {
            Form {
                Section("Remote relay (optional)") {
                    Text("If the Mac and iPhone are on different Wi-Fi networks, enter the same DeviceHarbor relay host and port on both sides.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextField("Relay host", text: Binding(
                        get: { model.relayHost },
                        set: { model.relayHost = $0 }
                    ))
                    TextField("Relay TCP port", text: Binding(
                        get: { model.relayPortText },
                        set: { model.relayPortText = String($0.filter { $0.isNumber }.prefix(5)) }
                    ))
                    Button("Connect via relay", systemImage: "arrow.up.right") {
                        model.connectViaRelay()
                    }
                    .disabled(!model.canConnectViaRelay)
                }

                Section("Mac companion") {
                    if model.discoveredMacs.isEmpty {
                        Label("Searching for DeviceHarbor Mac…", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.discoveredMacs) { mac in
                            Button {
                                model.select(mac)
                            } label: {
                                HStack {
                                    Image(systemName: mac.id == model.selectedMacID ? "checkmark.circle.fill" : "desktopcomputer")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(mac.name)
                                        Text(mac.endpointDescription)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Label(
                        model.companionStatus,
                        systemImage: model.companionConnectionReady ? "checkmark.circle.fill" : "link"
                    )
                    .foregroundStyle(model.companionConnectionReady ? .green : .secondary)

                    SecureField("Pairing code", text: model.pairingCodeBinding)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)

                    Button(
                        model.companionConnectionReady ? "Pair with Mac" : "Connect to Mac first",
                        systemImage: "link"
                    ) {
                        model.pair()
                    }
                    .disabled(!model.canPair)
                }

                Section("Private transport") {
                    Label(model.status, systemImage: model.statusSymbol)
                        .foregroundStyle(model.statusColor)

                    Button("Prepare Network Extension", systemImage: "shield.lefthalf.filled") {
                        model.prepareNetworkExtension()
                    }

                    Button("Start private transport", systemImage: "play.fill") {
                        model.startNetworkExtension()
                    }
                    .disabled(!model.networkExtensionPrepared)
                }

                Section("Reverse CoreDevice") {
                    Text("When paired, the Mac can request a CoreDevice stream. The companion opens that local service and returns bytes over the DeviceHarbor session.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("DeviceHarbor")
        }
        .task {
            model.startDiscovery()
        }
    }
}
