#if CALA_UPDATE_TEST
import Combine
import Foundation

final class UpdateTestHook: NSObject {
    private static let notification = Notification.Name("local.cala.test.update")
    private let center = DistributedNotificationCenter.default()
    private weak var service: UpdateService?
    private weak var store: ConfigStore?
    private var snapshots: AnyCancellable?

    init(service: UpdateService, store: ConfigStore) {
        self.service = service
        self.store = store
        super.init()
        center.addObserver(self, selector: #selector(receive(_:)), name: Self.notification,
                           object: nil, suspensionBehavior: .deliverImmediately)
        // @Published emits before assignment. Use the emitted values so the snapshot reflects the change.
        snapshots = service.$state.removeDuplicates().combineLatest(service.$offer, service.$available)
            .sink { [weak self] state, offer, available in
                self?.write(state: state, offer: offer, available: available)
            }
    }

    deinit { center.removeObserver(self) }

    @objc private func receive(_ notification: Notification) {
        guard let command = notification.userInfo?["command"] as? String ?? notification.object as? String else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let service = self.service else { return }
            switch command {
            case "check": service.checkNow()
            case "install": service.install()
            case "skip": service.skip()
            case "later": service.later()
            case "dump": self.write(state: service.state, offer: service.offer, available: service.available)
            default: break
            }
        }
    }

    private func write(state: UpdateState, offer: UpdateManifest?, available: UpdateManifest?) {
        guard let store else { return }
        let registry = ModuleRegistry.shared
        let modules = registry.waitingForOnboarding ? .none : ModulePlan.effective(store.config.modules)
        let indicators = [
            "bar": available != nil && !(registry.bar.controller?.bars.isEmpty ?? true),
            "statusItemBadge": available != nil && ModulePlan.showsStatusItem(modules, zonesIcon: store.config.zonesStatusItem)
        ]
        let english = state.message { english, _ in english }
        let spanish = state.message { _, spanish in spanish }
        let lastError: String?
        switch state {
        case .rolledBack, .offline, .feedUnavailable, .verificationFailed, .diskFull, .busy, .blockedByMacOS,
             .needsAdmin, .needsNewerMacOS, .manualInstall, .unsupported, .unavailable, .failed, .restartFailed:
            lastError = english
        default:
            lastError = nil
        }
        do {
            // Use the enum's Codable case name and associated values, including labels such as _0 and _1.
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let encoded = try JSONSerialization.jsonObject(with: encoder.encode(state))
            guard let entry = (encoded as? [String: [String: Any]])?.first else { return }
            let snapshot: [String: Any] = [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "version": Telemetry.appVersion(),
                "build": Telemetry.appBuild(),
                "state": entry.key,
                "stateDetail": entry.value.isEmpty ? NSNull() as Any : entry.value,
                "availableVersion": offer?.version as Any? ?? NSNull(),
                "indicatorVisible": indicators,
                "settingsStatusTextEN": english,
                "settingsStatusTextES": spanish,
                "lastError": lastError as Any? ?? NSNull(),
                "timestamp": Date().ISO8601Format(.init(includingFractionalSeconds: true))
            ]
            let folder = AppPaths.supportDirectory
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
            try data.write(to: folder.appendingPathComponent("update-test-state.json"), options: .atomic)
        } catch {
            log("update: could not write test state: \(error)")
        }
    }
}
#endif
