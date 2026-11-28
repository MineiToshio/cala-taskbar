import AppKit

final class TrayModule: CalaModule {
    let id = ModuleID.tray
    private(set) var isRunning = false
    private(set) var flyout: FlyoutController?
    private let store: ConfigStore
    private unowned let bar: BarModule
    private var shellReady = false
    private var runID: UUID?
    private var wakeObserver: NSObjectProtocol?
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
        WifiInfo.shared.start()
        CalendarService.shared.start()
        SystemMonitor.shared.start()
        controller.model.startTray()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.runID == run, self.shellReady, self.usageVisible else { return }
            UsageService.shared.refresh()
        }
        if shellReady { startServices() }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        runID = nil
        MainActor.assumeIsolated { DockerService.shared.stop() }
        Users.cancelSwitch()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        flyout?.stop()
        flyout = nil
        bar.controller?.closeFlyout()
        bar.controller?.model.stopTray()
        CalendarService.shared.stop()
        WifiInfo.shared.stop()
        SystemMonitor.shared.stop()
        DiskService.shared.stop()
        if shellReady {
            UsagePace.shared.stop()
            UsageService.shared.stop()
            MainActor.assumeIsolated {
                // Turning the tray off deletes mail's cached bodies; quitting (or an update relaunch) keeps them.
                MailService.shared.stop(purgingCache: !ModuleRegistry.shared.isShuttingDown)
                MailKeychainNoticeController.shared.dismiss()
            }
        }
        if ModuleRegistry.shared.isShuttingDown { MenuBarIcons.onQuit(store) }
        else { MenuBarIcons.restoreForTrayStop(store) }
    }

    func finishOnboarding() {
        guard !shellReady else { return }
        shellReady = true
        if isRunning { startServices() }
    }

    private var usageVisible: Bool {
        !store.config.autoHide || bar.controller?.bars.contains(where: { !$0.hidden }) == true
    }

    func reconcileServices() {
        guard isRunning else { return }
        let visible = store.config.place(trayDocker) != .hidden
        if !visible, flyout?.kind == trayDocker { bar.controller?.closeFlyout() }
        MainActor.assumeIsolated {
            if visible { DockerService.shared.start() }
            else { DockerService.shared.stop() }
        }
    }

    private func startServices() {
        let visible = usageVisible
        UsageService.shared.start(store: store, visible: visible)
        UsagePace.shared.start(store: store)
        if visible { UsageService.shared.refresh() }
        MainActor.assumeIsolated {
            // Warm the message web view (rule list, data store, WebContent process) only when mail is set up.
            if !MailService.shared.accounts.isEmpty { MailWebBody.prewarm() }
            MailService.shared.start(explainingKeychain: MailKeychainNoticeController.shared.show,
                                     dismissing: MailKeychainNoticeController.shared.dismiss)
        }
    }

    func tick() {
        guard isRunning, let controller = bar.controller else { return }
        let now = Date()
        if shellReady {
            UsageService.shared.visibility(visible: controller.bars.contains(where: { !$0.hidden }),
                                           alwaysVisible: !store.config.autoHide)
        }
        if now.timeIntervalSince(lastTray) > 3 {
            lastTray = now
            controller.model.refreshTray()
        }
        if store.config.place(traySystem) != .hidden, now.timeIntervalSince(lastMonitor) > 3 {
            lastMonitor = now
            SystemMonitor.shared.tick()
            RestartAdvisor.shared.refresh(disk: controller.model.disk)
        }
        if now.timeIntervalSince(lastCalendar) > 60 {
            lastCalendar = now
            CalendarService.shared.backgroundRefresh(config: store.config)
        }
    }

    func openSystemPanel() {
        guard isRunning, let controller = bar.controller, let first = controller.bars.first else { return }
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
