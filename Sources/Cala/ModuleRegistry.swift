import AppKit
import Combine

/// Main-thread owner of the enabled modules and their shared thumbnail watcher.
final class ModuleRegistry: ObservableObject {
    static let shared = ModuleRegistry()

    let bar: BarModule
    let tray: TrayModule
    let zones: ZonesModule
    @Published private(set) var runningModules = ModuleSet.none
    private let store = ConfigStore.shared
    private let thumbnails = ThumbnailWatch()
    private let statusItem = StatusItemController()
    private var modules: [ModuleID: any CalaModule]
    private var configObserver: AnyCancellable?
    private var statusItemObserver: AnyCancellable?
    private var effectiveModules = ModuleSet.none
    private var desired = ModuleSet.none
    private var pending: (ModuleSet, String, ModulePlan.Source?)?
    private var isApplying = false
    private(set) var isShuttingDown = false
    /// A first-run welcome has not been answered yet: nothing runs until "What do you want to use?" is saved.
    private(set) var waitingForOnboarding = false

    private init() {
        let bar = BarModule(store: store)
        let tray = TrayModule(store: store, bar: bar)
        bar.tray = tray
        let zones = ZonesModule(store: store, bar: bar)
        self.bar = bar
        self.tray = tray
        self.zones = zones
        modules = [.bar: bar, .tray: tray, .switcher: WindowSwitcher.shared, .zones: zones]
    }

    @discardableResult
    func launch(onboardingCompleted: Bool, onboardingPending: Bool, axTrusted: Bool) -> ModulePlan.Resolution {
        precondition(Thread.isMainThread)
        let config = store.config
        let resolved = ModulePlan.resolve(config.modules, chosen: config.modulesChosen,
                                          onboardingCompleted: onboardingCompleted, onboardingPending: onboardingPending,
                                          configExisted: store.existedAtLaunch, axTrusted: axTrusted)
        waitingForOnboarding = resolved.source == .provisional
        if resolved.persist {
            var migrated = config
            migrated.barEnabled = resolved.set.bar
            migrated.trayEnabled = resolved.set.tray
            migrated.zonesEnabled = resolved.set.zones
            migrated.modulesChosen = true
            store.config = migrated
        }

        let effective = ModulePlan.effective(resolved.set)
        if !effective.bar {
            DockControl.restoreAfterCrashIfNeeded(store)
            MenuBarControl.onBarStop(store)
        }
        if !effective.tray, !store.config.menuBarIconBackupV2.isEmpty {
            MenuBarIcons.restoreForTrayStop(store)
        }
        apply(resolved.set, reason: "launch", startupSource: resolved.source)

        // @Published emits before writing the value. Apply after the write, and use the latest value if changes coalesce.
        // While waiting for the welcome, module keys may still hold their defaults: only the saved choice
        // (modulesChosen turning true) starts anything, even when it equals those defaults.
        configObserver = store.$config.map { ModuleKeys(modules: $0.modules, chosen: $0.modulesChosen) }.removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self else { return }
                let config = self.store.config
                if self.waitingForOnboarding {
                    guard config.modulesChosen else { return }
                    self.waitingForOnboarding = false
                    self.apply(config.modules, reason: "onboarding")
                } else {
                    self.apply(config.modules, reason: "config")
                }
            }
        statusItemObserver = store.$config.map(\.zonesStatusItem).removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self, !self.isShuttingDown else { return }
                self.refreshStatusItem()
            }
        return resolved
    }

    private struct ModuleKeys: Equatable {
        var modules: ModuleSet
        var chosen: Bool
    }

    /// Register a module before launch, or start it immediately if its preference is already enabled.
    func register(_ module: any CalaModule) {
        precondition(Thread.isMainThread && modules[module.id] == nil)
        modules[module.id] = module
        apply(desired, reason: "registration")
    }

    func isRunning(_ id: ModuleID) -> Bool { modules[id]?.isRunning == true }

    func apply(_ desired: ModuleSet, reason: String) {
        apply(desired, reason: reason, startupSource: nil)
    }

    private func apply(_ desired: ModuleSet, reason: String, startupSource: ModulePlan.Source?) {
        precondition(Thread.isMainThread)
        guard !isShuttingDown else { return }
        pending = (desired, reason, startupSource)
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        while let (next, reason, source) = pending {
            pending = nil
            applyOnce(next, reason: reason, startupSource: source)
        }
    }

    private var running: ModuleSet { ModulePlan.running(modules.values) }

    private func applyOnce(_ next: ModuleSet, reason: String, startupSource: ModulePlan.Source?) {
        let effective = ModulePlan.effective(next)
        let changed = desired != next || startupSource != nil
        desired = next
        var started: [String] = []
        let (stops, starts) = ModulePlan.startOrder(from: running, to: effective)
        for id in stops {
            guard !isShuttingDown else { return }
            stop(id, reason: reason)
        }
        guard !isShuttingDown else { return }
        thumbnails.update(needed: ModulePlan.needsThumbnails(effective))
        for id in starts {
            guard let module = modules[id] else { continue }
            module.start()
            if isShuttingDown {
                if module.isRunning { stop(id, reason: "quit") }
                return
            }
            guard module.isRunning else { continue }
            let detail = id == .bar ? "\(bar.controller?.bars.count ?? 0) screens, \(reason)" : reason
            started.append("module \(id.rawValue): started (\(detail))")
        }
        if let startupSource {
            log(ModulePlan.startupLine(running: running, source: startupSource))
        } else if changed {
            log("modules: apply \(ModulePlan.summary(running)) reason=\(reason)")
        }
        started.forEach(log)
        if changed {
            if !effective.bar { log("module bar: off (bar not created / no space reserved)") }
            if next.tray && !effective.tray { log("module tray: off (needs bar)") }
            if effective.zones && modules[.zones] == nil { log("module zones: requested, unavailable (no module registered)") }
        }
        if runningModules != running { runningModules = running }
        effectiveModules = effective
        refreshStatusItem()
    }

    private func refreshStatusItem() {
        let zones = isRunning(.zones) ? modules[.zones] as? any ZonesStatusMenuProvider : nil
        statusItem.refresh(effectiveModules, zones: zones, zonesIcon: store.config.zonesStatusItem)
    }

    func shutdown() {
        precondition(Thread.isMainThread)
        guard !isShuttingDown else { return }
        isShuttingDown = true
        pending = nil
        configObserver?.cancel()
        configObserver = nil
        statusItemObserver?.cancel()
        statusItemObserver = nil
        for id in ModulePlan.startOrder(from: running, to: .none).stop { stop(id, reason: "quit") }
        thumbnails.update(needed: false)
        statusItem.remove()
    }

    private func stop(_ id: ModuleID, reason: String) {
        modules[id]?.stop()
        log("module \(id.rawValue): stopped (\(reason))")
    }
}

private final class ThumbnailWatch {
    private var timer: Timer?

    func update(needed: Bool) {
        if needed {
            guard timer == nil else { return }
            MinimizeWatcher.shared.start()
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in MinimizeWatcher.shared.sync() }
        } else if let timer {
            timer.invalidate()
            self.timer = nil
            MinimizeWatcher.shared.stop()
        }
    }
}

/// Signals in-flight background work to exit when its module stops.
final class ModuleCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
