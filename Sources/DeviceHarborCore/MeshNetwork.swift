import Foundation

public struct MeshPeer: Codable, Hashable, Sendable {
    public let name: String
    public let dnsName: String
    public let addresses: [String]
    public let online: Bool

    public init(name: String, dnsName: String, addresses: [String], online: Bool) {
        self.name = name
        self.dnsName = dnsName
        self.addresses = addresses
        self.online = online
    }
}

public enum MeshNetworkError: LocalizedError, Sendable {
    case unsupportedProvider(MeshProvider)
    case commandFailed(String)
    case peerNotFound(String)
    case invalidStatusJSON(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedProvider(let provider):
            "Automatic address resolution is not implemented for \(provider.displayName); enter the private IP manually."
        case .commandFailed(let message):
            "Mesh provider command failed: \(message)"
        case .peerNotFound(let query):
            "No online mesh peer matched ‘\(query)’."
        case .invalidStatusJSON(let message):
            "Invalid mesh status JSON: \(message)"
        }
    }
}

public enum MeshResolutionOutcome: Sendable {
    case success(String)
    case failure(String)
}

public struct MeshEndpointResolver: @unchecked Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func resolve(provider: MeshProvider, matching query: String) throws -> String {
        switch provider {
        case .tailscale:
            let result = try runner.run(
                CommandSpec(executable: "/usr/bin/env", arguments: ["tailscale", "status", "--json"])
            )
            guard result.succeeded else {
                throw MeshNetworkError.commandFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let peers = try TailscaleStatusParser.parse(result.output)
            let normalizedQuery = query.lowercased()
            guard let peer = peers.first(where: {
                $0.online && [ $0.name, $0.dnsName ].contains(where: { $0.lowercased().contains(normalizedQuery) })
            }) else {
                throw MeshNetworkError.peerNotFound(query)
            }
            guard let address = peer.addresses.first(where: { $0.contains(".") || $0.contains(":") }) else {
                throw MeshNetworkError.peerNotFound(query)
            }
            return address
        case .zeroTier, .netbird, .manual:
            throw MeshNetworkError.unsupportedProvider(provider)
        }
    }
}

public enum TailscaleStatusParser {
    public static func parse(_ output: String) throws -> [MeshPeer] {
        let data = Data(output.utf8)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MeshNetworkError.invalidStatusJSON(error.localizedDescription)
        }
        guard let root = object as? [String: Any] else {
            throw MeshNetworkError.invalidStatusJSON("root is not an object")
        }

        var peers: [MeshPeer] = []
        if let selfPeer = parsePeer(root["Self"] as? [String: Any]) {
            peers.append(selfPeer)
        }
        if let rawPeers = root["Peer"] as? [String: Any] {
            for raw in rawPeers.values {
                if let peer = parsePeer(raw as? [String: Any]) { peers.append(peer) }
            }
        }
        return peers
    }

    private static func parsePeer(_ raw: [String: Any]?) -> MeshPeer? {
        guard let raw else { return nil }
        let name = raw["HostName"] as? String ?? raw["HostInfo"] as? String ?? ""
        let dnsName = raw["DNSName"] as? String ?? ""
        let addresses = raw["TailscaleIPs"] as? [String] ?? []
        let online = raw["Online"] as? Bool ?? true
        guard !name.isEmpty || !dnsName.isEmpty else { return nil }
        return MeshPeer(name: name, dnsName: dnsName, addresses: addresses, online: online)
    }
}
