import Combine
import DeviceHarborCore
import DeviceHarborTransport
import Foundation

enum SidebarSelection: Hashable {
    case device(String)
    case profile(UUID)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [CoreDevice] = []
    @Published var profiles: [DeviceProfile] = []
    @Published var selection: SidebarSelection?
    @Published var bridgeState: BridgeState = .stopped
    @Published var statusMessage = "Ready"
    @Published var lastCommand = ""
    @Published var isRefreshing = false
    @Published var watchPairings: [DevicePairing] = []
    @Published var isLoadingWatchPairings = false
    @Published var companionState: DeviceHarborCompanionState = .stopped
    @Published var companionPairingCode = ""

    private let deviceClient: DeviceCtlClient
    private let profileStore: any ProfileStoring
    private let companionServer: DeviceHarborCompanionServer
    private var bridge: BonjourBridge?

    init(
        deviceClient: DeviceCtlClient = DeviceCtlClient(),
        profileStore: any ProfileStoring = FileProfileStore()
    ) {
        self.deviceClient = deviceClient
        self.profileStore = profileStore
        let companionServer = DeviceHarborCompanionServer()
        self.companionServer = companionServer
        self.companionPairingCode = companionServer.pairingCode
        companionServer.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.companionState = state
            }
        }
        do {
            try companionServer.start()
            companionState = .waitingForPair
        } catch {
            companionState = .failed(error.localizedDescription)
        }
        provisionEphemeralRelay()
        do {
            profiles = try profileStore.load()
        } catch {
            statusMessage = error.localizedDescription
        }
        Task { @MainActor [weak self] in
            self?.refreshDevices()
        }
    }

    deinit {
        companionServer.stop()
    }

    var selectedDevice: CoreDevice? {
        guard case .device(let identifier) = selection else { return nil }
        return devices.first { $0.identifier == identifier }
    }

    var selectedProfile: DeviceProfile? {
        guard case .profile(let id) = selection else { return nil }
        return profiles.first { $0.id == id }
    }

    func refreshDevices() {
        guard !isRefreshing else { return }
        isRefreshing = true
        statusMessage = "Asking Xcode 27 CoreDevice for devices…"
        let client = deviceClient
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                do {
                    return Result<[CoreDevice], BackgroundFailure>.success(try client.listDevices())
                } catch {
                    return Result<[CoreDevice], BackgroundFailure>.failure(
                        BackgroundFailure(message: error.localizedDescription)
                    )
                }
            }.value
            guard let self else { return }
            isRefreshing = false
            switch result {
            case .success(let devices):
                self.devices = devices.filter(\.isPhysical)
                self.statusMessage = self.devices.first(where: { $0.connectivityAdvice != nil })?.connectivityAdvice
                    ?? (self.devices.isEmpty ? "No physical devices reported by CoreDevice." : "Found \(self.devices.count) physical device(s).")
            case .failure(let message):
                self.statusMessage = message.message
            }
        }
    }

    func addProfile() {
        let profile = DeviceProfile(
            displayName: "New Device",
            deviceIdentifier: "",
            platform: .iOS,
            advertisedAddress: "127.0.0.1",
            services: [
                RelayService(
                    instanceName: "iPhone",
                    serviceType: "_remotepairing._tcp",
                    remotePort: 49152
                )
            ]
        )
        profiles.append(profile)
        selection = .profile(profile.id)
        persistProfiles()
    }

    func updateProfile(_ profile: DeviceProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        persistProfiles()
    }

    func deleteProfile(_ profile: DeviceProfile) {
        if case .profile(profile.id) = selection {
            stopBridge()
            selection = nil
        }
        profiles.removeAll { $0.id == profile.id }
        persistProfiles()
    }

    func pair(device: CoreDevice) {
        statusMessage = "Pairing \(device.name)…"
        let client = deviceClient
        let identifier = device.identifier
        runInBackground {
            try client.pair(deviceIdentifier: identifier)
        } completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                statusMessage = "Pairing request completed for \(device.name)."
                refreshDevices()
            case .failure(let message):
                statusMessage = message
            }
        }
    }

    func prepare(device: CoreDevice) {
        if device.isPaired {
            statusMessage = device.connectivityAdvice ?? "\(device.name) is already paired."
            refreshDevices()
        } else {
            pair(device: device)
        }
    }

    func refreshWatchPairings(for phone: CoreDevice) {
        guard phone.platformKind == .iOS else { return }
        guard !isLoadingWatchPairings else { return }
        guard devices.contains(where: { $0.platformKind == .watchOS }) else {
            watchPairings = []
            statusMessage = "No watchOS device is visible in CoreDevice yet. Pair the Watch in Xcode Device Hub with the iPhone connected, then refresh."
            return
        }
        isLoadingWatchPairings = true
        statusMessage = "Reading Watch pairings…"
        let client = deviceClient
        let identifier = phone.identifier
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                do {
                    return Result<[DevicePairing], BackgroundFailure>.success(
                        try client.listPairings(for: identifier)
                    )
                } catch {
                    return Result<[DevicePairing], BackgroundFailure>.failure(
                        BackgroundFailure(message: error.localizedDescription)
                    )
                }
            }.value
            guard let self else { return }
            isLoadingWatchPairings = false
            switch result {
            case .success(let pairings):
                watchPairings = pairings
                statusMessage = pairings.isEmpty ? "No Watch pairing records reported." : "Found \(pairings.count) Watch pairing(s)."
            case .failure(let error):
                statusMessage = error.message
            }
        }
    }

    func startBridge(for profile: DeviceProfile) {
        guard profile.isValid else {
            bridgeState = .failed("Complete the profile and add a valid Bonjour service first.")
            return
        }
        guard case .paired = companionState else {
            bridgeState = .failed("Pair the DeviceHarbor iPhone companion before starting the bridge.")
            statusMessage = "The Mac is ready, but no paired DeviceHarbor iPhone companion session is active."
            return
        }
        bridge?.stop()
        bridgeState = .starting
        statusMessage = "Starting Bonjour proxy and DeviceHarbor transport…"
        let newBridge = BonjourBridge(streamProvider: companionServer)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                do {
                    return Result<BridgeStartResult, BackgroundFailure>.success(try newBridge.start(profile: profile))
                } catch {
                    return Result<BridgeStartResult, BackgroundFailure>.failure(
                        BackgroundFailure(message: error.localizedDescription)
                    )
                }
            }.value
            guard let self else {
                newBridge.stop()
                return
            }
            switch result {
            case .success(let started):
                bridge = newBridge
                bridgeState = .active(serviceCount: started.serviceCount)
                statusMessage = "Relay active on \(started.serviceCount) Bonjour service(s)."
            case .failure(let message):
                newBridge.stop()
                bridge = nil
                bridgeState = .failed(message.message)
                statusMessage = message.message
            }
        }
    }

    func stopBridge() {
        bridge?.stop()
        bridge = nil
        bridgeState = .stopped
        statusMessage = "Relay stopped."
    }

    private func provisionEphemeralRelay() {
        let provisioner = DeviceHarborEphemeralRelayProvisioner()
        let pairingCode = companionPairingCode
        Task { @MainActor [weak self, provisioner] in
            let result = await Task.detached(priority: .utility) {
                do {
                    return Result<DeviceHarborRelayOffer, RelayProvisioningFailure>.success(
                        try provisioner.provision(pairingCode: pairingCode)
                    )
                } catch {
                    return Result<DeviceHarborRelayOffer, RelayProvisioningFailure>.failure(
                        RelayProvisioningFailure(message: error.localizedDescription)
                    )
                }
            }.value
            guard let self else { return }
            switch result {
            case .success(let offer):
                companionServer.setRelayOffer(offer)
                do {
                    try companionServer.connectToHostedRelay(offer: offer)
                    statusMessage = "Temporary DeviceHarbor relay is ready. Pair code \(companionPairingCode) is available to the iPhone companion."
                } catch {
                    statusMessage = error.localizedDescription
                }
            case .failure(let failure):
                statusMessage = "Temporary DeviceHarbor relay unavailable: \(failure.message)"
            }
        }
    }

    func captureLocalBonjourServices(
        matching identities: [String] = [],
        duration: TimeInterval = 12,
        completion: @escaping @MainActor (BonjourCaptureOutcome) -> Void
    ) {
        statusMessage = "Capturing local Xcode Bonjour records…"
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                do {
                        var services: [CapturedBonjourService] = []
                        for serviceType in BonjourServiceFamilies.xcode27 {
                            services.append(contentsOf: try BonjourCapture().capture(
                                serviceType: serviceType,
                                matching: identities,
                                duration: duration
                            ))
                    }
                    return BonjourCaptureOutcome.success(services)
                } catch {
                    return BonjourCaptureOutcome.failure(error.localizedDescription)
                }
            }.value
            guard let self else { return }
            switch outcome {
            case .success(let services):
                statusMessage = services.isEmpty
                    ? "No matching wireless-debug Bonjour records were captured. Enable wireless debugging while the phone is on the same Wi-Fi, then try again."
                    : "Captured \(services.count) local Bonjour service(s)."
            case .failure(let message):
                statusMessage = message
            }
            completion(outcome)
        }
    }

    func installApp(at url: URL, for profile: DeviceProfile) {
        let client = deviceClient
        let identifier = profile.deviceIdentifier
        lastCommand = DeviceCtlClient.installCommand(
            deviceIdentifier: identifier,
            applicationPath: url.path
        ).displayCommand
        statusMessage = "Installing \(url.lastPathComponent)…"
        runInBackground {
            try client.installApp(at: url, on: identifier)
        } completion: { [weak self] result in
            guard let self else { return }
            statusMessage = result.isSuccess ? "Install completed." : result.message
        }
    }

    func launch(bundleIdentifier: String, for profile: DeviceProfile) {
        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "Enter a bundle identifier first."
            return
        }
        let client = deviceClient
        let identifier = profile.deviceIdentifier
        lastCommand = DeviceCtlClient.launchCommand(
            deviceIdentifier: identifier,
            bundleIdentifier: trimmed
        ).displayCommand
        statusMessage = "Launching \(trimmed)…"
        runInBackground {
            try client.launch(bundleIdentifier: trimmed, on: identifier)
        } completion: { [weak self] result in
            guard let self else { return }
            statusMessage = result.isSuccess ? "Launch completed." : result.message
        }
    }

    private func persistProfiles() {
        do {
            try profileStore.save(profiles)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func runInBackground(
        operation: @escaping @Sendable () throws -> Void,
        completion: @escaping @MainActor (BackgroundResult) -> Void
    ) {
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> BackgroundResult in
                do {
                    try operation()
                    return .success
                } catch {
                    return .failure(error.localizedDescription)
                }
            }.value
            guard self != nil else { return }
            completion(result)
        }
    }
}

private struct BackgroundFailure: Error, Sendable {
    let message: String
}

private struct RelayProvisioningFailure: Error, Sendable {
    let message: String
}

enum BonjourCaptureOutcome: Sendable {
    case success([CapturedBonjourService])
    case failure(String)
}

enum BackgroundResult: Sendable {
    case success
    case failure(String)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .success: "Success"
        case .failure(let message): message
        }
    }
}
