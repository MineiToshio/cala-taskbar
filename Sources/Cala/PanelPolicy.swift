import Foundation

/// The one rule for how an open tray panel and the auto-hiding bar interact. Pure on purpose: no AppKit, so
/// `scripts/check-rules.sh` can run it. A panel opened with a click is never closed by the pointer leaving; only a
/// click outside, Esc or the same tray item again closes it (see FlyoutController).
enum PanelPolicy {
    /// What a mouse press means for an open panel.
    enum Press {
        case inPanel          // inside the panel: the panel handles it
        case onBar            // on the bar: the bar's own click handler decides (it may toggle or switch panels)
        case onMenu           // a pop-up menu raised from the panel (Picker, context menu...)
        case elsewhere        // another window or another app
    }

    /// The bar that owns an open panel must stay out, wherever the pointer is. Other bars hide as usual.
    static func keepsBarVisible(panelOpen: Bool, panelBarIsThisBar: Bool) -> Bool {
        panelOpen && panelBarIsThisBar
    }

    /// Whether an auto-hiding bar slides away now. With a panel open on it, never; otherwise after `delay`
    /// seconds without the pointer on it (or on the screen edge that reveals it).
    static func barShouldHide(autoHide: Bool, barHidden: Bool, pointerNearBar: Bool,
                              panelPinsBar: Bool, secondsSinceInside: TimeInterval, delay: TimeInterval) -> Bool {
        autoHide && !barHidden && !pointerNearBar && !panelPinsBar && secondsSinceInside > delay
    }

    /// Whether a mouse press closes the open panel.
    static func pressClosesPanel(panelOpen: Bool, _ press: Press) -> Bool {
        panelOpen && press == .elsewhere
    }
}
