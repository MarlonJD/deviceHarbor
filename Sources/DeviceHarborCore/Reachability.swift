import Foundation
import Network

public enum TCPReachabilityOutcome: Sendable {
    case reachable
    case failed(String)
}

public struct TCPReachabilityTester: @unchecked Sendable {
    public init() {}

    public func test(address: String, port: UInt16, timeout: TimeInterval = 3) -> TCPReachabilityOutcome {
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed("Enter a private address first.")
        }
        guard let endpointPort = NWEndpoint.Port(rawValue: port), port > 0 else {
            return .failed("Enter a valid service port first.")
        }

        let connection = NWConnection(host: NWEndpoint.Host(address), port: endpointPort, using: .tcp)
        let state = ProbeState()
        connection.stateUpdateHandler = { newState in
            switch newState {
            case .ready:
                state.finish(.reachable)
            case .failed(let error):
                state.finish(.failed(error.localizedDescription))
            case .cancelled:
                state.finish(.failed("Connection cancelled."))
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue.global(qos: .utility))
        if state.semaphore.wait(timeout: .now() + timeout) == .timedOut {
            connection.cancel()
            return .failed("Timed out reaching \(address):\(port). Check the private route.")
        }
        connection.cancel()
        return state.outcome ?? .failed("No reachability result was produced.")
    }
}

private final class ProbeState: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedOutcome: TCPReachabilityOutcome?

    var outcome: TCPReachabilityOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return storedOutcome
    }

    func finish(_ outcome: TCPReachabilityOutcome) {
        lock.lock()
        guard storedOutcome == nil else {
            lock.unlock()
            return
        }
        storedOutcome = outcome
        lock.unlock()
        semaphore.signal()
    }
}
