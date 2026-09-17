import Foundation
import XCTest
@testable import DeviceHarborCore

final class DeviceHarborCoreTests: XCTestCase {
    func testParsesCurrentDeviceCtlShapeForPhoneAndWatch() throws {
        let data = Data(
            """
            {
              "result": {
                "devices": [
                  {
                    "identifier": "PHONE-UDID",
                    "properties": {
                      "connection": {
                        "pairingState": "paired",
                        "state": "unavailable"
                      },
                      "hardware": {
                        "deviceType": "iPhone",
                        "marketingName": "iPhone 17",
                        "platform": "iOS",
                        "reality": "physical",
                        "udid": "PHONE-UDID"
                      },
                      "software": {
                        "osVersionNumber": {
                          "stringValue": "27.0"
                        }
                      },
                      "state": {
                        "developerModeStatus": {
                          "enabled": {
                            "mode": 1
                          }
                        },
                        "name": "iPhone 17 Pro"
                      }
                    },
                    "hardwareProperties": {
                      "productType": "iPhone18,1",
                      "platform": "iOS",
                      "reality": "physical"
                    },
                    "deviceProperties": {
                      "name": "iPhone 17 Pro",
                      "osVersionNumber": "27.0"
                    },
                    "connectionProperties": {
                      "pairingState": "paired",
                      "tunnelState": "unavailable",
                      "transportType": "localNetwork"
                    }
                  },
                  {
                    "identifier": "WATCH-UDID",
                    "hardwareProperties": {
                      "productType": "Watch7,1",
                      "platform": "watchOS",
                      "reality": "physical"
                    },
                    "deviceProperties": {
                      "name": "Apple Watch",
                      "osVersionNumber": "27.0"
                    },
                    "connectionProperties": {
                      "pairingState": "paired",
                      "tunnelState": "connected",
                      "transportType": "localNetwork"
                    }
                  }
                ]
              }
            }
            """.utf8
        )

        let devices = try DeviceCtlJSONParser.parse(data)

        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].platformKind, .iOS)
        XCTAssertEqual(devices[0].operatingSystem, "27.0")
        XCTAssertEqual(devices[0].model, "iPhone 17")
        XCTAssertEqual(devices[0].udid, "PHONE-UDID")
        XCTAssertEqual(devices[0].connectionState, "unavailable")
        XCTAssertEqual(devices[0].developerModeStatus, "enabled")
        XCTAssertEqual(devices[0].connectivityAdvice, "Paired, but no CoreDevice tunnel is reachable. Connect the phone over USB or the configured private network.")
        XCTAssertEqual(devices[1].platformKind, .watchOS)
        XCTAssertEqual(devices[1].name, "Apple Watch")
    }

    func testParsesEmptyDeviceList() throws {
        let data = Data(#"{"result":{"devices":[]}}"#.utf8)
        XCTAssertEqual(try DeviceCtlJSONParser.parse(data), [])
    }

    func testBuildsVersionedDeviceCtlCommandsWithoutShellInterpolation() {
        let list = DeviceCtlClient.listDevicesCommand(outputPath: "/tmp/devices.json", timeoutSeconds: 8)
        XCTAssertEqual(list.executable, "/usr/bin/xcrun")
        XCTAssertEqual(
            list.arguments,
            ["devicectl", "--timeout", "8", "list", "devices", "--json-output", "/tmp/devices.json", "--quiet"]
        )

        let install = DeviceCtlClient.installCommand(
            deviceIdentifier: "PHONE-UDID",
            applicationPath: "/tmp/My App.app",
            timeoutSeconds: 120
        )
        XCTAssertEqual(install.arguments.suffix(5), ["install", "app", "--device", "PHONE-UDID", "/tmp/My App.app"])
        XCTAssertFalse(install.displayCommand.contains("My App.app;"))

        let pairing = DeviceCtlClient.createWatchPairingCommand(
            phoneIdentifier: "PHONE-CORE-ID",
            watchIdentifier: "WATCH-CORE-ID"
        )
        XCTAssertEqual(pairing.arguments.suffix(5), ["pair", "--phone", "PHONE-CORE-ID", "--watch", "WATCH-CORE-ID"])
    }

    func testBuildsBonjourProxyCommandWithStableTxtOrder() {
        let command = BonjourProxyCommand.make(
            instanceName: "iPhone",
            serviceType: "_remotepairing._tcp",
            domain: "local.",
            localPort: 55001,
            hostName: "DeviceHarbor.local.",
            localAddress: "127.0.0.1",
            textRecords: ["udid": "PHONE-UDID", "platform": "iOS"]
        )

        XCTAssertEqual(command.executable, "/usr/bin/dns-sd")
        XCTAssertEqual(command.arguments.prefix(7), [
            "-P", "iPhone", "_remotepairing._tcp", "local.", "55001", "DeviceHarbor.local.", "127.0.0.1"
        ])
        XCTAssertEqual(command.arguments.suffix(2), ["platform=iOS", "udid=PHONE-UDID"])
    }

    func testParsesBonjourZoneServiceAndEscapedInstanceName() {
        let zone = """
        ; dns-sd -Z output is a DNS-SD zone snapshot
        Burak\\032iPhoneu._remotepairing._tcp SRV 0 0 49152 Burak-iPhoneu.local.
        Burak\\032iPhoneu._remotepairing._tcp TXT "platform=iOS" "udid=PHONE-UDID" "paired"
        """

        let services = BonjourZoneParser.parse(
            zone,
            serviceType: "_remotepairing._tcp",
            domain: "local."
        )

        XCTAssertEqual(services.count, 1)
        XCTAssertEqual(services[0].instanceName, "Burak iPhoneu")
        XCTAssertEqual(services[0].remoteHost, "Burak-iPhoneu.local.")
        XCTAssertEqual(services[0].remotePort, 49152)
        XCTAssertEqual(services[0].textRecords["platform"], "iOS")
        XCTAssertEqual(services[0].textRecords["paired"], "")
    }

    func testParsesWatchPairingJSON() throws {
        let data = Data(
            #"{"result":{"pairings":[{"identifier":"PAIR-1","phone":{"identifier":"PHONE-1","name":"iPhone 17"},"watch":{"identifier":"WATCH-1","name":"Apple Watch"},"active":true}]}}"#.utf8
        )

        let pairings = try DevicePairingJSONParser.parse(data)

        XCTAssertEqual(pairings.count, 1)
        XCTAssertEqual(pairings[0].phoneIdentifier, "PHONE-1")
        XCTAssertEqual(pairings[0].watchIdentifier, "WATCH-1")
        XCTAssertEqual(pairings[0].watchName, "Apple Watch")
        XCTAssertEqual(pairings[0].active, true)
    }

    func testParsesTailscaleStatusPeers() throws {
        let output = #"{"Self":{"HostName":"mac","DNSName":"mac.tailnet.ts.net.","TailscaleIPs":["100.64.0.2"],"Online":true},"Peer":{"key":{"HostName":"Burak-iPhoneu","DNSName":"burak-iphoneu.tailnet.ts.net.","TailscaleIPs":["100.64.0.10"],"Online":true}}}"#
        let peers = try TailscaleStatusParser.parse(output)

        XCTAssertEqual(peers.count, 2)
        XCTAssertEqual(peers[1].addresses, ["100.64.0.10"])
        XCTAssertTrue(peers[1].online)
    }

    func testReachabilityRejectsMissingAddressAndPortWithoutOpeningAConnection() {
        let tester = TCPReachabilityTester()

        if case .failed(let message) = tester.test(address: "", port: 49152) {
            XCTAssertTrue(message.contains("address"))
        } else {
            XCTFail("Expected empty address to be rejected")
        }

        if case .failed(let message) = tester.test(address: "127.0.0.1", port: 0) {
            XCTAssertTrue(message.contains("port"))
        } else {
            XCTFail("Expected zero port to be rejected")
        }
    }

    func testProfileRoundTripDoesNotAddCredentials() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deviceharbor-tests-\(UUID().uuidString)", isDirectory: true)
        let store = FileProfileStore(fileURL: directory.appendingPathComponent("profiles.json"))
        let profile = DeviceProfile(
            displayName: "Test iPhone",
            deviceIdentifier: "PHONE-UDID",
            platform: .iOS,
            meshProvider: .tailscale,
            advertisedAddress: "127.0.0.1",
            services: [
                RelayService(
                    instanceName: "iPhone",
                    serviceType: "_remotepairing._tcp",
                    remoteAddress: "100.64.0.10",
                    remotePort: 49152
                )
            ]
        )

        try store.save([profile])
        let loaded = try store.load()
        XCTAssertEqual(loaded, [profile])
        XCTAssertFalse(String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self).contains("secret"))

        try FileManager.default.removeItem(at: directory)
    }
}
