import Foundation

public enum DeviceCtlError: LocalizedError, Sendable {
    case commandFailed(String)
    case invalidJSON(String)
    case missingApplication(URL)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let message): message
        case .invalidJSON(let message): "Invalid devicectl JSON: \(message)"
        case .missingApplication(let url): "Application bundle does not exist: \(url.path)"
        }
    }
}

public struct DeviceCtlClient: @unchecked Sendable {
    public static let xcrunPath = "/usr/bin/xcrun"

    private let runner: any CommandRunning
    private let fileManager: FileManager

    public init(
        runner: any CommandRunning = ProcessCommandRunner(),
        fileManager: FileManager = .default
    ) {
        self.runner = runner
        self.fileManager = fileManager
    }

    public func listDevices(timeoutSeconds: Int = 8) throws -> [CoreDevice] {
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("deviceharbor-devices-\(UUID().uuidString).json")
        defer { try? fileManager.removeItem(at: outputURL) }

        let command = Self.listDevicesCommand(outputPath: outputURL.path, timeoutSeconds: timeoutSeconds)
        let result = try runner.run(command)
        guard result.succeeded else {
            throw DeviceCtlError.commandFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        do {
            let data = try Data(contentsOf: outputURL)
            return try DeviceCtlJSONParser.parse(data)
        } catch let error as DeviceCtlError {
            throw error
        } catch {
            throw DeviceCtlError.invalidJSON(error.localizedDescription)
        }
    }

    public func pair(deviceIdentifier: String, timeoutSeconds: Int = 30) throws {
        let result = try runner.run(Self.pairCommand(deviceIdentifier: deviceIdentifier, timeoutSeconds: timeoutSeconds))
        guard result.succeeded else {
            throw DeviceCtlError.commandFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public func installApp(at url: URL, on deviceIdentifier: String, timeoutSeconds: Int = 120) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw DeviceCtlError.missingApplication(url)
        }
        let result = try runner.run(
            Self.installCommand(deviceIdentifier: deviceIdentifier, applicationPath: url.path, timeoutSeconds: timeoutSeconds)
        )
        guard result.succeeded else {
            throw DeviceCtlError.commandFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public func launch(bundleIdentifier: String, on deviceIdentifier: String, timeoutSeconds: Int = 30) throws {
        let result = try runner.run(
            Self.launchCommand(deviceIdentifier: deviceIdentifier, bundleIdentifier: bundleIdentifier, timeoutSeconds: timeoutSeconds)
        )
        guard result.succeeded else {
            throw DeviceCtlError.commandFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public func listPairings(for phoneIdentifier: String, timeoutSeconds: Int = 8) throws -> [DevicePairing] {
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("deviceharbor-pairings-\(UUID().uuidString).json")
        defer { try? fileManager.removeItem(at: outputURL) }

        let command = Self.listPairingsCommand(
            phoneIdentifier: phoneIdentifier,
            outputPath: outputURL.path,
            timeoutSeconds: timeoutSeconds
        )
        let result = try runner.run(command)
        guard result.succeeded else {
            throw DeviceCtlError.commandFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        do {
            return try DevicePairingJSONParser.parse(Data(contentsOf: outputURL))
        } catch let error as DeviceCtlError {
            throw error
        } catch {
            throw DeviceCtlError.invalidJSON(error.localizedDescription)
        }
    }

    public static func listDevicesCommand(outputPath: String, timeoutSeconds: Int = 8) -> CommandSpec {
        CommandSpec(
            executable: xcrunPath,
            arguments: [
                "devicectl",
                "--timeout", String(timeoutSeconds),
                "list", "devices",
                "--json-output", outputPath,
                "--quiet"
            ]
        )
    }

    public static func pairCommand(deviceIdentifier: String, timeoutSeconds: Int = 30) -> CommandSpec {
        CommandSpec(
            executable: xcrunPath,
            arguments: [
                "devicectl",
                "--timeout", String(timeoutSeconds),
                "manage", "pair",
                "--device", deviceIdentifier
            ]
        )
    }

    public static func installCommand(
        deviceIdentifier: String,
        applicationPath: String,
        timeoutSeconds: Int = 120
    ) -> CommandSpec {
        CommandSpec(
            executable: xcrunPath,
            arguments: [
                "devicectl",
                "--timeout", String(timeoutSeconds),
                "device", "install", "app",
                "--device", deviceIdentifier,
                applicationPath
            ]
        )
    }

    public static func launchCommand(
        deviceIdentifier: String,
        bundleIdentifier: String,
        timeoutSeconds: Int = 30
    ) -> CommandSpec {
        CommandSpec(
            executable: xcrunPath,
            arguments: [
                "devicectl",
                "--timeout", String(timeoutSeconds),
                "device", "process", "launch",
                "--device", deviceIdentifier,
                "--terminate-existing",
                bundleIdentifier
            ]
        )
    }

    public static func listPairingsCommand(
        phoneIdentifier: String,
        outputPath: String,
        timeoutSeconds: Int = 8
    ) -> CommandSpec {
        CommandSpec(
            executable: xcrunPath,
            arguments: [
                "devicectl",
                "--timeout", String(timeoutSeconds),
                "device", "pairings", "list",
                "--device", phoneIdentifier,
                "--json-output", outputPath
            ]
        )
    }

    public static func createWatchPairingCommand(
        phoneIdentifier: String,
        watchIdentifier: String,
        timeoutSeconds: Int = 30
    ) -> CommandSpec {
        CommandSpec(
            executable: xcrunPath,
            arguments: [
                "devicectl",
                "--timeout", String(timeoutSeconds),
                "device", "pairings", "pair",
                "--phone", phoneIdentifier,
                "--watch", watchIdentifier
            ]
        )
    }

    public static func setActiveWatchPairingCommand(
        phoneIdentifier: String,
        watchIdentifier: String,
        timeoutSeconds: Int = 30
    ) -> CommandSpec {
        CommandSpec(
            executable: xcrunPath,
            arguments: [
                "devicectl",
                "--timeout", String(timeoutSeconds),
                "device", "pairings", "set-active",
                "--phone", phoneIdentifier,
                "--watch", watchIdentifier
            ]
        )
    }
}

public enum DeviceCtlJSONParser {
    public static func parse(_ data: Data) throws -> [CoreDevice] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw DeviceCtlError.invalidJSON(error.localizedDescription)
        }

        guard let root = object as? [String: Any] else {
            throw DeviceCtlError.invalidJSON("root is not an object")
        }
        guard let result = root["result"] as? [String: Any] else {
            if let error = root["error"] as? [String: Any], let description = findString(error, keys: ["string", "message"]) {
                throw DeviceCtlError.commandFailed(description)
            }
            throw DeviceCtlError.invalidJSON("missing result")
        }
        guard let rawDevices = result["devices"] as? [[String: Any]] else {
            return []
        }

        return rawDevices.compactMap(makeDevice)
    }

    private static func makeDevice(_ raw: [String: Any]) -> CoreDevice? {
        guard let identifier = findString(raw, keys: ["identifier", "udid"]), !identifier.isEmpty else {
            return nil
        }

        let name = findString(raw, paths: [
            ["deviceProperties", "name"],
            ["properties", "state", "name"],
            ["properties", "name"],
            ["name"]
        ]) ?? "Unnamed device"
        let model = findString(raw, paths: [
            ["properties", "hardware", "marketingName"],
            ["hardwareProperties", "productType"],
            ["hardwareProperties", "modelName"],
            ["properties", "hardware", "productType"],
            ["model"]
        ]) ?? "Unknown model"
        let udid = findString(raw, paths: [
            ["hardwareProperties", "udid"],
            ["properties", "hardware", "udid"]
        ]) ?? ""
        let deviceType = findString(raw, paths: [
            ["hardwareProperties", "deviceType"],
            ["properties", "hardware", "deviceType"]
        ]) ?? ""
        let platform = findString(raw, paths: [
            ["hardwareProperties", "platform"],
            ["properties", "hardware", "platform"],
            ["properties", "platform"],
            ["platform"]
        ]) ?? ""
        let operatingSystem = findString(raw, paths: [
            ["properties", "software", "osVersionNumber", "stringValue"],
            ["deviceProperties", "osVersionNumber"],
            ["properties", "osVersionNumber"],
            ["operatingSystemVersion"]
        ]) ?? ""
        let reality = findString(raw, paths: [
            ["hardwareProperties", "reality"],
            ["properties", "hardware", "reality"],
            ["reality"]
        ]) ?? "physical"
        let pairingState = findString(raw, paths: [
            ["connectionProperties", "pairingState"],
            ["properties", "connection", "pairingState"],
            ["pairingState"]
        ]) ?? ""
        let connectionState = findString(raw, paths: [
            ["properties", "connection", "state"],
            ["connectionProperties", "state"],
            ["state"]
        ]) ?? ""
        let tunnelState = findString(raw, paths: [
            ["connectionProperties", "tunnelState"],
            ["properties", "connection", "tunnelState"],
            ["tunnelState"]
        ]) ?? ""
        let transportType = findString(raw, paths: [
            ["connectionProperties", "transportType"],
            ["properties", "connection", "transportType"],
            ["transportType"]
        ]) ?? ""
        let developerModeStatus = findString(raw, paths: [
            ["deviceProperties", "developerModeStatus"],
            ["properties", "state", "developerModeStatus"]
        ]) ?? (dictionaryContainsKey(raw, path: ["properties", "state", "developerModeStatus", "enabled"]) ? "enabled" : "")
        let ddiServicesAvailable = findBool(raw, paths: [
            ["deviceProperties", "ddiServicesAvailable"],
            ["properties", "ddiServicesAvailable"]
        ])
        let potentialHostnames = findStrings(raw, paths: [
            ["connectionProperties", "potentialHostnames"],
            ["properties", "connection", "potentialHostnames"]
        ])

        return CoreDevice(
            identifier: identifier,
            udid: udid,
            name: name,
            model: model,
            deviceType: deviceType,
            platform: platform,
            operatingSystem: operatingSystem,
            reality: reality,
            pairingState: pairingState,
            connectionState: connectionState,
            tunnelState: tunnelState,
            transportType: transportType,
            developerModeStatus: developerModeStatus,
            ddiServicesAvailable: ddiServicesAvailable,
            potentialHostnames: potentialHostnames
        )
    }

    private static func findString(_ dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String { return value }
        }
        return nil
    }

    private static func findString(_ dictionary: [String: Any], paths: [[String]]) -> String? {
        for path in paths {
            var current: Any = dictionary
            var found = true
            for key in path {
                guard let object = current as? [String: Any], let next = object[key] else {
                    found = false
                    break
                }
                current = next
            }
            if found, let value = current as? String { return value }
        }
        return nil
    }

    private static func findBool(_ dictionary: [String: Any], paths: [[String]]) -> Bool? {
        for path in paths {
            var current: Any = dictionary
            var found = true
            for key in path {
                guard let object = current as? [String: Any], let next = object[key] else {
                    found = false
                    break
                }
                current = next
            }
            if found, let value = current as? Bool { return value }
        }
        return nil
    }

    private static func findStrings(_ dictionary: [String: Any], paths: [[String]]) -> [String] {
        for path in paths {
            var current: Any = dictionary
            var found = true
            for key in path {
                guard let object = current as? [String: Any], let next = object[key] else {
                    found = false
                    break
                }
                current = next
            }
            if found, let values = current as? [String] { return values }
        }
        return []
    }

    private static func dictionaryContainsKey(_ dictionary: [String: Any], path: [String]) -> Bool {
        var current: Any = dictionary
        for key in path {
            guard let object = current as? [String: Any], let next = object[key] else { return false }
            current = next
        }
        return true
    }
}

public enum DevicePairingJSONParser {
    public static func parse(_ data: Data) throws -> [DevicePairing] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw DeviceCtlError.invalidJSON(error.localizedDescription)
        }
        guard let root = object as? [String: Any],
              let result = root["result"] as? [String: Any] else {
            throw DeviceCtlError.invalidJSON("missing result")
        }
        guard let rawPairings = result["pairings"] as? [[String: Any]] else { return [] }

        return rawPairings.compactMap { raw in
            let phone = firstString(raw, paths: [
                ["phoneIdentifier"], ["phone", "identifier"], ["phone", "udid"], ["phoneID"]
            ])
            let watch = firstString(raw, paths: [
                ["watchIdentifier"], ["watch", "identifier"], ["watch", "udid"], ["watchID"]
            ])
            guard let phone, let watch, !phone.isEmpty, !watch.isEmpty else { return nil }
            let id = firstString(raw, paths: [["identifier"], ["id"]])
            let active = firstBool(raw, paths: [["active"], ["isActive"]])
            let phoneName = firstString(raw, paths: [["phone", "name"], ["phoneName"]]) ?? ""
            let watchName = firstString(raw, paths: [["watch", "name"], ["watchName"]]) ?? ""
            return DevicePairing(
                id: id,
                phoneIdentifier: phone,
                watchIdentifier: watch,
                active: active,
                phoneName: phoneName,
                watchName: watchName
            )
        }
    }

    private static func firstString(_ dictionary: [String: Any], paths: [[String]]) -> String? {
        for path in paths {
            var current: Any = dictionary
            var found = true
            for key in path {
                guard let object = current as? [String: Any], let next = object[key] else {
                    found = false
                    break
                }
                current = next
            }
            if found, let value = current as? String { return value }
        }
        return nil
    }

    private static func firstBool(_ dictionary: [String: Any], paths: [[String]]) -> Bool? {
        for path in paths {
            var current: Any = dictionary
            var found = true
            for key in path {
                guard let object = current as? [String: Any], let next = object[key] else {
                    found = false
                    break
                }
                current = next
            }
            if found, let value = current as? Bool { return value }
        }
        return nil
    }
}
