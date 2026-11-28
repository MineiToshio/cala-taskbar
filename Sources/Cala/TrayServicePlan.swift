import Foundation

// Pure tray service logic (Foundation only, checked by scripts/check-settings.sh). It decides which of the tray's
// background services run for a given placement of the tray items; `TrayModule` applies the result.

// Tray item ids. One home for all of them so the plan below can be checked without AppKit.
let trayKB = "__t_kb", trayWifi = "__t_wifi", trayBT = "__t_bt", trayBright = "__t_bright", trayVol = "__t_vol"
let trayUsage = "__t_usage_combined", traySystem = "__t_system", trayDisk = "__t_disk"
let trayDocker = "__t_docker", trayMail = "__t_mail"
let trayBatt = "__t_batt", trayUser = "__t_user", trayDownloads = "__t_downloads", trayTrash = "__t_trash"
let trayClock = "__t_clock", trayJoin = "__t_join", trayMore = "__t_more"

/// A background service the tray runs for its items. It runs only while at least one of its items is visible
/// (in the bar or in More ⌃): a hidden item's service is stopped. To add one, add a case with its items here and its
/// start/stop in `TrayModule.start(_:)` / `stop(_:)` (the compiler asks for both).
enum TrayService: String, CaseIterable {
    /// Nearby-network scan (CoreWLAN) for the Wi-Fi panel.
    case wifi
    /// The IOKit power-source notification that updates the battery.
    case power
    /// CPU, memory and energy sampling, and the restart advisor.
    case system
    /// The folder-size scan of the Disk panel.
    case disk
    /// Docker engine discovery, event stream and reconnect watcher.
    case docker
    /// Claude and Codex quota fetches, their file watchers and the pace notifications.
    case usage
    /// IMAP sync, the network monitor and the warm message web view.
    case mail
    /// EventKit observers and the background refresh for the Join button.
    case calendar

    var items: [String] {
        switch self {
        case .wifi: return [trayWifi]
        case .power: return [trayBatt]
        case .system: return [traySystem]
        case .disk: return [trayDisk]
        case .docker: return [trayDocker]
        case .usage: return [trayUsage]
        case .mail: return [trayMail]
        case .calendar: return [trayClock, trayJoin]
        }
    }

    /// Waits for the welcome to finish: it may show Keychain prompts.
    var waitsForWelcome: Bool { self == .usage || self == .mail }
}

enum TrayServicePlan {
    /// Items that cannot be placed (no row in Settings → Tray): always on screen while the tray runs.
    static let alwaysShown: [String] = [trayClock, trayJoin]

    /// The items on screen (bar or More) among `placeable`, plus the ones that are always shown.
    static func visibleItems(_ placeable: [String], place: (String) -> TrayPlace) -> Set<String> {
        Set(placeable.filter { place($0) != .hidden } + alwaysShown)
    }

    /// The services that should run while the tray runs.
    static func wanted(visible: Set<String>, welcomeDone: Bool) -> Set<TrayService> {
        Set(TrayService.allCases.filter { service in
            (welcomeDone || !service.waitsForWelcome) && service.items.contains(where: visible.contains)
        })
    }

    /// What to stop (reverse declaration order) and start (declaration order) to go from `running` to `wanted`.
    /// Services in both sets are left alone, so an unrelated layout change never restarts anything.
    static func transition(from running: Set<TrayService>, to wanted: Set<TrayService>)
        -> (stop: [TrayService], start: [TrayService]) {
        (TrayService.allCases.reversed().filter { running.contains($0) && !wanted.contains($0) },
         TrayService.allCases.filter { wanted.contains($0) && !running.contains($0) })
    }

    /// A click opens a panel only for a shown item. Ids that cannot be placed (More, the clock, Join) always can.
    static func acceptsClick(_ id: String, shown: Set<String>, placeable: [String]) -> Bool {
        !placeable.contains(id) || shown.contains(id)
    }

    /// The free-space reading feeds the Disk item and the restart advisor of the CPU item.
    static func readsDiskInfo(_ visible: Set<String>) -> Bool {
        visible.contains(trayDisk) || visible.contains(traySystem)
    }

    /// One log line for a reconcile that changed something.
    static func summary(running: Set<TrayService>, stopped: [TrayService], started: [TrayService]) -> String {
        func names(_ list: [TrayService]) -> String { list.isEmpty ? "-" : list.map(\.rawValue).joined(separator: ",") }
        return "tray services: running=\(names(TrayService.allCases.filter(running.contains))) "
            + "stopped=\(names(stopped)) started=\(names(started))"
    }
}
