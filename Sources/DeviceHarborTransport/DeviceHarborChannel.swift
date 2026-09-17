import Foundation
import Network

public enum DeviceHarborChannelState: Equatable, Sendable {
    case preparing
    case ready
    case failed(String)
    case cancelled
}

public final class DeviceHarborChannel: @unchecked Sendable {
    public let connection: NWConnection
    public var onStateChange: (@Sendable (DeviceHarborChannelState) -> Void)?
    public var onFrame: (@Sendable (DeviceHarborFrame) -> Void)?

    private let queue: DispatchQueue
    private let sendQueue = DispatchQueue(label: "dev.deviceharbor.transport.send")
    private let lock = NSLock()
    private var receiveBuffer = Data()
    private var didStart = false

    public init(connection: NWConnection, queue: DispatchQueue? = nil) {
        self.connection = connection
        self.queue = queue ?? DispatchQueue(label: "dev.deviceharbor.transport.channel")
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
                self.connection.send(content: data, completion: .contentProcessed { _ in })
            } catch {
                self.onStateChange?(.failed(error.localizedDescription))
            }
        }
    }

    public func cancel() {
        connection.cancel()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.lock()
                self.receiveBuffer.append(data)
                do {
                    let frames = try DeviceHarborWireCodec.decodeLines(from: &self.receiveBuffer)
                    self.lock.unlock()
                    frames.forEach { self.onFrame?($0) }
                } catch {
                    self.lock.unlock()
                    self.onStateChange?(.failed(error.localizedDescription))
                    self.connection.cancel()
                    return
                }
            }
            if isComplete || error != nil {
                if let error {
                    self.onStateChange?(.failed(error.localizedDescription))
                } else {
                    self.onStateChange?(.cancelled)
                }
                return
            }
            self.receiveNext()
        }
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
