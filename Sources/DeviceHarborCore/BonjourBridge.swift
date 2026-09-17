import Foundation
import Network

public enum BridgeError: LocalizedError, Sendable {
    case invalidProfile
    case invalidService(String)
    case listenerFailed(String)
    case proxyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidProfile:
            "The bridge profile is incomplete. Add at least one valid service."
        case .invalidService(let message):
            "Invalid bridge service: \(message)"
        case .listenerFailed(let message):
            "Could not start the local TCP relay: \(message)"
        case .proxyFailed(let message):
            "Could not publish the Bonjour proxy: \(message)"
        }
    }
}

public struct BonjourProxyCommand: Hashable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String = "/usr/bin/dns-sd", arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    public static func make(
        instanceName: String,
        serviceType: String,
        domain: String,
        localPort: UInt16,
        hostName: String,
        localAddress: String,
        textRecords: [String: String]
    ) -> BonjourProxyCommand {
        let txt = textRecords
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        return BonjourProxyCommand(arguments: [
            "-P",
            instanceName,
            serviceType,
            domain,
            String(localPort),
            hostName,
            localAddress
        ] + txt)
    }
}

public final class BonjourProxyRegistration: @unchecked Sendable {
    private let process: Process

    public init(command: BonjourProxyCommand) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw BridgeError.proxyFailed(error.localizedDescription)
        }
        self.process = process
    }

    public func stop() {
        guard process.isRunning else { return }
        process.terminate()
    }

    deinit {
        stop()
    }
}

public final class TCPRelay: @unchecked Sendable {
    private let service: RelayService
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var sessions: [UUID: RelaySession] = [:]
    private let lock = NSLock()

    public init(service: RelayService) {
        self.service = service
        self.queue = DispatchQueue(label: "dev.deviceharbor.relay.\(service.id.uuidString)")
    }

    public func start() throws -> UInt16 {
        guard service.isValid else {
            throw BridgeError.invalidService("missing instance, service type, address, or port")
        }
        guard let remotePort = NWEndpoint.Port(rawValue: service.remotePort) else {
            throw BridgeError.invalidService("remote port is out of range")
        }

        let listener: NWListener
        do {
            if let localPort = service.localPort {
                guard let requestedPort = NWEndpoint.Port(rawValue: localPort) else {
                    throw BridgeError.invalidService("local port is out of range")
                }
                listener = try NWListener(using: .tcp, on: requestedPort)
            } else {
                listener = try NWListener(using: .tcp)
            }
        } catch {
            if let bridgeError = error as? BridgeError { throw bridgeError }
            throw BridgeError.listenerFailed(error.localizedDescription)
        }

        let startState = ListenerStartState()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = listener.port?.rawValue {
                    startState.store(.success(port))
                } else {
                    startState.store(.failure(BridgeError.listenerFailed("listener has no assigned port")))
                }
            case .failed(let error):
                startState.store(.failure(error))
            case .cancelled:
                if startState.result == nil {
                    startState.store(.failure(BridgeError.listenerFailed("listener was cancelled")))
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, remotePort: remotePort)
        }
        listener.start(queue: queue)

        guard startState.semaphore.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw BridgeError.listenerFailed("timed out waiting for listener")
        }

        guard let result = startState.result else {
            listener.cancel()
            throw BridgeError.listenerFailed("listener did not report a state")
        }
        switch result {
        case .success(let port):
            self.listener = listener
            return port
        case .failure(let error):
            listener.cancel()
            if let bridgeError = error as? BridgeError { throw bridgeError }
            throw BridgeError.listenerFailed(error.localizedDescription)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        let activeSessions = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        activeSessions.forEach { $0.stop() }
    }

    private func accept(_ connection: NWConnection, remotePort: NWEndpoint.Port) {
        let sessionID = UUID()
        let remote = NWConnection(
            host: NWEndpoint.Host(service.remoteAddress),
            port: remotePort,
            using: .tcp
        )
        let session = RelaySession(inbound: connection, outbound: remote, queue: queue) { [weak self] in
            self?.remove(sessionID)
        }
        lock.lock()
        sessions[sessionID] = session
        lock.unlock()
        session.start()
    }

    private func remove(_ id: UUID) {
        lock.lock()
        sessions.removeValue(forKey: id)
        lock.unlock()
    }
}

private final class ListenerStartState: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedResult: Result<UInt16, Error>?

    var result: Result<UInt16, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storedResult
    }

    func store(_ result: Result<UInt16, Error>) {
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

private final class RelaySession: @unchecked Sendable {
    private let inbound: NWConnection
    private let outbound: NWConnection
    private let queue: DispatchQueue
    private let onStop: () -> Void
    private let lock = NSLock()
    private var stopped = false

    init(inbound: NWConnection, outbound: NWConnection, queue: DispatchQueue, onStop: @escaping () -> Void) {
        self.inbound = inbound
        self.outbound = outbound
        self.queue = queue
        self.onStop = onStop
    }

    func start() {
        inbound.start(queue: queue)
        outbound.start(queue: queue)
        pump(from: inbound, to: outbound)
        pump(from: outbound, to: inbound)
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        inbound.cancel()
        outbound.cancel()
        onStop()
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.stop() }
                })
            }
            if isComplete || error != nil {
                self.stop()
            } else {
                self.pump(from: source, to: destination)
            }
        }
    }
}

public struct BridgeStartResult: Sendable {
    public let serviceCount: Int
    public let localPorts: [UUID: UInt16]

    public init(serviceCount: Int, localPorts: [UUID: UInt16]) {
        self.serviceCount = serviceCount
        self.localPorts = localPorts
    }
}

public final class BonjourBridge: @unchecked Sendable {
    private struct ActiveService {
        let relay: TCPRelay
        let registration: BonjourProxyRegistration
    }

    private var activeServices: [UUID: ActiveService] = [:]

    public init() {}

    @discardableResult
    public func start(profile: DeviceProfile) throws -> BridgeStartResult {
        guard profile.isValid else { throw BridgeError.invalidProfile }
        stop()

        let hostName = "DeviceHarbor-\(UUID().uuidString).local."
        var started: [UUID: ActiveService] = [:]
        var localPorts: [UUID: UInt16] = [:]
        do {
            for service in profile.services {
                let relay = TCPRelay(service: service)
                let localPort = try relay.start()
                let command = BonjourProxyCommand.make(
                    instanceName: service.instanceName,
                    serviceType: service.serviceType,
                    domain: service.domain,
                    localPort: localPort,
                    hostName: hostName,
                    localAddress: profile.advertisedAddress,
                    textRecords: service.textRecords
                )
                let registration = try BonjourProxyRegistration(command: command)
                started[service.id] = ActiveService(relay: relay, registration: registration)
                localPorts[service.id] = localPort
            }
        } catch {
            started.values.forEach {
                $0.registration.stop()
                $0.relay.stop()
            }
            throw error
        }

        activeServices = started
        return BridgeStartResult(serviceCount: started.count, localPorts: localPorts)
    }

    public func stop() {
        activeServices.values.forEach {
            $0.registration.stop()
            $0.relay.stop()
        }
        activeServices.removeAll()
    }

    public var isRunning: Bool { !activeServices.isEmpty }

    deinit {
        stop()
    }
}
