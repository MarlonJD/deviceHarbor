# DeviceHarbor

DeviceHarbor is an open-source macOS developer tool for keeping Xcode device
connectivity usable across a private network. The first supported matrix is
macOS 27, Xcode 27, iOS 27, and watchOS 27.

The project is intentionally separate from application code. It does not
replace Xcode, Apple signing, Developer Mode, or the device trust relationship.
It builds on the current Xcode 27 `devicectl` surface and publishes local
Bonjour proxy records while relaying TCP traffic to a paired device address on
a private network such as Tailscale.

## Current status

The current increment provides:

- a native SwiftUI macOS menu bar app;
- a typed `devicectl` adapter for listing, pairing, installing, and launching;
- a profile store that contains endpoints and Bonjour records, never pairing
  secrets;
- optional Tailscale peer resolution with a manual-IP fallback;
- bounded `dns-sd -Z` capture and a parser for Xcode 27 service families;
- a TCP relay and `/usr/bin/dns-sd -P` Bonjour proxy publisher;
- initial iPhone and Apple Watch service-model support;
- Xcode 27 phone/Watch pairing command and JSON adapters;
- deterministic parser, command, profile, and Bonjour command tests.

The physical Xcode bridge is not yet certified. A real iPhone 17 and paired
Apple Watch on iOS 27/watchOS 27 are required to verify the device graph,
RemotePairing records, dynamic CoreDevice ports, native Xcode Run Destinations,
breakpoints, LLDB, and Watch installation/debugging. Until that pass exists,
the relay is candidate-only.

An Apple Watch charging puck provides power; it is not treated as a direct USB
developer transport. DeviceHarbor expects the Watch to be paired with its
iPhone and visible through Xcode 27’s CoreDevice graph, with Bluetooth/Wi-Fi
available for the Apple developer connection.

## Build

Requirements: macOS 27, Xcode 27, and Swift 6.4.

```sh
swift build
swift test
./script/build_and_run.sh --verify
```

Open `Package.swift` in Xcode when you want an Xcode project view; the Swift
package is the source of truth.

## Pairing and transport model

1. Pair the iPhone with Xcode over USB and enable Developer Mode.
2. Pair the Watch with its iPhone and enable Developer Mode on both devices.
3. Capture the device’s Bonjour service records while the normal local path is
   working.
4. Install the same private-network client on the Mac and iPhone, then record
   the iPhone’s private address in a DeviceHarbor profile.
5. Start the relay. DeviceHarbor re-advertises the captured services locally and
   forwards their TCP connections over the private network.
6. Use Xcode’s Device Hub and `devicectl` to verify the resulting device path.

The known Xcode service families are `_remotepairing._tcp`, `_remoted._tcp`,
and `_apple-mobdev2._tcp`. Their ports and TXT records are device/session data;
DeviceHarbor does not invent them or commit them to the repository.

## Security boundary

DeviceHarbor stores only local profile metadata. Pairing records and private
keys remain in the operating system’s owner-only locations managed by Apple’s
device tooling. The relay does not open a public listener by default, does not
provide a cloud relay, and does not disable macOS firewall or network privacy
controls.

The app is not affiliated with Apple. Xcode, iPhone, Apple Watch, and related
marks belong to Apple Inc.
