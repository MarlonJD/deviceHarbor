import SwiftUI

struct CompanionContentView: View {
    @Environment(CompanionModel.self) private var model

    var body: some View {
        NavigationStack {
            Form {
                Section("Remote relay (optional)") {
                    Text("The Mac creates a temporary relay Worker at runtime after launch. Pair once on the same network; the iPhone then receives the temporary endpoint and can reconnect from another Wi-Fi.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if model.canConnectViaRelay {
                        Label("Temporary relay session ready.", systemImage: "checkmark.shield")
                            .foregroundStyle(.green)
                    } else {
                        Label("No temporary relay session received yet.", systemImage: "network.slash")
                            .foregroundStyle(.secondary)
                    }
                    Button("Connect via temporary relay", systemImage: "arrow.up.right") {
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
