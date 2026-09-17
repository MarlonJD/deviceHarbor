import Foundation

public struct CapturedBonjourService: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let instanceName: String
    public let serviceType: String
    public let domain: String
    public let remoteHost: String
    public let remotePort: UInt16
    public let textRecords: [String: String]

    public init(
        id: UUID = UUID(),
        instanceName: String,
        serviceType: String,
        domain: String,
        remoteHost: String,
        remotePort: UInt16,
        textRecords: [String: String] = [:]
    ) {
        self.id = id
        self.instanceName = instanceName
        self.serviceType = serviceType
        self.domain = domain
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.textRecords = textRecords
    }

    public func makeRelayService(remoteAddress: String) -> RelayService {
        RelayService(
            instanceName: instanceName,
            serviceType: serviceType,
            domain: domain,
            remoteAddress: remoteAddress,
            remotePort: remotePort,
            textRecords: textRecords
        )
    }
}

public enum BonjourServiceFamilies {
    public static let xcode27 = [
        "_remotepairing._tcp",
        "_remoted._tcp",
        "_apple-mobdev2._tcp"
    ]
}

public enum BonjourZoneParser {
    private struct PartialService {
        var instanceName: String
        var serviceType: String
        var domain: String
        var remoteHost: String?
        var remotePort: UInt16?
        var textRecords: [String: String] = [:]
    }

    public static func parse(
        _ zone: String,
        serviceType: String,
        domain: String = "local."
    ) -> [CapturedBonjourService] {
        let normalizedDomain = domain.hasSuffix(".") ? domain : domain + "."
        let suffix = ".\(serviceType).\(normalizedDomain)"
        var partials: [String: PartialService] = [:]

        for rawLine in zone.split(whereSeparator: { $0.isNewline }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix(";") else { continue }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let nameToken = tokens.first else { continue }
            let name = nameToken.hasSuffix(".") ? nameToken : nameToken + "."
            let shortSuffix = ".\(serviceType)."
            let lowerName = name.lowercased()
            let lowerLongSuffix = suffix.lowercased()
            let lowerShortSuffix = shortSuffix.lowercased()
            let matchedSuffix: String
            if lowerName.hasSuffix(lowerLongSuffix) {
                matchedSuffix = suffix
            } else if lowerName.hasSuffix(lowerShortSuffix) {
                matchedSuffix = shortSuffix
            } else {
                continue
            }
            let key = name.lowercased()
            let instance = decodeZoneName(String(name.dropLast(matchedSuffix.count)))
            var partial = partials[key] ?? PartialService(
                instanceName: instance,
                serviceType: serviceType,
                domain: normalizedDomain
            )

            if let index = tokens.firstIndex(where: { $0.uppercased() == "SRV" }), tokens.count > index + 4,
               let port = UInt16(tokens[index + 3]) {
                partial.remotePort = port
                partial.remoteHost = decodeZoneName(tokens[index + 4])
            } else if let index = tokens.firstIndex(where: { $0.uppercased() == "TXT" }) {
                let text = tokens[(index + 1)...].joined(separator: " ")
                for record in parseTextRecords(text) {
                    partial.textRecords[record.key] = record.value
                }
            }
            partials[key] = partial
        }

        return partials.values
            .compactMap { partial in
                guard let host = partial.remoteHost, let port = partial.remotePort, port > 0 else { return nil }
                return CapturedBonjourService(
                    instanceName: partial.instanceName,
                    serviceType: partial.serviceType,
                    domain: partial.domain,
                    remoteHost: host,
                    remotePort: port,
                    textRecords: partial.textRecords
                )
            }
            .sorted { $0.instanceName.localizedStandardCompare($1.instanceName) == .orderedAscending }
    }

    private static func parseTextRecords(_ text: String) -> [(key: String, value: String)] {
        let regex = try? NSRegularExpression(pattern: #""((?:\\.|[^"\\])*)"|([^\s]+)"#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex?.matches(in: text, range: range) ?? []
        return matches.compactMap { match in
            let quotedRange = match.range(at: 1)
            let bareRange = match.range(at: 2)
            let value: String
            if quotedRange.location != NSNotFound, let swiftRange = Range(quotedRange, in: text) {
                value = decodeZoneName(String(text[swiftRange]))
            } else if bareRange.location != NSNotFound, let swiftRange = Range(bareRange, in: text) {
                value = decodeZoneName(String(text[swiftRange]))
            } else {
                return nil
            }
            let pieces = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(pieces[0])
            let recordValue = pieces.count == 2 ? String(pieces[1]) : ""
            guard !key.isEmpty else { return nil }
            return (key, recordValue)
        }
    }

    private static func decodeZoneName(_ value: String) -> String {
        var result = ""
        var index = value.startIndex
        while index < value.endIndex {
            guard value[index] == "\\" else {
                result.append(value[index])
                index = value.index(after: index)
                continue
            }
            let next = value.index(after: index)
            guard next < value.endIndex else {
                result.append("\\")
                break
            }
            let remaining = value[next...]
            if remaining.count >= 3 {
                let digits = String(remaining.prefix(3))
                if let code = Int(digits), let scalar = UnicodeScalar(code) {
                    result.append(Character(scalar))
                    index = value.index(next, offsetBy: 3)
                    continue
                }
            }
            result.append(value[next])
            index = value.index(after: next)
        }
        return result
    }
}

public enum BonjourCaptureError: LocalizedError, Sendable {
    case launchFailed(String)
    case timedOut
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let message): "Could not start dns-sd: \(message)"
        case .timedOut: "dns-sd capture timed out"
        case .commandFailed(let message): "dns-sd capture failed: \(message)"
        }
    }
}

public struct BonjourCapture {
    public let executablePath: String

    public init(executablePath: String = "/usr/bin/dns-sd") {
        self.executablePath = executablePath
    }

    public func capture(
        serviceType: String,
        domain: String = "local.",
        matching: String? = nil,
        duration: TimeInterval = 3
    ) throws -> [CapturedBonjourService] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["-t", String(max(1, Int(ceil(duration)))), "-Z", serviceType, domain]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw BonjourCaptureError.launchFailed(error.localizedDescription)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 || !output.isEmpty else {
            throw BonjourCaptureError.commandFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let services = BonjourZoneParser.parse(output, serviceType: serviceType, domain: domain)
        guard let matching else { return services }
        return services.filter {
            $0.instanceName.localizedCaseInsensitiveContains(matching)
                || $0.remoteHost.localizedCaseInsensitiveContains(matching)
        }
    }
}
