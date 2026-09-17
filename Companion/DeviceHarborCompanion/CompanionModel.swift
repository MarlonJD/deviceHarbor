import Foundation
import Network
@preconcurrency import NetworkExtension
import Observation
import SwiftUI

@MainActor
@Observable
final class CompanionModel {
    struct DiscoveredMac: Identifiable, @unchecked Sendable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
        let endpointDescription: String
    }

    var discoveredMacs: [DiscoveredMac] = []
    var selectedMacID: String?
    var pairingCode = ""
    var relayHost = ""
    var relayPortText = "49153"
    var status = "Starting discovery…"
    var networkExtensionPrepared = false
    var companionConnectionReady = false

    private var browser: NWBrowser?
    private let companionClient = DeviceHarborCompanionClient()
    private var tunnelManager: NETunnelProviderManager?

    var canPair: Bool {
        companionConnectionReady && pairingCode.count == 6
    }

    var canConnectViaRelay: Bool {
        !relayHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && UInt16(relayPortText) != nil
            && pairingCode.count == 6
    }

    var pairingCodeBinding: Binding<String> {
        Binding(
            get: { self.pairingCode },
            set: { self.pairingCode = String($0.filter { $0.isNumber }.prefix(6)) }
        )
    }

    var statusSymbol: String {
        if networkExtensionPrepared { return "checkmark.shield" }
        if companionConnectionReady { return "link" }
        return "magnifyingglass"
    }

    var statusColor: Color {
        if status.localizedCaseInsensitiveContains("failed") || status.localizedCaseInsensitiveContains("error") {
            return .red
        }
        if networkExtensionPrepared { return .green }
        return .secondary
    }

    func startDiscovery() {
        guard browser == nil else { return }
        let browser = NWBrowser(
            for: .bonjour(type: "_deviceharbor._tcp", domain: "local."),
            using: .tcp
        )
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                if case .failed(let error) = state {
                    self.status = "Discovery failed: \(error.localizedDescription)"
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let discovered = results.compactMap { result -> DiscoveredMac? in
                guard case let .service(name, type, domain, _) = result.endpoint else { return nil }
                return DiscoveredMac(
                    id: "\(name).\(type).\(domain)",
                    name: name,
                    endpoint: result.endpoint,
                    endpointDescription: "\(type)\(domain)"
                )
            }
            Task { @MainActor in
                guard let self else { return }
                self.discoveredMacs = discovered.sorted { $0.name < $1.name }
                if self.selectedMacID == nil {
                    self.selectedMacID = self.discoveredMacs.first?.id
                }
                if !self.discoveredMacs.isEmpty && self.selectedMacID != nil {
                    self.status = "Mac companion found. Enter the pairing code."
                }
            }
        }
        browser.start(queue: DispatchQueue.main)
        self.browser = browser
    }

    func select(_ mac: DiscoveredMac) {
        selectedMacID = mac.id
        companionClient.onStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .stopped:
                    self.companionConnectionReady = false
                    self.status = "Connection closed."
                case .failed(let message):
                    self.companionConnectionReady = false
                    self.status = "Connection failed: \(message)"
                case .connecting:
                    self.companionConnectionReady = false
                    self.status = "Connecting to Mac companion…"
                case .waitingForPair:
                    self.companionConnectionReady = true
                    self.status = "Connected to Mac companion. Enter the pairing code."
                case .paired:
                    self.companionConnectionReady = true
                    self.status = "Paired with Mac companion."
                }
            }
        }
        companionClient.onMacHello = { [weak self] _, name in
            Task { @MainActor in
                self?.companionConnectionReady = true
                self?.status = "Connected to \(name). Enter the pairing code."
            }
        }
        companionClient.connect(to: mac.endpoint)
    }

    func pair() {
        companionClient.pair(using: pairingCode)
        status = "Pairing with Mac companion…"
    }

    func connectViaRelay() {
        let host = relayHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let portValue = UInt16(relayPortText), let port = NWEndpoint.Port(rawValue: portValue) else {
            status = "Enter a valid DeviceHarbor relay host and TCP port."
            return
        }
        guard pairingCode.count == 6 else {
            status = "Enter the six-digit Mac pairing code before connecting to the relay."
            return
        }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: port
        )
        companionClient.connect(
            to: endpoint,
            rendezvousID: pairingCode,
            accessToken: pairingCode
        )
        companionConnectionReady = false
        status = "Connecting to DeviceHarbor relay \(host):\(portValue)…"
    }

    func prepareNetworkExtension() {
        status = "Preparing Network Extension…"
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            if let error {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.status = "Network Extension error: \(error.localizedDescription)"
                }
                return
            }

            let manager = TunnelProviderManagerBox(managers?.first ?? NETunnelProviderManager())
            Task { @MainActor [weak self, manager] in
                guard let self else { return }
                let configuration = NETunnelProviderProtocol()
                configuration.providerBundleIdentifier = "dev.deviceharbor.companion.network-extension"
                configuration.serverAddress = "DeviceHarbor"
                configuration.providerConfiguration = ["transport": "reverse-session"]
                manager.value.protocolConfiguration = configuration
                manager.value.localizedDescription = "DeviceHarbor Private Transport"
                manager.value.isEnabled = true
                manager.value.saveToPreferences { [weak self, manager] error in
                    Task { @MainActor [weak self, manager] in
                        guard let self else { return }
                        if let error {
                            self.status = "Network Extension save failed: \(error.localizedDescription)"
                        } else {
                            self.tunnelManager = manager.value
                            self.networkExtensionPrepared = true
                            self.status = "Network Extension prepared; start it and approve the VPN prompt."
                        }
                    }
                }
            }
        }
    }

    func startNetworkExtension() {
        guard let manager = tunnelManager else {
            status = "Prepare the Network Extension first."
            return
        }
        guard let session = manager.connection as? NETunnelProviderSession else {
            status = "Network Extension session is unavailable."
            return
        }
        do {
            try session.startVPNTunnel()
            status = "Private transport starting; approve the system prompt if shown."
        } catch {
            status = "Network Extension start failed: \(error.localizedDescription)"
        }
    }

}

private final class TunnelProviderManagerBox: @unchecked Sendable {
    let value: NETunnelProviderManager

    init(_ value: NETunnelProviderManager) {
        self.value = value
    }
}
