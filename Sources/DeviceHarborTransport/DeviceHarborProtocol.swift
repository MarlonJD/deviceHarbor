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
        accessToken: String? = nil
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

    public static func error(message: String) -> Self {
        Self(kind: .error, message: message)
    }

    public static func relayJoin(rendezvousID: String, accessToken: String) -> Self {
        Self(kind: .relayJoin, rendezvousID: rendezvousID, accessToken: accessToken)
    }

    public static func relayReady(rendezvousID: String) -> Self {
        Self(kind: .relayReady, rendezvousID: rendezvousID)
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

    public var errorDescription: String? {
        switch self {
        case .invalidPort:
            "The DeviceHarbor relay port is invalid."
        case .listenerFailed(let message):
            "The DeviceHarbor relay could not start: \(message)"
        }
    }
}
