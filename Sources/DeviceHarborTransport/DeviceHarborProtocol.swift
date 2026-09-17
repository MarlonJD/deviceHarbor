import Foundation

public enum DeviceHarborFrameKind: String, Codable, Sendable {
    case hello
    case pairRequest
    case pairAccepted
    case pairRejected
    case heartbeat
    case openStream
    case streamReady
    case streamData
    case closeStream
    case error
    case relayJoin
    case relayReady
    case relayOffer
}

public struct DeviceHarborFrame: Codable, Equatable, Sendable {
    public let kind: DeviceHarborFrameKind
    public let protocolVersion: Int
    public let peerID: String?
    public let displayName: String?
    public let pairingCode: String?
    public let streamID: String?
    public let port: UInt16?
    public let payload: Data?
    public let message: String?
    public let rendezvousID: String?
    public let accessToken: String?
    public let relayEndpoint: String?
    public let relayRoomID: String?
    public let relayAccessToken: String?
    public let relayExpiresAt: Int64?

    public init(
        kind: DeviceHarborFrameKind,
        protocolVersion: Int = 1,
        peerID: String? = nil,
        displayName: String? = nil,
        pairingCode: String? = nil,
        streamID: String? = nil,
        port: UInt16? = nil,
        payload: Data? = nil,
        message: String? = nil,
        rendezvousID: String? = nil,
        accessToken: String? = nil,
        relayEndpoint: String? = nil,
        relayRoomID: String? = nil,
        relayAccessToken: String? = nil,
        relayExpiresAt: Int64? = nil
    ) {
        self.kind = kind
        self.protocolVersion = protocolVersion
        self.peerID = peerID
        self.displayName = displayName
        self.pairingCode = pairingCode
        self.streamID = streamID
        self.port = port
        self.payload = payload
        self.message = message
        self.rendezvousID = rendezvousID
        self.accessToken = accessToken
        self.relayEndpoint = relayEndpoint
        self.relayRoomID = relayRoomID
        self.relayAccessToken = relayAccessToken
        self.relayExpiresAt = relayExpiresAt
    }

    public static func hello(peerID: String, displayName: String) -> Self {
        Self(kind: .hello, peerID: peerID, displayName: displayName)
    }

    public static func pairRequest(peerID: String, pairingCode: String) -> Self {
        Self(kind: .pairRequest, peerID: peerID, pairingCode: pairingCode)
    }

    public static func pairAccepted(peerID: String) -> Self {
        Self(kind: .pairAccepted, peerID: peerID)
    }

    public static func pairRejected(message: String) -> Self {
        Self(kind: .pairRejected, message: message)
    }

    public static func openStream(streamID: String, port: UInt16) -> Self {
        Self(kind: .openStream, streamID: streamID, port: port)
    }

    public static func streamReady(streamID: String) -> Self {
        Self(kind: .streamReady, streamID: streamID)
    }

    public static func streamData(streamID: String, payload: Data) -> Self {
        Self(kind: .streamData, streamID: streamID, payload: payload)
    }

    public static func closeStream(streamID: String, message: String? = nil) -> Self {
        Self(kind: .closeStream, streamID: streamID, message: message)
    }

    public static func heartbeat(message: String) -> Self {
        Self(kind: .heartbeat, message: message)
    }

    public static func error(message: String) -> Self {
        Self(kind: .error, message: message)
    }

    public static func relayJoin(rendezvousID: String, accessToken: String) -> Self {
        Self(kind: .relayJoin, rendezvousID: rendezvousID, accessToken: accessToken)
    }

    public static func relayReady(rendezvousID: String) -> Self {
        Self(kind: .relayReady, rendezvousID: rendezvousID)
    }

    public static func relayOffer(_ offer: DeviceHarborRelayOffer) -> Self {
        Self(
            kind: .relayOffer,
            pairingCode: offer.pairingCode,
            relayEndpoint: offer.baseURLString,
            relayRoomID: offer.session.roomID,
            relayAccessToken: offer.session.accessToken,
            relayExpiresAt: offer.session.expiresAt
        )
    }
}

public enum DeviceHarborWireCodec {
    public static func encode(_ frame: DeviceHarborFrame) throws -> Data {
        var data = try JSONEncoder().encode(frame)
        data.append(0x0A)
        return data
    }

    public static func decodeLines(from buffer: inout Data) throws -> [DeviceHarborFrame] {
        var frames: [DeviceHarborFrame] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            frames.append(try JSONDecoder().decode(DeviceHarborFrame.self, from: line))
        }
        return frames
    }
}

public enum DeviceHarborPairing {
    public static func generateCode() -> String {
        let number = Int.random(in: 100_000...999_999)
        return String(number)
    }
}

public enum DeviceHarborRelayServerError: LocalizedError, Sendable {
    case invalidPort
    case listenerFailed(String)
    case invalidEndpoint

    public var errorDescription: String? {
        switch self {
        case .invalidPort:
            "The DeviceHarbor relay port is invalid."
        case .listenerFailed(let message):
            "The DeviceHarbor relay could not start: \(message)"
        case .invalidEndpoint:
            "The DeviceHarbor hosted relay endpoint is invalid or not configured."
        }
    }
}

public struct DeviceHarborHostedRelaySession: Codable, Equatable, Sendable {
    public let roomID: String
    public let accessToken: String
    public let expiresAt: Int64

    public init(roomID: String, accessToken: String, expiresAt: Int64) {
        self.roomID = roomID
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }
}

public struct DeviceHarborRelayOffer: Codable, Equatable, Sendable {
    public let baseURLString: String
    public let pairingCode: String
    public let session: DeviceHarborHostedRelaySession

    public init(
        baseURLString: String,
        pairingCode: String,
        session: DeviceHarborHostedRelaySession
    ) {
        self.baseURLString = baseURLString
        self.pairingCode = pairingCode
        self.session = session
    }

    public init(
        baseURL: URL,
        pairingCode: String,
        session: DeviceHarborHostedRelaySession
    ) {
        self.init(
            baseURLString: baseURL.absoluteString,
            pairingCode: pairingCode,
            session: session
        )
    }

    public var webSocketURL: URL? {
        guard let baseURL = URL(string: baseURLString) else { return nil }
        return DeviceHarborHostedRelay.roomURL(baseURL: baseURL, roomID: session.roomID)
    }

    public var isExpired: Bool {
        session.expiresAt <= Int64(Date().timeIntervalSince1970 * 1000)
    }
}

public enum DeviceHarborHostedRelay {
    public static func roomURL(baseURL: URL, roomID: String) -> URL? {
        let roomID = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard roomID.range(of: #"^[A-Za-z0-9_-]{6,64}$"#, options: .regularExpression) != nil else {
            return nil
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let path = [basePath, "v1", "rooms", roomID]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components?.path = "/\(path)"
        switch components?.scheme?.lowercased() {
        case "https":
            components?.scheme = "wss"
        case "http":
            components?.scheme = "ws"
        case "wss", "ws":
            break
        default:
            return nil
        }
        return components?.url
    }

}
