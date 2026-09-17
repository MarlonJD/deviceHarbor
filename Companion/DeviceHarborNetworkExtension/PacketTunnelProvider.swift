@preconcurrency import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private var isRunning = false

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let completion = ErrorCompletion(completionHandler)
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
                completion.call(error)
                return
            }
            if let error {
                completion.call(error)
                return
            }
            self.isRunning = true
            self.readPackets()
            completion.call(nil)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        isRunning = false
        completionHandler()
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)? = nil
    ) {
        completionHandler?(messageData)
    }

    private func readPackets() {
        guard isRunning else { return }
        packetFlow.readPackets { [weak self] _, _ in
            self?.readPackets()
        }
    }
}

private final class ErrorCompletion: @unchecked Sendable {
    private let handler: (Error?) -> Void

    init(_ handler: @escaping (Error?) -> Void) {
        self.handler = handler
    }

    func call(_ error: Error?) {
        handler(error)
    }
}
