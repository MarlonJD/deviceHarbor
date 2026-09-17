import Foundation
import Network
@preconcurrency import NetworkExtension

private enum PacketTunnelError: LocalizedError, Sendable {
    case missingRelayOffer
    case invalidRelayOffer
    case relayFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingRelayOffer:
            return "DeviceHarbor has no relay offer configured for the Network Extension."
        case .invalidRelayOffer:
            return "DeviceHarbor received an invalid or expired relay offer."
        case .relayFailed(let message):
            return "DeviceHarbor relay failed: \(message)"
        }
    }
}

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private var isRunning = false
    private var companionClient: DeviceHarborCompanionClient?
    private var startupTimeout: DispatchWorkItem?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let providerConfiguration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
              let relayData = providerConfiguration["relayOffer"] as? Data else {
            completionHandler(PacketTunnelError.missingRelayOffer)
            return
        }
        guard let offer = try? JSONDecoder().decode(DeviceHarborRelayOffer.self, from: relayData),
              !offer.isExpired,
              let endpoint = offer.webSocketURL else {
            completionHandler(PacketTunnelError.invalidRelayOffer)
            return
        }

        let completion = CompletionGate(completionHandler)
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "deviceharbor")
        let ipv4 = NEIPv4Settings(
            addresses: ["198.18.0.2"],
            subnetMasks: ["255.255.255.0"]
        )
        ipv4.includedRoutes = [
            NEIPv4Route(destinationAddress: "198.18.0.0", subnetMask: "255.255.0.0")
        ]
        settings.ipv4Settings = ipv4
        settings.mtu = 1_280

        setTunnelNetworkSettings(settings) { [weak self, completion] error in
            guard let self else {
                completion.finish(error)
                return
            }
            if let error {
                completion.finish(error)
                return
            }

            let client = DeviceHarborCompanionClient()
            client.onMacHello = { [weak self] _, _ in
                self?.companionClient?.pair(using: offer.pairingCode)
            }
            client.onStateChange = { [weak self, completion] state in
                guard let self else { return }
                switch state {
                case .paired:
                    self.isRunning = true
                    self.startupTimeout?.cancel()
                    self.startupTimeout = nil
                    completion.finish(nil)
                case .failed(let message):
                    self.isRunning = false
                    self.startupTimeout?.cancel()
                    self.startupTimeout = nil
                    self.companionClient?.disconnect()
                    completion.finish(PacketTunnelError.relayFailed(message))
                case .stopped:
                    if !self.isRunning {
                        completion.finish(PacketTunnelError.relayFailed("The companion session stopped before pairing."))
                    }
                case .connecting, .waitingForPair:
                    break
                }
            }
            self.companionClient = client
            let timeout = DispatchWorkItem { [weak self, completion] in
                guard let self else { return }
                self.isRunning = false
                self.companionClient?.disconnect()
                self.companionClient = nil
                completion.finish(PacketTunnelError.relayFailed("Timed out waiting for the Mac relay peer."))
            }
            self.startupTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
            client.connect(
                to: NWEndpoint.url(endpoint),
                parameters: DeviceHarborChannel.webSocketParameters(),
                transport: .webSocket,
                rendezvousID: offer.session.roomID,
                accessToken: offer.session.accessToken
            )
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        isRunning = false
        startupTimeout?.cancel()
        startupTimeout = nil
        companionClient?.disconnect()
        companionClient = nil
        completionHandler()
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)? = nil
    ) {
        completionHandler?(nil)
    }
}

private final class CompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: (Error?) -> Void
    private var didFinish = false

    init(_ handler: @escaping (Error?) -> Void) {
        self.handler = handler
    }

    func finish(_ error: Error?) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        lock.unlock()
        handler(error)
    }
}
