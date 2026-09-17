import Foundation

public struct CommandSpec: Hashable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String] = []) {
        self.executable = executable
        self.arguments = arguments
    }

    public var displayCommand: String {
        ([executable] + arguments).map(Self.shellQuote).joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        if value.range(of: "[^A-Za-z0-9_./:-]", options: .regularExpression) == nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public struct CommandResult: Hashable, Sendable {
    public let exitCode: Int32
    public let output: String

    public init(exitCode: Int32, output: String) {
        self.exitCode = exitCode
        self.output = output
    }

    public var succeeded: Bool { exitCode == 0 }
}

public enum CommandRunnerError: LocalizedError, Sendable {
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let message): message
        }
    }
}

public protocol CommandRunning: Sendable {
    func run(_ command: CommandSpec) throws -> CommandResult
}

public struct ProcessCommandRunner: CommandRunning, Sendable {
    public init() {}

    public func run(_ command: CommandSpec) throws -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw CommandRunnerError.launchFailed(
                "Could not launch \(command.executable): \(error.localizedDescription)"
            )
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        return CommandResult(exitCode: process.terminationStatus, output: output)
    }
}
