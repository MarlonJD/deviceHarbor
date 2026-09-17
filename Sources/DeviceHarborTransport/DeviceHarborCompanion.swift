import Foundation
import Network

public enum DeviceHarborCompanionError: LocalizedError, Sendable {
    case notPaired
    case streamUnavailable

    public var errorDescription: String? {
        switch self {
        case .notPaired:
            "No paired DeviceHarbor iPhone companion is connected."
        case .streamUnavailable:
            "The requested CoreDevice stream is not available."
        }
    }
}

public protocol DeviceHarborByteStream: AnyObject, Sendable {
    var onData: (@Sendable (Data) -> Void)? { get set }
    var onEnd: (@Sendable (String?) -> Void)? { get set }
    func send(_ data: Data)
    func close()
}

public protocol DeviceHarborStreamProvider: AnyObject, Sendable {
    func openStream(
        port: UInt16,
        completion: @escaping @Sendable (Result<any DeviceHarborByteStream, Error>) -> Void
    )
}

public enum DeviceHarborCompanionTransport: String, Codable, Sendable {
    case localNetwork
    case relay
}

public enum DeviceHarborCompanionState: Equatable, Sendable {
    case stopped
    case connecting
    case waitingForPair
    case paired(peerID: String, transport: DeviceHarborCompanionTransport)
    case failed(String)
}

public final class DeviceHarborCompanionServer: @unchecked Sendable, DeviceHarborStreamProvider {
    public let peerID: String
    public let displayName: String
    public let pairingCode: String
    public var onStateChange: (@Sendable (DeviceHarborCompanionState) -> Void)?

    private let listener: DeviceHarborListener
    private let lock = NSLock()
    private var session: CompanionServerSession?
    private var pendingSessions: [UUID: CompanionServerSession] = [:]
    private var relayOffer: DeviceHarborRelayOffer?

    public init(displayName: String = "DeviceHarbor Mac") {
        self.peerID = "mac-\(UUID().uuidString)"
        self.displayName = displayName
        self.pairingCode = DeviceHarborPairing.generateCode()
        self.listener = DeviceHarborListener(serviceName: displayName)
        self.listener.onChannel = { [weak self] channel in
            self?.accept(channel)
        }
    }

    public func start() throws {
        try listener.start()
        onStateChange?(.waitingForPair)
    }

    public func stop() {
        listener.stop()
        lock.lock()
        let oldSession = session
        let waitingSessions = Array(pendingSessions.values)
        session = nil
        pendingSessions.removeAll()
        lock.unlock()
        oldSession?.close()
        waitingSessions.forEach { $0.close() }
        onStateChange?(.stopped)
    }

    public func openStream(
        port: UInt16,
        completion: @escaping @Sendable (Result<any DeviceHarborByteStream, Error>) -> Void
    ) {
        lock.lock()
        let activeSession = session
        lock.unlock()
        guard let activeSession else {
            completion(.failure(DeviceHarborCompanionError.notPaired))
            return
        }
        activeSession.openStream(port: port, completion: completion)
    }

    /// Attach an outbound relay connection after the relay has connected both
    /// peers. This is kept separate from local Bonjour discovery so the same
    /// companion session can be used for either path.
    public func connectToRelay(
        host: String,
        port: UInt16,
        rendezvousID: String,
        accessToken: String
    ) throws {
        guard let relayPort = NWEndpoint.Port(rawValue: port) else {
            throw DeviceHarborRelayServerError.invalidPort
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: relayPort,
            using: .tcp
        )
        let channel = DeviceHarborChannel(connection: connection)
        attach(channel, rendezvousID: rendezvousID, accessToken: accessToken)
        channel.start()
    }

    public func connectToHostedRelay(
        offer: DeviceHarborRelayOffer
    ) throws {
        guard let endpoint = offer.webSocketURL else {
            throw DeviceHarborRelayServerError.invalidEndpoint
        }
        let connection = NWConnection(
            to: NWEndpoint.url(endpoint),
            using: DeviceHarborChannel.webSocketParameters()
        )
        let channel = DeviceHarborChannel(connection: connection, transport: .webSocket)
        attach(
            channel,
            rendezvousID: offer.session.roomID,
            accessToken: offer.session.accessToken,
            relayOffer: offer
        )
        channel.start()
    }

    public func setRelayOffer(_ offer: DeviceHarborRelayOffer?) {
        lock.lock()
        relayOffer = offer
        let activeSession = session
        let waitingSessions = Array(pendingSessions.values)
        lock.unlock()
        activeSession?.updateRelayOffer(offer)
        waitingSessions.forEach { $0.updateRelayOffer(offer) }
    }

    private func accept(_ channel: DeviceHarborChannel) {
        lock.lock()
        let offer = relayOffer
        lock.unlock()
        attach(channel, relayOffer: offer)
    }

    private func attach(
        _ channel: DeviceHarborChannel,
        rendezvousID: String? = nil,
        accessToken: String? = nil,
        relayOffer: DeviceHarborRelayOffer? = nil
    ) {
        let sessionID = UUID()
        let newSession = CompanionServerSession(
            channel: channel,
            peerID: peerID,
            displayName: displayName,
            pairingCode: pairingCode,
            rendezvousID: rendezvousID,
            accessToken: accessToken,
            transport: rendezvousID == nil ? .localNetwork : .relay,
            relayOffer: relayOffer,
            onPaired: { [weak self] peerID, session in
                guard let self else { return }
                self.lock.lock()
                self.pendingSessions = self.pendingSessions.filter { $0.value !== session }
                self.session?.close()
                self.session = session
                self.lock.unlock()
                self.onStateChange?(.paired(peerID: peerID, transport: session.transport))
            },
            onClosed: { [weak self] session in
                guard let self else { return }
                self.lock.lock()
                self.pendingSessions = self.pendingSessions.filter { $0.value !== session }
                if self.session === session { self.session = nil }
                self.lock.unlock()
                self.onStateChange?(.waitingForPair)
            }
        )
        lock.lock()
        pendingSessions[sessionID] = newSession
        lock.unlock()
        newSession.start()
    }
}

private final class CompanionServerSession: @unchecked Sendable {
    private let channel: DeviceHarborChannel
    private let peerID: String
    private let displayName: String
    private let pairingCode: String
    private let rendezvousID: String?
    private let accessToken: String?
    let transport: DeviceHarborCompanionTransport
    private let onPaired: @Sendable (String, CompanionServerSession) -> Void
    private let onClosed: @Sendable (CompanionServerSession) -> Void
    private let lock = NSLock()
    private var pairedPeerID: String?
    private var streams: [String: CompanionServerStream] = [:]
    private var openCompletions: [String: @Sendable (Result<any DeviceHarborByteStream, Error>) -> Void] = [:]
    private var didSendRelayJoin = false
    private var didAnnounceHello = false
    private var heartbeatTimer: DispatchSourceTimer?
    private var lastHeartbeat = Date()
    private var relayOffer: DeviceHarborRelayOffer?

    init(
        channel: DeviceHarborChannel,
        peerID: String,
        displayName: String,
        pairingCode: String,
        rendezvousID: String?,
        accessToken: String?,
        transport: DeviceHarborCompanionTransport,
        relayOffer: DeviceHarborRelayOffer?,
        onPaired: @escaping @Sendable (String, CompanionServerSession) -> Void,
        onClosed: @escaping @Sendable (CompanionServerSession) -> Void
    ) {
        self.channel = channel
        self.peerID = peerID
        self.displayName = displayName
        self.pairingCode = pairingCode
        self.rendezvousID = rendezvousID
        self.accessToken = accessToken
        self.transport = transport
        self.relayOffer = relayOffer
        self.onPaired = onPaired
        self.onClosed = onClosed
    }

    func start() {
        channel.onFrame = { [weak self] frame in self?.handle(frame) }
        channel.onStateChange = { [weak self] state in
            guard let self else { return }
            if case .cancelled = state { self.onClosed(self) }
            if case .failed = state { self.onClosed(self) }
            if case .ready = state { self.startHandshake() }
        }
        startHeartbeat()
    }

    func close() {
        stopHeartbeat()
        channel.cancel()
        lock.lock()
        let active = Array(streams.values)
        streams.removeAll()
        let completions = Array(openCompletions.values)
        openCompletions.removeAll()
        lock.unlock()
        active.forEach { $0.close() }
        completions.forEach { $0(.failure(DeviceHarborCompanionError.streamUnavailable)) }
    }

    func openStream(
        port: UInt16,
        completion: @escaping @Sendable (Result<any DeviceHarborByteStream, Error>) -> Void
    ) {
        let streamID = UUID().uuidString
        let stream = CompanionServerStream(
            streamID: streamID,
            send: { [weak self] frame in self?.channel.send(frame) },
            remove: { [weak self] id in self?.removeStream(id) }
        )
        lock.lock()
        streams[streamID] = stream
        openCompletions[streamID] = completion
        lock.unlock()
        channel.send(.openStream(streamID: streamID, port: port))
    }

    private func handle(_ frame: DeviceHarborFrame) {
        switch frame.kind {
        case .relayReady:
            announceHello()
        case .pairRequest:
            guard frame.pairingCode == pairingCode, let peerID = frame.peerID else {
                channel.send(.pairRejected(message: "Pairing code did not match."))
                return
            }
            lock.lock()
            pairedPeerID = peerID
            lock.unlock()
            channel.send(.pairAccepted(peerID: self.peerID))
            sendRelayOfferIfNeeded()
            onPaired(peerID, self)
        case .heartbeat:
            lock.lock()
            lastHeartbeat = Date()
            lock.unlock()
            if frame.message == "ping" {
                channel.send(.heartbeat(message: "pong"))
            }
        case .streamReady:
            guard let streamID = frame.streamID else { return }
            lock.lock()
            let stream = streams[streamID]
            let completion = openCompletions.removeValue(forKey: streamID)
            lock.unlock()
            if let stream, let completion {
                completion(.success(stream))
            }
        case .streamData:
            guard let streamID = frame.streamID, let payload = frame.payload else { return }
            lock.lock()
            let stream = streams[streamID]
            lock.unlock()
            stream?.receive(payload)
        case .closeStream:
            guard let streamID = frame.streamID else { return }
            lock.lock()
            let stream = streams.removeValue(forKey: streamID)
            let completion = openCompletions.removeValue(forKey: streamID)
            lock.unlock()
            completion?(.failure(DeviceHarborCompanionError.streamUnavailable))
            stream?.finish(frame.message)
        case .hello, .pairAccepted, .pairRejected, .openStream, .error, .relayJoin, .relayOffer:
            break
        }
    }

    func updateRelayOffer(_ offer: DeviceHarborRelayOffer?) {
        lock.lock()
        relayOffer = offer
        let shouldSend = pairedPeerID != nil
        lock.unlock()
        if shouldSend {
            sendRelayOfferIfNeeded()
        }
    }

    private func sendRelayOfferIfNeeded() {
        guard transport == .localNetwork else { return }
        lock.lock()
        let offer = relayOffer
        lock.unlock()
        guard let offer else { return }
        channel.send(.relayOffer(offer))
    }

    private func announceHello() {
        lock.lock()
        guard !didAnnounceHello else {
            lock.unlock()
            return
        }
        didAnnounceHello = true
        lock.unlock()
        channel.send(.hello(peerID: peerID, displayName: displayName))
    }

    private func startHandshake() {
        if let rendezvousID, let accessToken {
            lock.lock()
            guard !didSendRelayJoin else {
                lock.unlock()
                return
            }
            didSendRelayJoin = true
            lock.unlock()
            channel.send(.relayJoin(rendezvousID: rendezvousID, accessToken: accessToken))
        } else {
            announceHello()
        }
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.deviceharbor.transport.heartbeat"))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.heartbeatTick()
        }
        lock.lock()
        guard heartbeatTimer == nil else {
            lock.unlock()
            return
        }
        lastHeartbeat = Date()
        heartbeatTimer = timer
        lock.unlock()
        timer.resume()
    }

    private func stopHeartbeat() {
        lock.lock()
        let timer = heartbeatTimer
        heartbeatTimer = nil
        lock.unlock()
        timer?.cancel()
    }

    private func heartbeatTick() {
        lock.lock()
        let isStale = Date().timeIntervalSince(lastHeartbeat) > 15
        lock.unlock()
        if isStale {
            close()
        } else {
            channel.send(.heartbeat(message: "ping"))
        }
    }

    private func removeStream(_ streamID: String) {
        lock.lock()
        streams.removeValue(forKey: streamID)
        openCompletions.removeValue(forKey: streamID)
        lock.unlock()
    }
}

private final class CompanionServerStream: @unchecked Sendable, DeviceHarborByteStream {
    let streamID: String
    var onData: (@Sendable (Data) -> Void)?
    var onEnd: (@Sendable (String?) -> Void)?

    private let sendFrame: @Sendable (DeviceHarborFrame) -> Void
    private let remove: @Sendable (String) -> Void
    private let lock = NSLock()
    private var closed = false

    init(
        streamID: String,
        send: @escaping @Sendable (DeviceHarborFrame) -> Void,
        remove: @escaping @Sendable (String) -> Void
    ) {
        self.streamID = streamID
        self.sendFrame = send
        self.remove = remove
    }

    func send(_ data: Data) {
        lock.lock()
        let canSend = !closed
        lock.unlock()
        guard canSend else { return }
        sendFrame(.streamData(streamID: streamID, payload: data))
    }

    func receive(_ data: Data) {
        onData?(data)
    }

    func finish(_ message: String?) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        onEnd?(message)
        remove(streamID)
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        sendFrame(.closeStream(streamID: streamID))
        remove(streamID)
    }
}

/// Client used by the iPhone companion. The client keeps the connection
/// outbound from iOS and turns Mac stream requests into connections to the
/// local CoreDevice endpoint exposed by the current Apple pairing session.
public final class DeviceHarborCompanionClient: @unchecked Sendable {
    public let peerID: String
    public let displayName: String
    public var onStateChange: (@Sendable (DeviceHarborCompanionState) -> Void)?
    public var onMacHello: (@Sendable (String, String) -> Void)?
    public var onRelayOffer: (@Sendable (DeviceHarborRelayOffer) -> Void)?

    private let localHost: NWEndpoint.Host
    private let queue = DispatchQueue(label: "dev.deviceharbor.transport.client")
    private let lock = NSLock()
    private var channel: DeviceHarborChannel?
    private var paired = false
    private var transport: DeviceHarborCompanionTransport = .localNetwork
    private var streams: [String: ReverseCoreDeviceStream] = [:]

    public init(
        displayName: String = "DeviceHarbor iPhone",
        localHost: String = "127.0.0.1"
    ) {
        self.peerID = "iphone-\(UUID().uuidString)"
        self.displayName = displayName
        self.localHost = NWEndpoint.Host(localHost)
    }

    public func connect(
        to endpoint: NWEndpoint,
        parameters: NWParameters = .tcp,
        transport: DeviceHarborChannelTransport = .tcp,
        rendezvousID: String? = nil,
        accessToken: String? = nil
    ) {
        disconnect()
        onStateChange?(.connecting)

        let connection = NWConnection(to: endpoint, using: parameters)
        let channel = DeviceHarborChannel(connection: connection, queue: queue, transport: transport)
        channel.onStateChange = { [weak self, rendezvousID, accessToken] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let rendezvousID, let accessToken {
                    self.send(.relayJoin(rendezvousID: rendezvousID, accessToken: accessToken))
                } else {
                    self.onStateChange?(.waitingForPair)
                }
            case .failed(let message):
                self.onStateChange?(.failed(message))
                self.closeStreams()
            case .cancelled:
                self.onStateChange?(.stopped)
                self.closeStreams()
            case .preparing:
                self.onStateChange?(.connecting)
            }
        }
        channel.onFrame = { [weak self] frame in
            self?.handle(frame)
        }
        lock.lock()
        self.channel = channel
        self.paired = false
        self.transport = rendezvousID == nil ? .localNetwork : .relay
        lock.unlock()
        channel.start()
    }

    public func pair(using pairingCode: String) {
        lock.lock()
        let channel = self.channel
        lock.unlock()
        guard let channel else {
            onStateChange?(.failed(DeviceHarborCompanionError.notPaired.localizedDescription))
            return
        }
        channel.send(.pairRequest(peerID: peerID, pairingCode: pairingCode))
    }

    public func disconnect() {
        lock.lock()
        let channel = self.channel
        self.channel = nil
        paired = false
        transport = .localNetwork
        let activeStreams = Array(streams.values)
        streams.removeAll()
        lock.unlock()
        activeStreams.forEach { $0.close(sendFrame: false) }
        channel?.cancel()
        onStateChange?(.stopped)
    }

    private func handle(_ frame: DeviceHarborFrame) {
        switch frame.kind {
        case .hello:
            guard let peerID = frame.peerID, let displayName = frame.displayName else { return }
            onMacHello?(peerID, displayName)
            onStateChange?(.waitingForPair)
        case .pairAccepted:
            lock.lock()
            paired = true
            let transport = self.transport
            lock.unlock()
            if let peerID = frame.peerID {
                onStateChange?(.paired(peerID: peerID, transport: transport))
            }
        case .pairRejected:
            onStateChange?(.failed(frame.message ?? "Pairing rejected."))
        case .openStream:
            guard let streamID = frame.streamID, let port = frame.port else { return }
            openLocalStream(streamID: streamID, port: port)
        case .streamData:
            guard let streamID = frame.streamID, let payload = frame.payload else { return }
            lock.lock()
            let stream = streams[streamID]
            lock.unlock()
            stream?.sendToLocal(payload)
        case .closeStream:
            guard let streamID = frame.streamID else { return }
            lock.lock()
            let stream = streams.removeValue(forKey: streamID)
            lock.unlock()
            stream?.close(sendFrame: false)
        case .heartbeat:
            if frame.message == "ping" {
                send(.heartbeat(message: "pong"))
            }
        case .error:
            onStateChange?(.failed(frame.message ?? "Transport error."))
        case .relayOffer:
            guard let endpoint = frame.relayEndpoint,
                  let pairingCode = frame.pairingCode,
                  pairingCode.range(of: #"^\d{6}$"#, options: .regularExpression) != nil,
                  let roomID = frame.relayRoomID,
                  let accessToken = frame.relayAccessToken,
                  let expiresAt = frame.relayExpiresAt else {
                onStateChange?(.failed("The Mac companion sent an incomplete relay offer."))
                return
            }
            onRelayOffer?(
                DeviceHarborRelayOffer(
                    baseURLString: endpoint,
                    pairingCode: pairingCode,
                    session: DeviceHarborHostedRelaySession(
                        roomID: roomID,
                        accessToken: accessToken,
                        expiresAt: expiresAt
                    )
                )
            )
        case .pairRequest, .streamReady, .relayReady, .relayJoin:
            break
        }
    }

    private func openLocalStream(streamID: String, port: UInt16) {
        lock.lock()
        let isPaired = paired
        lock.unlock()
        guard isPaired, let localPort = NWEndpoint.Port(rawValue: port) else {
            send(.closeStream(streamID: streamID, message: "The iPhone companion is not paired or the port is invalid."))
            return
        }

        let connection = NWConnection(host: localHost, port: localPort, using: .tcp)
        let stream = ReverseCoreDeviceStream(
            streamID: streamID,
            connection: connection,
            channel: self,
            queue: queue,
            onEnd: { [weak self] streamID, message in
                self?.removeStream(streamID, message: message)
            }
        )
        lock.lock()
        streams[streamID] = stream
        lock.unlock()
        stream.start()
    }

    private func send(_ frame: DeviceHarborFrame) {
        lock.lock()
        let channel = self.channel
        lock.unlock()
        channel?.send(frame)
    }

    private func sendStreamReady(_ streamID: String) {
        send(.streamReady(streamID: streamID))
    }

    private func sendStreamData(_ streamID: String, payload: Data) {
        send(.streamData(streamID: streamID, payload: payload))
    }

    private func sendStreamClosed(_ streamID: String, message: String?) {
        send(.closeStream(streamID: streamID, message: message))
    }

    private func removeStream(_ streamID: String, message: String?) {
        lock.lock()
        streams.removeValue(forKey: streamID)
        lock.unlock()
        sendStreamClosed(streamID, message: message)
    }

    private func closeStreams() {
        lock.lock()
        let activeStreams = Array(streams.values)
        streams.removeAll()
        lock.unlock()
        activeStreams.forEach { $0.close(sendFrame: false) }
    }

    private final class ReverseCoreDeviceStream: @unchecked Sendable {
        private let streamID: String
        private let connection: NWConnection
        private weak var client: DeviceHarborCompanionClient?
        private let queue: DispatchQueue
        private let onEnd: @Sendable (String, String?) -> Void
        private let lock = NSLock()
        private var closed = false

        init(
            streamID: String,
            connection: NWConnection,
            channel: DeviceHarborCompanionClient,
            queue: DispatchQueue,
            onEnd: @escaping @Sendable (String, String?) -> Void
        ) {
            self.streamID = streamID
            self.connection = connection
            self.client = channel
            self.queue = queue
            self.onEnd = onEnd
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.client?.sendStreamReady(self.streamID)
                    self.receiveNext()
                case .failed(let error):
                    self.finish(error.localizedDescription, sendFrame: true)
                case .cancelled:
                    self.finish(nil, sendFrame: false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        func sendToLocal(_ data: Data) {
            lock.lock()
            let canSend = !closed
            lock.unlock()
            guard canSend else { return }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.finish(error.localizedDescription, sendFrame: true)
                }
            })
        }

        func close(sendFrame: Bool) {
            finish(nil, sendFrame: sendFrame)
        }

        private func receiveNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.client?.sendStreamData(self.streamID, payload: data)
                }
                if let error {
                    self.finish(error.localizedDescription, sendFrame: true)
                } else if isComplete {
                    self.finish(nil, sendFrame: true)
                } else {
                    self.receiveNext()
                }
            }
        }

        private func finish(_ message: String?, sendFrame: Bool) {
            lock.lock()
            guard !closed else {
                lock.unlock()
                return
            }
            closed = true
            lock.unlock()
            connection.cancel()
            if sendFrame {
                client?.sendStreamClosed(streamID, message: message)
            }
            onEnd(streamID, message)
        }
    }
}
