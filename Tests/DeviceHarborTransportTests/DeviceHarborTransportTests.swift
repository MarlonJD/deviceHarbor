import DeviceHarborTransport
import Foundation
import Network
import XCTest

final class DeviceHarborTransportTests: XCTestCase {
    func testRelayPairsTwoOutboundChannelsAndForwardsFrames() throws {
        let port = UInt16.random(in: 30_000...40_000)
        let relay = try DeviceHarborRelayServer(port: port)
        try relay.start()
        defer { relay.stop() }

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let channelA = DeviceHarborChannel(
            connection: NWConnection(to: endpoint, using: .tcp)
        )
        let channelB = DeviceHarborChannel(
            connection: NWConnection(to: endpoint, using: .tcp)
        )
        let observations = RelayObservations()

        channelA.onStateChange = { state in
            if case .ready = state {
                channelA.send(.relayJoin(rendezvousID: "room", accessToken: "token"))
            }
        }
        channelB.onStateChange = { state in
            if case .ready = state {
                channelB.send(.relayJoin(rendezvousID: "room", accessToken: "token"))
            }
        }
        channelA.onFrame = { frame in
            if frame.kind == .relayReady {
                observations.markReady()
            }
        }
        channelB.onFrame = { frame in
            switch frame.kind {
            case .relayReady:
                observations.markReady()
                channelA.send(.hello(peerID: "peer-a", displayName: "Peer A"))
            case .hello:
                observations.forwarded.fulfill()
            default:
                break
            }
        }

        channelA.start()
        channelB.start()
        wait(for: [observations.ready, observations.forwarded], timeout: 5)

        channelA.cancel()
        channelB.cancel()
    }

    func testRelayRejectsAnInvalidPort() {
        XCTAssertThrowsError(try DeviceHarborRelayServer(port: 0)) { error in
            XCTAssertEqual((error as? DeviceHarborRelayServerError)?.errorDescription, "The DeviceHarbor relay port is invalid.")
        }
    }

    func testHostedRelayBuildsRoomURLAndNormalizesHTTPS() {
        let baseURL = URL(string: "https://relay.example.test/edge")!

        let roomURL = DeviceHarborHostedRelay.roomURL(
            baseURL: baseURL,
            roomID: "123456"
        )

        XCTAssertEqual(roomURL?.absoluteString, "wss://relay.example.test/edge/v1/rooms/123456")
        XCTAssertNil(DeviceHarborHostedRelay.roomURL(baseURL: baseURL, roomID: "short"))
    }

    func testRelayOfferFrameCarriesRuntimeEndpointAndPairingCode() throws {
        let session = DeviceHarborHostedRelaySession(
            roomID: "room-123456",
            accessToken: "runtime-secret",
            expiresAt: Int64(Date().timeIntervalSince1970 * 1000) + 60_000
        )
        let offer = DeviceHarborRelayOffer(
            baseURLString: "https://relay.example.test",
            pairingCode: "123456",
            session: session
        )
        let frame = DeviceHarborFrame.relayOffer(offer)
        var buffer = try DeviceHarborWireCodec.encode(frame)

        XCTAssertEqual(try DeviceHarborWireCodec.decodeLines(from: &buffer), [frame])
        XCTAssertEqual(offer.webSocketURL?.absoluteString, "wss://relay.example.test/v1/rooms/room-123456")
    }

    func testCompanionPairingWorksThroughRelay() throws {
        let port = UInt16.random(in: 30_000...40_000)
        let relay = try DeviceHarborRelayServer(port: port)
        try relay.start()
        defer { relay.stop() }

        let mac = DeviceHarborCompanionServer(displayName: "Test Mac")
        let iphone = DeviceHarborCompanionClient(displayName: "Test iPhone")
        let macPaired = XCTestExpectation(description: "Mac companion pairs through the relay")
        let iPhonePaired = XCTestExpectation(description: "iPhone companion pairs through the relay")

        mac.onStateChange = { state in
            if case .paired = state {
                macPaired.fulfill()
            }
        }
        iphone.onStateChange = { state in
            if case .paired = state {
                iPhonePaired.fulfill()
            }
        }
        iphone.onMacHello = { _, _ in
            iphone.pair(using: mac.pairingCode)
        }

        try mac.connectToRelay(
            host: "127.0.0.1",
            port: port,
            rendezvousID: mac.pairingCode,
            accessToken: mac.pairingCode
        )
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!
        )
        iphone.connect(
            to: endpoint,
            rendezvousID: mac.pairingCode,
            accessToken: mac.pairingCode
        )

        wait(for: [macPaired, iPhonePaired], timeout: 5)
        iphone.disconnect()
        mac.stop()
    }

    func testCompanionPairingWorksThroughHostedWebSocketRelay() throws {
        guard let rawURL = ProcessInfo.processInfo.environment["DEVICEHARBOR_HOSTED_RELAY_URL"],
              URL(string: rawURL) != nil else {
            throw XCTSkip("Set DEVICEHARBOR_HOSTED_RELAY_URL to run the hosted relay test.")
        }

        let mac = DeviceHarborCompanionServer(displayName: "Hosted Test Mac")
        let iphone = DeviceHarborCompanionClient(displayName: "Hosted Test iPhone")
        let macPaired = XCTestExpectation(description: "Mac pairs through hosted relay")
        let iPhonePaired = XCTestExpectation(description: "iPhone pairs through hosted relay")
        let session = DeviceHarborHostedRelaySession(
            roomID: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            accessToken: "\(UUID().uuidString)\(UUID().uuidString)",
            expiresAt: Int64(Date().timeIntervalSince1970 * 1000) + 60 * 60 * 1000
        )
        let offer = DeviceHarborRelayOffer(
            baseURLString: rawURL,
            pairingCode: mac.pairingCode,
            session: session
        )

        mac.onStateChange = { state in
            if case .paired = state {
                macPaired.fulfill()
            }
        }
        iphone.onStateChange = { state in
            if case .paired = state {
                iPhonePaired.fulfill()
            }
        }
        iphone.onMacHello = { _, _ in
            iphone.pair(using: mac.pairingCode)
        }

        try mac.connectToHostedRelay(offer: offer)
        guard let endpoint = offer.webSocketURL else {
            XCTFail("Hosted relay room URL could not be constructed")
            return
        }
        iphone.connect(
            to: NWEndpoint.url(endpoint),
            parameters: DeviceHarborChannel.webSocketParameters(),
            transport: .webSocket,
            rendezvousID: session.roomID,
            accessToken: session.accessToken
        )

        wait(for: [macPaired, iPhonePaired], timeout: 15)
        iphone.disconnect()
        mac.stop()
    }
}

private final class RelayObservations: @unchecked Sendable {
    let ready = XCTestExpectation(description: "Both relay peers receive relayReady")
    let forwarded = XCTestExpectation(description: "Relay forwards a frame")
    private let lock = NSLock()
    private var readyCount = 0

    func markReady() {
        lock.lock()
        readyCount += 1
        let complete = readyCount == 2
        lock.unlock()
        if complete {
            ready.fulfill()
        }
    }
}
