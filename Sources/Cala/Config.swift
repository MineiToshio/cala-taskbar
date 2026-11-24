import Foundation
import Combine

struct Config: Codable, Equatable {
    /// First-run pins: apps every Mac has. Anything not installed is skipped when the bar is built.
    var pinned: [String] = [
        "com.apple.finder",
        "com.apple.Safari",
        "com.apple.systempreferences",
    ]
    var autoHide = true
    /// Interface language: "system" (follow macOS), "en" or "es".
    var language = "system"
    var iconSize: Double = 28
    var previewDelay: Double = 0.05
    var previewWidth: Double = 420
    /// Icon alignment per screen (display UUID -> "left" | "center").
    var alignments: [String: String] = [:]
    /// Custom icon order (app ids), set by dragging icons on the bar.
    var order: [String] = []
    /// Bar color theme id (see BarTheme).
    var theme = "system"
    /// Bar background opacity (1 = solid, lower = more transparent). Icons and text are unaffected.
    var barOpacity: Double = 1
    /// Hide the native macOS Dock while the bar runs.
    var hideNativeDock = false
    /// Window switcher (Option+Tab): one card per window.
    var switcherEnabled = true
    /// Also take over Cmd+Tab.
    var switcherReplaceCmdTab = false
    var modulesChosen = false
    var barEnabled = true
    var trayEnabled = true
    var zonesEnabled = false
    var zonesActivation = "rightClick"
    var zonesGap: Double = 8
    var zonesEditorGrid = false

    var modules: ModuleSet {
        ModuleSet(bar: barEnabled, switcher: switcherEnabled, tray: trayEnabled, zones: zonesEnabled)
    }
    /// Give the Dock back when the bar quits (so nobody is left without one).
    var restoreDockOnQuit = true
    /// Hide the macOS menu bar (auto-hide everywhere) while the app runs.
    /// What to do when Cala crashed last time: "ask" (default), "auto" (send without asking) or "never".
    var crashReports = "ask"
    /// Open Cala again by itself if it crashes (see Watchdog).
    var relaunchOnCrash = true
    /// Suggest restarting the Mac, with the reasons, in the system panel.
    var restartAdvice = true
    var hideMenuBar = false
    var restoreMenuBarOnQuit = true
    /// Ids of macOS menu bar icons (see MenuBarIcons) to hide, and the original value of each so it can be restored.
    var menuBarHiddenIcons: [String] = []
    var menuBarIconBackupV2: [String: String] = [:]
    var menuBarBackupSaved = false
    var menuBarBackupOption: Int?
    var menuBarBackupHide: Bool?
    var menuBarBackupFullscreen: Bool?
    var dockBackupSaved = false
    /// Whether Cala wrote the hidden Dock values. Absent in configs from before ownership was recorded.
    var dockOverridePending: Bool?
    var dockBackupAutohide: Bool?
    var dockBackupDelay: Double?
    var usageEnabled = true
    var usageClaudeEnabled = true
    var usageCodexEnabled = true
    var usageClaudeConfigDir = ""
    var usageCodexHome = ""
    var usageClaudeStatusLine = false
    /// Notify when a quota window is low or projected to run out before it resets.
    var usageAlertsEnabled = true
    /// Remaining percentage at or below which the low-quota notification fires (10, 15, 20 or 30).
    var usageAlertThreshold = 20
    /// Tray item id -> "bar" | "more" | "hidden". Missing ids use their default (see TrayItems).
    var trayLayout: [String: String] = [:]
    /// Left-to-right order of the tray items.
    var trayOrder: [String] = []
    var diskEnabled = true
    /// CPU / memory monitor in the tray with a "why is my Mac slow" panel.
    var monitorEnabled = true
    /// What the CPU and memory tray item shows while nothing is wrong: "cpu" or "memory". A problem always wins.
    var monitorBarMetric = "cpu"
    /// Extra folders measured in the storage panel (e.g. where your projects or git worktrees live).
    var diskFolders: [String] = []
    var calendarEnabled = true
    /// Show a "Join" button in the bar for meetings with a video link that are about to start.
    var calendarJoinEnabled = true
    var calendarDays = 7
    var calendarExcludedIDs: [String] = []
    var mailLoadsRemoteImages = true
    var recoveredFromInvalidFields = false

    enum CodingKeys: String, CodingKey {
        case language
        case pinned, autoHide, iconSize, previewDelay, previewWidth, alignments, order, theme, barOpacity
        case hideNativeDock, switcherEnabled, switcherReplaceCmdTab, restoreDockOnQuit
        case calendarEnabled, calendarJoinEnabled, calendarDays, calendarExcludedIDs, diskEnabled, diskFolders, monitorEnabled, monitorBarMetric, trayLayout, trayOrder
        case dockBackupSaved, dockBackupAutohide, dockBackupDelay
        case dockOverridePending
        case crashReports, relaunchOnCrash, restartAdvice, menuBarHiddenIcons, menuBarIconBackupV2, hideMenuBar, restoreMenuBarOnQuit, menuBarBackupSaved, menuBarBackupOption, menuBarBackupHide, menuBarBackupFullscreen
        case usageEnabled, usageClaudeEnabled, usageCodexEnabled, usageClaudeConfigDir, usageCodexHome, usageClaudeStatusLine
        case usageAlertsEnabled, usageAlertThreshold
        case mailLoadsRemoteImages
        case modulesChosen, barEnabled, trayEnabled, zonesEnabled, zonesActivation, zonesGap, zonesEditorGrid
    }
}

extension Config {
    init(from d: Decoder) throws {
        self.init()
        let c = try d.container(keyedBy: CodingKeys.self)
        var invalid = false
        func field<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            do { return try c.decodeIfPresent(type, forKey: key) }
            catch { invalid = true; return nil }
        }
        func clamped(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? max(range.lowerBound, min(range.upperBound, value)) : fallback
        }
        pinned = field([String].self, .pinned) ?? pinned
        autoHide = field(Bool.self, .autoHide) ?? autoHide
        language = field(String.self, .language) ?? language
        mailLoadsRemoteImages = field(Bool.self, .mailLoadsRemoteImages) ?? mailLoadsRemoteImages
        if !["system", "en", "es"].contains(language) { language = "system"; invalid = true }
        iconSize = field(Double.self, .iconSize) ?? iconSize
        previewDelay = field(Double.self, .previewDelay) ?? previewDelay
        previewWidth = field(Double.self, .previewWidth) ?? previewWidth
        alignments = field([String: String].self, .alignments) ?? alignments
        order = field([String].self, .order) ?? order
        theme = field(String.self, .theme) ?? theme
        barOpacity = field(Double.self, .barOpacity) ?? barOpacity
        hideNativeDock = field(Bool.self, .hideNativeDock) ?? hideNativeDock
        switcherEnabled = field(Bool.self, .switcherEnabled) ?? switcherEnabled
        switcherReplaceCmdTab = field(Bool.self, .switcherReplaceCmdTab) ?? switcherReplaceCmdTab
        modulesChosen = field(Bool.self, .modulesChosen) ?? modulesChosen
        barEnabled = field(Bool.self, .barEnabled) ?? barEnabled
        trayEnabled = field(Bool.self, .trayEnabled) ?? trayEnabled
        zonesEnabled = field(Bool.self, .zonesEnabled) ?? zonesEnabled
        zonesActivation = field(String.self, .zonesActivation) ?? zonesActivation
        if !["rightClick", "shift", "both"].contains(zonesActivation) { zonesActivation = "rightClick"; invalid = true }
        zonesGap = clamped(field(Double.self, .zonesGap) ?? zonesGap, 0...40, 8)
        zonesEditorGrid = field(Bool.self, .zonesEditorGrid) ?? zonesEditorGrid
        restoreDockOnQuit = field(Bool.self, .restoreDockOnQuit) ?? restoreDockOnQuit
        dockBackupSaved = field(Bool.self, .dockBackupSaved) ?? dockBackupSaved
        dockOverridePending = field(Bool.self, .dockOverridePending)
        hideMenuBar = field(Bool.self, .hideMenuBar) ?? hideMenuBar
        crashReports = field(String.self, .crashReports) ?? crashReports
        relaunchOnCrash = field(Bool.self, .relaunchOnCrash) ?? relaunchOnCrash
        restartAdvice = field(Bool.self, .restartAdvice) ?? restartAdvice
        if !["ask", "auto", "never"].contains(crashReports) { crashReports = "ask"; invalid = true }
        menuBarHiddenIcons = field([String].self, .menuBarHiddenIcons) ?? menuBarHiddenIcons
        menuBarIconBackupV2 = field([String: String].self, .menuBarIconBackupV2) ?? menuBarIconBackupV2
        restoreMenuBarOnQuit = field(Bool.self, .restoreMenuBarOnQuit) ?? restoreMenuBarOnQuit
        menuBarBackupSaved = field(Bool.self, .menuBarBackupSaved) ?? menuBarBackupSaved
        menuBarBackupOption = field(Int.self, .menuBarBackupOption)
        menuBarBackupHide = field(Bool.self, .menuBarBackupHide)
        menuBarBackupFullscreen = field(Bool.self, .menuBarBackupFullscreen)
        dockBackupAutohide = field(Bool.self, .dockBackupAutohide)
        dockBackupDelay = field(Double.self, .dockBackupDelay)
        usageEnabled = field(Bool.self, .usageEnabled) ?? usageEnabled
        usageClaudeEnabled = field(Bool.self, .usageClaudeEnabled) ?? usageClaudeEnabled
        usageCodexEnabled = field(Bool.self, .usageCodexEnabled) ?? usageCodexEnabled
        usageClaudeConfigDir = field(String.self, .usageClaudeConfigDir) ?? usageClaudeConfigDir
        usageCodexHome = field(String.self, .usageCodexHome) ?? usageCodexHome
        usageClaudeStatusLine = field(Bool.self, .usageClaudeStatusLine) ?? usageClaudeStatusLine
        usageAlertsEnabled = field(Bool.self, .usageAlertsEnabled) ?? usageAlertsEnabled
        usageAlertThreshold = field(Int.self, .usageAlertThreshold) ?? usageAlertThreshold
        if ![10, 15, 20, 30].contains(usageAlertThreshold) { usageAlertThreshold = 20; invalid = true }
        diskEnabled = field(Bool.self, .diskEnabled) ?? diskEnabled
        monitorEnabled = field(Bool.self, .monitorEnabled) ?? monitorEnabled
        monitorBarMetric = field(String.self, .monitorBarMetric) ?? monitorBarMetric
        if !["cpu", "memory"].contains(monitorBarMetric) { monitorBarMetric = "cpu"; invalid = true }
        trayLayout = field([String: String].self, .trayLayout) ?? trayLayout
        trayOrder = field([String].self, .trayOrder) ?? trayOrder
        diskFolders = field([String].self, .diskFolders) ?? diskFolders
        calendarEnabled = field(Bool.self, .calendarEnabled) ?? calendarEnabled
        calendarJoinEnabled = field(Bool.self, .calendarJoinEnabled) ?? calendarJoinEnabled
        calendarDays = field(Int.self, .calendarDays) ?? calendarDays
        if ![1, 3, 7, 14].contains(calendarDays) { calendarDays = 7; invalid = true }
        calendarExcludedIDs = field([String].self, .calendarExcludedIDs) ?? calendarExcludedIDs
        iconSize = clamped(iconSize, 20...44, 28)
        previewDelay = clamped(previewDelay, 0...0.6, 0.05)
        previewWidth = clamped(previewWidth, 300...560, 420)
        barOpacity = clamped(barOpacity, 0.2...1, 1)
        // Dock backup fields are the user's original Dock settings: restored verbatim, never clamped.
        recoveredFromInvalidFields = invalid
    }
}

final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published var config: Config {
        didSet {
            if config.language != oldValue.language { Self.applyLanguage(config) }
            if config != oldValue { save() }
        }
    }

    /// Makes every tx()/calendarText() call use the chosen language ("system" follows macOS).
    static func applyLanguage(_ config: Config) {
        appLanguageOverride = config.language == "system" ? nil : config.language
    }

    private let url: URL = {
        let dir = AppPaths.supportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }()

    var fileURL: URL { url }
    private(set) var configLoadFailed = false
    /// A config file was already there when Cala started (an existing install, not a first run).
    private(set) var existedAtLaunch = false
    private var canSave = true

    private init() {
        defer { Self.applyLanguage(config) }
        config = Config()
        existedAtLaunch = FileManager.default.fileExists(atPath: url.path)
        guard existedAtLaunch else { save(); return }
        do {
            config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
            if config.recoveredFromInvalidFields { log("config: invalid fields replaced with defaults") }
        } catch {
            configLoadFailed = true
            log("config: load failed: \(error)")
            let bad = url.appendingPathExtension("bad")
            do {
                if FileManager.default.fileExists(atPath: bad.path) { try FileManager.default.removeItem(at: bad) }
                try FileManager.default.moveItem(at: url, to: bad)
                log("config: moved invalid file to \(bad.path)")
            } catch {
                canSave = false
                log("config: could not preserve invalid file: \(error)")
            }
        }
    }

    private func save() {
        guard canSave else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try enc.encode(config).write(to: url, options: .atomic) }
        catch { log("config: save failed: \(error)") }
    }

    /// Uninstall: stop writing config.json (its folder is about to be removed).
    func disableSaving() { canSave = false }

    var barHeight: CGFloat { CGFloat(config.iconSize) + 20 }
}

import AppKit

extension NSScreen {
    var key: String {
        let id = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        if let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
           let s = CFUUIDCreateString(nil, u) as String? { return s }
        return "\(id)"
    }
}
