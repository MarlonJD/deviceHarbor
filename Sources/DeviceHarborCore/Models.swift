import Foundation

public enum DevicePlatform: String, Codable, CaseIterable, Sendable {
    case iOS
    case watchOS
    case unknown

    public var displayName: String {
        switch self {
        case .iOS: "iOS"
        case .watchOS: "watchOS"
        case .unknown: "Unknown"
        }
    }
}

public enum MeshProvider: String, Codable, CaseIterable, Sendable {
    case tailscale
    case zeroTier
    case netbird
    case manual

    public var displayName: String {
        switch self {
        case .tailscale: "Tailscale"
        case .zeroTier: "ZeroTier"
        case .netbird: "NetBird"
        case .manual: "Manual IP"
        }
    }
}

public struct CoreDevice: Codable, Hashable, Identifiable, Sendable {
    public let identifier: String
    public let udid: String
    public let name: String
    public let model: String
    public let deviceType: String
    public let platform: String
    public let operatingSystem: String
    public let reality: String
    public let pairingState: String
    public let connectionState: String
    public let tunnelState: String
    public let transportType: String
    public let developerModeStatus: String
    public let ddiServicesAvailable: Bool?
    public let potentialHostnames: [String]

    public var id: String { identifier }

    public init(
        identifier: String,
        udid: String = "",
        name: String,
        model: String,
        deviceType: String = "",
        platform: String,
        operatingSystem: String,
        reality: String,
        pairingState: String,
        connectionState: String = "",
        tunnelState: String,
        transportType: String,
        developerModeStatus: String = "",
        ddiServicesAvailable: Bool? = nil,
        potentialHostnames: [String] = []
    ) {
        self.identifier = identifier
        self.udid = udid
        self.name = name
        self.model = model
        self.deviceType = deviceType
        self.platform = platform
        self.operatingSystem = operatingSystem
        self.reality = reality
        self.pairingState = pairingState
        self.connectionState = connectionState
        self.tunnelState = tunnelState
        self.transportType = transportType
        self.developerModeStatus = developerModeStatus
        self.ddiServicesAvailable = ddiServicesAvailable
        self.potentialHostnames = potentialHostnames
    }

    public var isPhysical: Bool {
        reality.caseInsensitiveCompare("physical") == .orderedSame || reality.isEmpty
    }

    public var platformKind: DevicePlatform {
        let value = "\(platform) \(deviceType) \(model)".lowercased()
        if value.contains("watch") { return .watchOS }
        if value.contains("ios") || value.contains("iphone") || value.contains("ipad") {
            return .iOS
        }
        return .unknown
    }

    public var connectionSummary: String {
        let state = connectionState.isEmpty ? tunnelState : connectionState
        let tunnel = state.isEmpty ? "unknown state" : state
        let transport = transportType.isEmpty ? "unknown transport" : transportType
        return "\(tunnel) · \(transport)"
    }

    public var isPaired: Bool {
        pairingState.caseInsensitiveCompare("paired") == .orderedSame
    }

    public var isReachable: Bool {
        let values = [connectionState, tunnelState].map { $0.lowercased() }
        return values.contains(where: { $0 == "connected" || $0 == "available" || $0 == "ready" })
    }

    public var connectivityAdvice: String? {
        guard isPaired, !isReachable else { return nil }
        let state = connectionState.isEmpty ? tunnelState : connectionState
        guard state.caseInsensitiveCompare("unavailable") == .orderedSame else { return nil }
        return "Paired, but no CoreDevice tunnel is reachable. Connect the phone over USB or the configured private network."
    }
}

public struct DevicePairing: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let phoneIdentifier: String
    public let watchIdentifier: String
    public let active: Bool?
    public let phoneName: String
    public let watchName: String

    public init(
        id: String? = nil,
        phoneIdentifier: String,
        watchIdentifier: String,
        active: Bool? = nil,
        phoneName: String = "",
        watchName: String = ""
    ) {
        self.phoneIdentifier = phoneIdentifier
        self.watchIdentifier = watchIdentifier
        self.active = active
        self.phoneName = phoneName
        self.watchName = watchName
        self.id = id ?? "\(phoneIdentifier)::\(watchIdentifier)"
    }
}

public struct RelayService: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var instanceName: String
    public var serviceType: String
    public var domain: String
    public var remoteAddress: String
    public var remotePort: UInt16
    public var localPort: UInt16?
    public var textRecords: [String: String]

    public init(
        id: UUID = UUID(),
        instanceName: String,
        serviceType: String,
        domain: String = "local.",
        remoteAddress: String,
        remotePort: UInt16,
        localPort: UInt16? = nil,
        textRecords: [String: String] = [:]
    ) {
        self.id = id
        self.instanceName = instanceName
        self.serviceType = serviceType
        self.domain = domain
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.localPort = localPort
        self.textRecords = textRecords
    }

    public var isValid: Bool {
        !instanceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && serviceType.hasPrefix("_")
            && !remoteAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && remotePort > 0
    }
}

public struct DeviceProfile: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var displayName: String
    public var deviceIdentifier: String
    public var platform: DevicePlatform
    public var meshProvider: MeshProvider
    public var advertisedAddress: String
    public var services: [RelayService]

    public init(
        id: UUID = UUID(),
        displayName: String,
        deviceIdentifier: String,
        platform: DevicePlatform,
        meshProvider: MeshProvider,
        advertisedAddress: String = "127.0.0.1",
        services: [RelayService]
    ) {
        self.id = id
        self.displayName = displayName
        self.deviceIdentifier = deviceIdentifier
        self.platform = platform
        self.meshProvider = meshProvider
        self.advertisedAddress = advertisedAddress
        self.services = services
    }

    public var isValid: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !deviceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !advertisedAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !services.isEmpty
            && services.allSatisfy(\.isValid)
    }
}

public enum BridgeState: Equatable, Sendable {
    case stopped
    case starting
    case active(serviceCount: Int)
    case failed(String)

    public var title: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .active(let count): "Active (\(count) service\(count == 1 ? "" : "s"))"
        case .failed: "Failed"
        }
    }
}
