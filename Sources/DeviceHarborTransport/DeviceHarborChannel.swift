import Foundation
import Network

public enum DeviceHarborChannelState: Equatable, Sendable {
    case preparing
    case ready
    case failed(String)
    case cancelled
}

public enum DeviceHarborChannelTransport: Equatable, Sendable {
    case tcp
    case webSocket
}

public final class DeviceHarborChannel: @unchecked Sendable {
    public let connection: NWConnection
    public let transport: DeviceHarborChannelTransport
    public var onStateChange: (@Sendable (DeviceHarborChannelState) -> Void)?
    public var onFrame: (@Sendable (DeviceHarborFrame) -> Void)?

    private let queue: DispatchQueue
    private let sendQueue = DispatchQueue(label: "dev.deviceharbor.transport.send")
    private let lock = NSLock()
    private var receiveBuffer = Data()
    private var didStart = false

    public init(
        connection: NWConnection,
        queue: DispatchQueue? = nil,
        transport: DeviceHarborChannelTransport = .tcp
    ) {
        self.connection = connection
        self.transport = transport
        self.queue = queue ?? DispatchQueue(label: "dev.deviceharbor.transport.channel")
    }

    public static func webSocketParameters() -> NWParameters {
        let parameters = NWParameters(
            tls: NWProtocolTLS.Options(),
            tcp: NWProtocolTCP.Options()
        )
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = 2 * 1024 * 1024
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        return parameters
    }

    public func start() {
        lock.lock()
        guard !didStart else {
            lock.unlock()
            return
        }
        didStart = true
        lock.unlock()

        onStateChange?(.preparing)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onStateChange?(.ready)
                self.receiveNext()
            case .failed(let error):
                self.onStateChange?(.failed(error.localizedDescription))
            case .cancelled:
                self.onStateChange?(.cancelled)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ frame: DeviceHarborFrame) {
        sendQueue.async { [weak self] in
            guard let self else { return }
            do {
                let data = try DeviceHarborWireCodec.encode(frame)
                let completion: NWConnection.SendCompletion = .contentProcessed { [weak self] error in
                    if let error {
                        self?.onStateChange?(.failed(error.localizedDescription))
                    }
                }
                if self.transport == .webSocket {
                    let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
                    let context = NWConnection.ContentContext(
                        identifier: "DeviceHarborFrame",
                        metadata: [metadata]
                    )
                    self.connection.send(
                        content: data,
                        contentContext: context,
                        isComplete: true,
                        completion: completion
                    )
                } else {
                    self.connection.send(content: data, completion: completion)
                }
            } catch {
                self.onStateChange?(.failed(error.localizedDescription))
            }
        }
    }

    public func cancel() {
        connection.cancel()
    }

    private func receiveNext() {
        if transport == .webSocket {
            connection.receiveMessage { [weak self] data, _, _, error in
                self?.handleReceived(data: data, isComplete: data == nil, error: error)
            }
            return
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            self?.handleReceived(data: data, isComplete: isComplete, error: error)
        }
    }

    private func handleReceived(data: Data?, isComplete: Bool, error: NWError?) {
        if let data, !data.isEmpty {
            lock.lock()
            receiveBuffer.append(data)
            do {
                let frames = try DeviceHarborWireCodec.decodeLines(from: &receiveBuffer)
                lock.unlock()
                frames.forEach { onFrame?($0) }
            } catch {
                lock.unlock()
                onStateChange?(.failed(error.localizedDescription))
                connection.cancel()
                return
            }
        }
        if isComplete || error != nil {
            if let error {
                onStateChange?(.failed(error.localizedDescription))
            } else {
                onStateChange?(.cancelled)
            }
            return
        }
        receiveNext()
    }
}

public final class DeviceHarborListener: @unchecked Sendable {
    public let serviceName: String
    public let serviceType: String
    public var onChannel: (@Sendable (DeviceHarborChannel) -> Void)?

    private let queue = DispatchQueue(label: "dev.deviceharbor.transport.listener")
    private var listener: NWListener?

    public init(serviceName: String = "DeviceHarbor Mac", serviceType: String = "_deviceharbor._tcp") {
        self.serviceName = serviceName
        self.serviceType = serviceType
    }

    public func start() throws {
        let listener = try NWListener(using: .tcp)
        listener.service = NWListener.Service(
            name: serviceName,
            type: serviceType,
            domain: "local."
        )
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let channel = DeviceHarborChannel(connection: connection, queue: self.queue)
            self.onChannel?(channel)
            channel.start()
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }
}
