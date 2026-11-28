import AppKit
import Combine

final class TrayModule: CalaModule {
    let id = ModuleID.tray
    private(set) var isRunning = false
    private(set) var flyout: FlyoutController?
    private let store: ConfigStore
    private unowned let bar: BarModule
    private var shellReady = false
    private var runID: UUID?
    private var wakeObserver: NSObjectProtocol?
    private var placeObserver: AnyCancellable?
    /// The services running now; `reconcile` keeps it equal to `TrayServicePlan.wanted` for the shown items.
    private(set) var services = Set<TrayService>()
    private var lastTray = Date.distantPast
    private var lastCalendar = Date.distantPast
    private var lastMonitor = Date.distantPast

    init(store: ConfigStore, bar: BarModule) {
        self.store = store
        self.bar = bar
    }

    func start() {
        guard !isRunning, let controller = bar.controller else { return }
        isRunning = true
        let run = UUID()
        runID = run
        lastTray = .distantPast; lastCalendar = .distantPast; lastMonitor = .distantPast
        MenuBarIcons.apply(store)
        controller.model.startTray()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.runID == run, self.services.contains(.usage), self.usageVisible else { return }
            UsageService.shared.refresh()
        }
        // Hiding or showing an item starts or stops only its own services; other layout changes do nothing.
        placeObserver = store.$config.map(Self.shownItems).removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main).sink { [weak self] shown in
                guard let self, self.runID == run else { return }
                self.reconcile(shown)
            }
        reconcile(Self.shownItems(store.config))
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        runID = nil
        placeObserver?.cancel()
        placeObserver = nil
        Users.cancelSwitch()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        flyout?.stop()
        flyout = nil
        bar.controller?.closeFlyout()
        for service in TrayServicePlan.transition(from: services, to: []).stop { stop(service) }
        services.removeAll()
        if shellReady {
            MainActor.assumeIsolated {
                // Turning the tray off deletes mail's cached bodies, also when a hidden Mail item had already stopped
                // sync; quitting (or an update relaunch) keeps them.
                if !ModuleRegistry.shared.isShuttingDown { MailService.shared.purgeCache() }
                MailKeychainNoticeController.shared.dismiss()
            }
        }
        bar.controller?.model.stopTray()
        if ModuleRegistry.shared.isShuttingDown { MenuBarIcons.onQuit(store) }
        else { MenuBarIcons.restoreForTrayStop(store) }
    }

    func finishOnboarding() {
        guard !shellReady else { return }
        shellReady = true
        if isRunning { reconcile(Self.shownItems(store.config)) }
    }

    /// Placeable items in the bar or in More, plus the clock: a hidden item is not shown anywhere.
    private static func shownItems(_ config: Config) -> Set<String> {
        TrayServicePlan.visibleItems(TrayItems.all.map(\.id), place: config.place)
    }

    /// Starts the services the shown items need and stops the rest (TrayServicePlan, pure and checked).
    private func reconcile(_ shown: Set<String>) {
        guard isRunning, let controller = bar.controller else { return }
        controller.model.shownTray = shown
        if let flyout, flyout.isVisible, TrayItems.info(flyout.kind) != nil, !shown.contains(flyout.kind) {
            controller.closeFlyout() // Its item was just hidden: its panel goes with the service behind it.
        }
        let (stops, starts) = TrayServicePlan.transition(
            from: services, to: TrayServicePlan.wanted(visible: shown, welcomeDone: shellReady))
        for service in stops {
            stop(service)
            services.remove(service)
        }
        for service in starts {
            start(service)
            services.insert(service)
        }
        if !stops.isEmpty || !starts.isEmpty {
            log(TrayServicePlan.summary(running: services, stopped: stops, started: starts))
        }
        // An item that just came back shows fresh values instead of the ones from before it was hidden.
        lastTray = .distantPast; lastMonitor = .distantPast
    }

    private func start(_ service: TrayService) {
        switch service {
        case .wifi: WifiInfo.shared.start()
        case .power: bar.controller?.model.startPowerWatch()
        case .system: SystemMonitor.shared.start()
        case .disk: break // The folder scan runs when the Disk panel opens.
        case .usage:
            let visible = usageVisible
            UsageService.shared.start(store: store, visible: visible)
            UsagePace.shared.start(store: store)
            if visible { UsageService.shared.refresh() }
        case .mail:
            MainActor.assumeIsolated {
                // Warm the message web view (rule list, data store, WebContent process) only when mail is set up.
                if !MailService.shared.accounts.isEmpty { MailWebBody.prewarm() }
                MailService.shared.start(explainingKeychain: MailKeychainNoticeController.shared.show,
                                         dismissing: MailKeychainNoticeController.shared.dismiss)
            }
        case .calendar: CalendarService.shared.start()
        }
    }

    private func stop(_ service: TrayService) {
        switch service {
        case .wifi: WifiInfo.shared.stop()
        case .power: bar.controller?.model.stopPowerWatch()
        case .system: SystemMonitor.shared.stop()
        case .disk: DiskService.shared.stop()
        case .usage:
            UsagePace.shared.stop()
            UsageService.shared.stop()
        case .mail:
            MainActor.assumeIsolated {
                // Hiding Mail stops sync and keeps the cached bodies; `stop()` purges them when the tray turns off.
                MailService.shared.stop()
                MailKeychainNoticeController.shared.dismiss()
                MailWebBody.cool()
            }
        case .calendar: CalendarService.shared.stop()
        }
    }

    private var usageVisible: Bool {
        !store.config.autoHide || bar.controller?.bars.contains(where: { !$0.hidden }) == true
    }

    func tick() {
        guard isRunning, let controller = bar.controller else { return }
        let now = Date()
        if services.contains(.usage) {
            UsageService.shared.visibility(visible: controller.bars.contains(where: { !$0.hidden }),
                                           alwaysVisible: !store.config.autoHide)
        }
        if now.timeIntervalSince(lastTray) > 3 {
            lastTray = now
            controller.model.refreshTray()
        }
        if services.contains(.system), now.timeIntervalSince(lastMonitor) > 3 {
            lastMonitor = now
            SystemMonitor.shared.tick()
            RestartAdvisor.shared.refresh(disk: controller.model.disk)
        }
        if services.contains(.calendar), now.timeIntervalSince(lastCalendar) > 60 {
            lastCalendar = now
            CalendarService.shared.backgroundRefresh(config: store.config)
        }
    }

    func openSystemPanel() {
        guard isRunning, services.contains(.system), let controller = bar.controller, let first = controller.bars.first else { return }
        click(traySystem, bar: first, controller: controller)
    }

    func click(_ id: String, bar: Bar, controller: BarController) {
        guard isRunning else { return }
        if id == trayJoin {
            controller.closeFlyout()
            if let url = CalendarLogic.joinCandidate(CalendarService.shared.events, now: Date())?.joinURL { NSWorkspace.shared.open(url) }
            return
        }
        let flyout = self.flyout ?? FlyoutController(model: controller.model) { [weak controller] id, point in
            guard let controller, let bar = controller.flyoutBar else { return }
            controller.showTrayMenu(id, bar: bar, at: point)
        }
        self.flyout = flyout
        if flyout.isVisible && flyout.kind == id { controller.closeFlyout(); return }
        controller.model.refreshTray()
        controller.overlayBar = bar
        controller.flyoutBar = bar
        flyout.show(kind: id, barTop: controller.barFrame(bar, hidden: false).maxY,
                    centerX: controller.iconCenterX(bar, id, fallback: NSEvent.mouseLocation.x), screen: bar.screen)
    }
}
