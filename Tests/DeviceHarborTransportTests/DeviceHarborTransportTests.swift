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
