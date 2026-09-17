import Foundation
import Network

/// Minimal DeviceHarbor-owned rendezvous relay.
///
/// Clients connect out to this listener, join the same per-user room, and
/// exchange the already-framed DeviceHarbor protocol. The relay never opens
/// a CoreDevice port and never interprets stream payloads.
public final class DeviceHarborRelayServer: @unchecked Sendable {
    private final class Peer: @unchecked Sendable {
        let id: UUID
        let channel: DeviceHarborChannel
        var roomID: String?
        var accessToken: String?
        var isJoined = false

        init(id: UUID, channel: DeviceHarborChannel) {
            self.id = id
            self.channel = channel
        }
    }

    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "dev.deviceharbor.relay-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var peers: [UUID: Peer] = [:]

    public init(port: UInt16 = 49_153) throws {
        guard port > 0, let port = NWEndpoint.Port(rawValue: port) else {
            throw DeviceHarborRelayServerError.invalidPort
        }
        self.port = port
    }

    public func start() throws {
        let listener = try NWListener(using: .tcp, on: port)
        let startState = RelayStartState()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                startState.store(.success(()))
            case .failed(let error):
                startState.store(.failure(DeviceHarborRelayServerError.listenerFailed(error.localizedDescription)))
                fputs("DeviceHarbor relay failed: \(error.localizedDescription)\n", stderr)
            case .cancelled:
                startState.store(.failure(DeviceHarborRelayServerError.listenerFailed("listener was cancelled")))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard startState.semaphore.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw DeviceHarborRelayServerError.listenerFailed("timed out waiting for listener")
        }
        if case .failure(let error) = startState.result {
            listener.cancel()
            throw error
        }
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        let activePeers = Array(peers.values)
        peers.removeAll()
        lock.unlock()
        activePeers.forEach { $0.channel.cancel() }
    }

    deinit {
        stop()
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let channel = DeviceHarborChannel(connection: connection, queue: queue)
        let peer = Peer(id: id, channel: channel)
        lock.lock()
        peers[id] = peer
        lock.unlock()

        channel.onFrame = { [weak self, weak peer] frame in
            guard let self, let peer else { return }
            self.handle(frame, from: peer)
        }
        channel.onStateChange = { [weak self, weak peer] state in
            guard let self, let peer else { return }
            switch state {
            case .failed, .cancelled:
                self.remove(peer)
            case .preparing, .ready:
                break
            }
        }
        channel.start()
    }

    private func handle(_ frame: DeviceHarborFrame, from peer: Peer) {
        if frame.kind == .relayJoin {
            join(peer, frame: frame)
            return
        }

        lock.lock()
        let isJoined = peer.isJoined
        let roomID = peer.roomID
        let recipients = peers.values.filter {
            $0.id != peer.id && $0.isJoined && $0.roomID == roomID
        }.map(\.channel)
        lock.unlock()

        guard isJoined else {
            peer.channel.send(.error(message: "Join a DeviceHarbor relay room first."))
            return
        }
        recipients.forEach { $0.send(frame) }
    }

    private func join(_ peer: Peer, frame: DeviceHarborFrame) {
        guard
            let roomID = frame.rendezvousID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !roomID.isEmpty,
            let accessToken = frame.accessToken,
            !accessToken.isEmpty
        else {
            peer.channel.send(.error(message: "The relay join request is incomplete."))
            peer.channel.cancel()
            return
        }

        lock.lock()
        let roomPeers = peers.values.filter { $0.isJoined && $0.roomID == roomID }
        guard roomPeers.count < 2 else {
            lock.unlock()
            peer.channel.send(.error(message: "This DeviceHarbor relay room already has two peers."))
            peer.channel.cancel()
            return
        }
        if let existingToken = roomPeers.first?.accessToken, existingToken != accessToken {
            lock.unlock()
            peer.channel.send(.error(message: "The DeviceHarbor relay room token did not match."))
            peer.channel.cancel()
            return
        }
        peer.roomID = roomID
        peer.accessToken = accessToken
        peer.isJoined = true
        let nowJoined = peers.values.filter { $0.isJoined && $0.roomID == roomID }
        lock.unlock()

        guard nowJoined.count == 2 else { return }
        nowJoined.forEach { $0.channel.send(.relayReady(rendezvousID: roomID)) }
    }

    private func remove(_ peer: Peer) {
        lock.lock()
        peers.removeValue(forKey: peer.id)
        lock.unlock()
    }
}

private final class RelayStartState: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedResult: Result<Void, Error>?

    var result: Result<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storedResult
    }

    func store(_ result: Result<Void, Error>) {
        lock.lock()
        guard storedResult == nil else {
            lock.unlock()
            return
        }
        storedResult = result
        lock.unlock()
        semaphore.signal()
    }
}
