import DeviceHarborTransport
import Foundation

struct DeviceHarborEphemeralRelayProvisioner: Sendable {
    enum ProvisioningError: LocalizedError, Sendable {
        case workerDirectoryMissing(URL)
        case npxUnavailable
        case processFailed(String)
        case endpointNotFound(String)

        var errorDescription: String? {
            switch self {
            case .workerDirectoryMissing(let url):
                return "The DeviceHarbor relay Worker source was not found at \(url.path)."
            case .npxUnavailable:
                return "DeviceHarbor could not find npx. Install Node.js/Wrangler or set DEVICEHARBOR_NPX_PATH."
            case .processFailed(let output):
                return "The temporary DeviceHarbor relay Worker could not be created: \(output)"
            case .endpointNotFound(let output):
                return "The temporary relay Worker was created, but its public endpoint was not found in the output: \(output)"
            }
        }
    }

    private let workerDirectory: URL

    init(workerDirectory: URL? = nil) {
        if let workerDirectory {
            self.workerDirectory = workerDirectory
        } else if let configuredPath = ProcessInfo.processInfo.environment["DEVICEHARBOR_RELAY_WORKER_DIR"],
                  !configuredPath.isEmpty {
            self.workerDirectory = URL(fileURLWithPath: configuredPath, isDirectory: true)
        } else {
            self.workerDirectory = Self.defaultWorkerDirectory
        }
    }

    func provision(pairingCode: String) throws -> DeviceHarborRelayOffer {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: workerDirectory.appendingPathComponent("wrangler.jsonc").path) else {
            throw ProvisioningError.workerDirectoryMissing(workerDirectory)
        }
        guard let npx = Self.npxURL(fileManager: fileManager) else {
            throw ProvisioningError.npxUnavailable
        }

        let workerName = "deviceharbor-\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16))"
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = npx
        process.arguments = [
            "wrangler",
            "deploy",
            "--temporary",
            "--minify",
            "--name",
            workerName
        ]
        process.currentDirectoryURL = workerDirectory
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            throw ProvisioningError.processFailed(error.localizedDescription)
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: outputData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw ProvisioningError.processFailed(Self.sanitizedDiagnostic(output))
        }

        guard let endpoint = Self.extractWorkerEndpoint(from: output) else {
            throw ProvisioningError.endpointNotFound(Self.sanitizedDiagnostic(output))
        }

        let roomID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let accessToken = "\(UUID().uuidString)\(UUID().uuidString)"
        let expiresAt = Int64(Date().timeIntervalSince1970 * 1000) + 60 * 60 * 1000
        let session = DeviceHarborHostedRelaySession(
            roomID: roomID,
            accessToken: accessToken,
            expiresAt: expiresAt
        )
        return DeviceHarborRelayOffer(
            baseURL: endpoint,
            pairingCode: pairingCode,
            session: session
        )
    }

    private static var defaultWorkerDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Infrastructure/relay-worker", isDirectory: true)
    }

    private static func npxURL(fileManager: FileManager) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let pathCandidates = environment["PATH"]?
            .split(separator: ":")
            .map { String($0) }
            .map { "\($0)/npx" } ?? []
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let nvmDirectory = homeDirectory.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        let nvmCandidates = (try? fileManager.contentsOfDirectory(
            at: nvmDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { $0.appendingPathComponent("bin/npx").path } ?? []
        let candidates = [
            environment["DEVICEHARBOR_NPX_PATH"],
            environment["NVM_BIN"].map { "\($0)/npx" },
            environment["VOLTA_HOME"].map { "\($0)/bin/npx" },
            homeDirectory.appendingPathComponent(".volta/bin/npx").path,
            "/opt/homebrew/bin/npx",
            "/usr/local/bin/npx",
            "/usr/bin/npx"
        ]
        .compactMap { $0 } + pathCandidates + nvmCandidates
        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func extractWorkerEndpoint(from output: String) -> URL? {
        let pattern = #"https://[A-Za-z0-9.-]+\.workers\.dev"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: output,
                range: NSRange(location: 0, length: output.utf16.count)
              ),
              let range = Range(match.range, in: output) else {
            return nil
        }
        return URL(string: String(output[range]))
    }

    private static func sanitizedDiagnostic(_ output: String) -> String {
        output.replacingOccurrences(
            of: #"https://dash\.cloudflare\.com/claim\?claimToken=[^\s]+"#,
            with: "[Cloudflare claim URL omitted]",
            options: .regularExpression
        )
    }
}
