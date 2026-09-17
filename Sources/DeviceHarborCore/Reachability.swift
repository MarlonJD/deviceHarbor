import Foundation

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
        guard port > 0 else {
            return .failed("Enter a valid service port first.")
        }

        let timeoutSeconds = max(1, Int(timeout.rounded(.up)))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = [
            "-v",
            "-z",
            "-G", String(timeoutSeconds),
            "-w", String(timeoutSeconds),
            address,
            String(port)
        ]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failed("Could not start the TCP probe: \(error.localizedDescription)")
        }

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            let lowercased = detail.lowercased()
            if lowercased.contains("connection refused") {
                return .failed(
                    "Connection refused at \(address):\(port). The host is reachable, but this CoreDevice service is not listening there."
                )
            }
            if lowercased.contains("timed out") || lowercased.contains("timeout") {
                return .failed(
                    "Timed out reaching \(address):\(port). Check the private route and whether the service is exposed."
                )
            }
            if lowercased.contains("no route") || lowercased.contains("network is unreachable") {
                return .failed("No route to \(address):\(port). Check the private network connection.")
            }
            if !detail.isEmpty {
                return .failed("Could not reach \(address):\(port): \(detail)")
            }
            return .failed("Could not reach \(address):\(port).")
        }

        return .reachable
    }
}
