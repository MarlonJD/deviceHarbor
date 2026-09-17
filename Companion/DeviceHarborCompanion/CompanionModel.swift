import Foundation
import Network
@preconcurrency import NetworkExtension
import Observation
import Security
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
    var status = "Starting discovery…"
    var companionStatus = "Searching for Mac companion…"
    var networkExtensionPrepared = false
    var companionConnectionReady = false
    var relayOffer: DeviceHarborRelayOffer?

    private var browser: NWBrowser?
    private let companionClient = DeviceHarborCompanionClient()
    private var tunnelManager: NETunnelProviderManager?
    private var relayReconnectTask: Task<Void, Never>?
    private var usingHostedRelay = false
    private var relayReconnectAttempts = 0

    init() {
        if let storedOffer = RelayOfferKeychain.load() {
            relayOffer = storedOffer
            pairingCode = storedOffer.pairingCode
        }
        configureCompanionClient()
    }

    var canPair: Bool {
        companionConnectionReady && pairingCode.count == 6
    }

    var canConnectViaRelay: Bool {
        guard let relayOffer else { return false }
        return !relayOffer.isExpired
    }

    var pairingCodeBinding: Binding<String> {
        Binding(
            get: { self.pairingCode },
            set: {
                self.pairingCode = String($0.filter { $0.isNumber }.prefix(6))
                if self.pairingCode.count == 6,
                   self.canConnectViaRelay,
                   !self.companionConnectionReady {
                    self.connectViaRelay()
                }
            }
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
                let shouldConnectToFirstMac = self.selectedMacID == nil
                self.discoveredMacs = discovered.sorted { $0.name < $1.name }
                if shouldConnectToFirstMac, let firstMac = self.discoveredMacs.first {
                    self.select(firstMac)
                } else if !self.discoveredMacs.isEmpty && self.selectedMacID != nil && !self.companionConnectionReady {
                    self.companionStatus = "Mac companion found. Tap the Mac row to connect."
                }
            }
        }
        browser.start(queue: DispatchQueue.main)
        self.browser = browser
        scheduleHostedRelayReconnect()
    }

    func select(_ mac: DiscoveredMac) {
        relayReconnectTask?.cancel()
        relayReconnectTask = nil
        usingHostedRelay = false
        selectedMacID = mac.id
        companionConnectionReady = false
        companionStatus = "Connecting to \(mac.name)…"
        companionClient.connect(to: mac.endpoint)
    }

    private func configureCompanionClient() {
        companionClient.onStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .stopped:
                    self.companionConnectionReady = false
                    self.companionStatus = "Connection closed."
                case .failed(let message):
                    self.companionConnectionReady = false
                    self.companionStatus = "Connection failed: \(message)"
                    self.usingHostedRelay = false
                    self.scheduleHostedRelayReconnect()
                case .connecting:
                    self.companionConnectionReady = false
                    self.companionStatus = "Connecting to Mac companion…"
                case .waitingForPair:
                    self.companionConnectionReady = true
                    self.companionStatus = "Connected to Mac companion. Enter the pairing code."
                case .paired(_, let transport):
                    self.companionConnectionReady = true
                    self.usingHostedRelay = transport == .relay
                    self.relayReconnectAttempts = 0
                    self.companionStatus = transport == .relay
                        ? "Paired with Mac companion through the DeviceHarbor network."
                        : "Paired with Mac companion."
                }
            }
        }
        companionClient.onMacHello = { [weak self] _, name in
            Task { @MainActor in
                guard let self else { return }
                self.companionConnectionReady = true
                if self.usingHostedRelay && self.pairingCode.count == 6 {
                    self.companionClient.pair(using: self.pairingCode)
                    self.status = "Pairing with Mac companion through the DeviceHarbor network…"
                    self.companionStatus = "Mac companion found through the DeviceHarbor network. Pairing…"
                } else {
                    self.companionStatus = "Connected to \(name). Enter the pairing code."
                }
            }
        }
        companionClient.onRelayOffer = { [weak self] offer in
            Task { @MainActor in
                guard let self else { return }
                self.relayOffer = offer
                self.pairingCode = offer.pairingCode
                RelayOfferKeychain.save(offer)
                self.status = "Relay session received from the Mac companion."
                self.scheduleHostedRelayReconnect()
            }
        }
    }

    func pair() {
        companionClient.pair(using: pairingCode)
        status = "Pairing with Mac companion…"
    }

    func connectViaRelay() {
        guard let relayOffer, !relayOffer.isExpired, let endpoint = relayOffer.webSocketURL else {
            status = "Pair with the Mac companion once on the same network to receive a temporary relay session."
            return
        }
        relayReconnectTask?.cancel()
        relayReconnectTask = nil
        usingHostedRelay = true
        companionConnectionReady = false
        companionStatus = "Connecting to the DeviceHarbor network…"
        status = "Connecting to the DeviceHarbor network…"
        self.companionClient.connect(
            to: NWEndpoint.url(endpoint),
            parameters: DeviceHarborChannel.webSocketParameters(),
            transport: .webSocket,
            rendezvousID: relayOffer.session.roomID,
            accessToken: relayOffer.session.accessToken
        )
    }

    private func scheduleHostedRelayReconnect() {
        guard canConnectViaRelay,
              !companionConnectionReady,
              !usingHostedRelay,
              relayReconnectTask == nil,
              relayReconnectAttempts < 3 else {
            return
        }
        relayReconnectAttempts += 1
        relayReconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.relayReconnectTask = nil
            guard !self.companionConnectionReady else { return }
            self.connectViaRelay()
        }
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

private enum RelayOfferKeychain {
    private static let service = "dev.deviceharbor.companion"
    private static let account = "temporary-relay-offer"

    static func load() -> DeviceHarborRelayOffer? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(DeviceHarborRelayOffer.self, from: data)
    }

    static func save(_ offer: DeviceHarborRelayOffer) {
        guard let data = try? JSONEncoder().encode(offer) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item.merge(attributes) { _, newValue in newValue }
            _ = SecItemAdd(item as CFDictionary, nil)
        }
    }
}

private final class TunnelProviderManagerBox: @unchecked Sendable {
    let value: NETunnelProviderManager

    init(_ value: NETunnelProviderManager) {
        self.value = value
    }
}
