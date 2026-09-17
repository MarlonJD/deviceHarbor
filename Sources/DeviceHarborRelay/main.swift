import DeviceHarborTransport
import Foundation

let requestedPort = CommandLine.arguments.dropFirst().first.flatMap(UInt16.init) ?? 49_153

do {
    let server = try DeviceHarborRelayServer(port: requestedPort)
    try server.start()
    print("DeviceHarbor relay listening on TCP port \(requestedPort).")
    dispatchMain()
} catch {
    fputs("Unable to start DeviceHarbor relay: \(error.localizedDescription)\n", stderr)
    exit(1)
}
