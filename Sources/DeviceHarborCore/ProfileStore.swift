import Foundation

public enum ProfileStoreError: LocalizedError, Sendable {
    case invalidData(String)
    case unableToCreateDirectory(String)

    public var errorDescription: String? {
        switch self {
        case .invalidData(let message): "Could not read DeviceHarbor profiles: \(message)"
        case .unableToCreateDirectory(let message): "Could not prepare DeviceHarbor storage: \(message)"
        }
    }
}

public protocol ProfileStoring: Sendable {
    func load() throws -> [DeviceProfile]
    func save(_ profiles: [DeviceProfile]) throws
}

public struct FileProfileStore: ProfileStoring, Sendable {
    public let fileURL: URL

    public init(fileURL: URL = FileProfileStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DeviceHarbor", isDirectory: true)
            .appendingPathComponent("profiles.json")
    }

    public func load() throws -> [DeviceProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([DeviceProfile].self, from: data)
        } catch {
            throw ProfileStoreError.invalidData(error.localizedDescription)
        }
    }

    public func save(_ profiles: [DeviceProfile]) throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder.prettyPrinted.encode(profiles)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            if !FileManager.default.fileExists(atPath: directory.path) {
                throw ProfileStoreError.unableToCreateDirectory(error.localizedDescription)
            }
            throw ProfileStoreError.invalidData(error.localizedDescription)
        }
    }
}

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
