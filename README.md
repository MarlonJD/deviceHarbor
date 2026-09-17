# DeviceHarbor

DeviceHarbor is an open-source macOS developer tool and iPhone companion for
carrying an Xcode 27 device session across a private DeviceHarbor transport.
The first supported matrix is macOS 27, Xcode 27, iOS 27, and watchOS 27.

The Mac app remains the Xcode/CoreDevice host. It captures the verified
Bonjour records published by a physical device, re-advertises those records
locally, and proxies each dynamic TCP service through the paired iPhone
companion. The iPhone companion keeps the transport outbound, so the phone
does not need to accept an unsolicited public connection.

## Current increment

This repository currently contains:

- a native SwiftUI macOS menu bar app;
- a typed `devicectl` adapter for listing, pairing, installing, and launching;
- physical-device filtering so simulator records are not shown as targets;
- verified Xcode 27 Bonjour capture for `_remotepairing._tcp`, `_remoted._tcp`,
  and `_apple-mobdev2._tcp`;
- a local Bonjour proxy publisher and a TCP relay backed by a companion stream;
- a shared newline-delimited JSON transport protocol;
- a six-digit local pairing flow between the Mac app and iPhone companion;
- an iOS 27 companion app with Bonjour discovery and reverse stream handling;
- a Network Extension target that is currently a configuration and lifecycle
  skeleton, not a finished packet tunnel;
- a small DeviceHarbor-owned rendezvous relay executable for development;
- iOS/watchOS CoreDevice and Watch-pairing models and deterministic tests.

The companion path is still candidate-only. The current slice proves the
local discovery, pairing, framing, and prototype relay contracts. The relay is
not yet deployed as a production service, and the path has not been certified
against a physical iPhone 17 running iOS 27.

## Build

Requirements: macOS 27, Xcode 27, and Swift 6.4.

```sh
xcrun swift build
xcrun swift test
```

Build the iPhone companion project without signing for a simulator compile
check:

```sh
xcodebuild -project Companion/DeviceHarborCompanion.xcodeproj \
  -scheme DeviceHarborCompanion \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

Run the development relay locally or on a private test host:

```sh
xcrun swift run DeviceHarborRelay 49153
```

For a physical iPhone, open
`Companion/DeviceHarborCompanion.xcodeproj`, select the user’s development
team for both targets, and install the app from Xcode. The Network Extension
requires the matching entitlement and explicit user approval.

## Local pairing test

1. Keep the Mac DeviceHarbor app running. It advertises `_deviceharbor._tcp`
   and shows a six-digit pairing code in the transport bar.
2. Install the iPhone companion while the Mac and iPhone are on the same
   local network. Allow Local Network access when iOS asks.
3. Select the Mac in the companion, enter the displayed code, and tap `Pair
   with Mac`.
4. In the Mac app, select the physical iPhone, capture the Xcode Bonjour
   records while the normal USB or same-Wi-Fi Apple path is working, and save
   the profile.
5. Start the bridge only after the Mac status says that the iPhone companion
   is paired. Each local Xcode connection then opens a reverse stream request
   to the iPhone companion.

The first Apple trust and wireless-debug setup still belongs to Apple’s
pairing flow: use USB or the same Wi-Fi first, enable Developer Mode, and
confirm that Xcode can see the physical device. A charging puck is power, not
a direct Watch USB data transport. A Watch is reached through its paired
iPhone and the Xcode CoreDevice graph.

## Transport roadmap

The intended remote flow is:

```text
iPhone DeviceHarbor companion
        ⇅ outbound authenticated session
DeviceHarbor rendezvous / relay (per-user room)
        ⇅ outbound authenticated session
Mac DeviceHarbor
        ⇅ local Bonjour proxy + TCP relay
Xcode / devicectl / CoreDevice
```

The first local slice uses direct Bonjour discovery. The prototype relay can
also accept outbound Mac and iPhone sessions for a different-network test:
enter the relay host and port in both companion UIs, use the Mac’s displayed
six-digit code on the iPhone, and connect both sides. The next transport
increment is production per-user keys, reconnects, keepalives, and NAT
traversal. A temporary tunnel may bootstrap that service during development,
but a generic HTTP tunnel is not the CoreDevice data plane.

The iOS Network Extension is deliberately kept separate from the companion
control session. Apple’s [Packet Tunnel guidance](https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers) says a packet tunnel is for routing packets through a tunnel server, not for hosting a general-purpose inbound listener or proxy. The production design must therefore keep the iPhone session outbound and use the extension only where the approved entitlement and transport require it.

## Security boundary

The current pairing code is a development bootstrap mechanism. The transport
does not yet claim production confidentiality or mutual authentication. Before
release, DeviceHarbor must add per-user key material in Keychain, authenticated
handshake and replay protection, encrypted relay traffic, explicit peer
revocation, and bounded stream/resource limits.

DeviceHarbor is not affiliated with Apple. Xcode, iPhone, Apple Watch, and
related marks belong to Apple Inc.
