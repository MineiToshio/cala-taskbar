import SwiftUI
import AppKit

struct BarTheme: Identifiable {
    let id: String
    let name: String
    let colors: [Color]       // gradient stops, empty = system material
    let accent: Color
    let dark: Bool?           // forced color scheme, nil = follow system

    static let all: [BarTheme] = [
        BarTheme(id: "system", name: tx("System", "Sistema"), colors: [], accent: .accentColor, dark: nil),
        BarTheme(id: "graphite", name: tx("Graphite", "Grafito"), colors: [hex(0x2B2D31), hex(0x1E1F22)], accent: hex(0x5B9DFF), dark: true),
        BarTheme(id: "midnight", name: tx("Midnight", "Medianoche"), colors: [hex(0x141B3A), hex(0x0B1026)], accent: hex(0x7C9CFF), dark: true),
        BarTheme(id: "ocean", name: tx("Ocean", "Océano"), colors: [hex(0x0E7490), hex(0x1D4ED8)], accent: hex(0x7DF9FF), dark: true),
        BarTheme(id: "sunset", name: tx("Sunset", "Atardecer"), colors: [hex(0xF97316), hex(0xDB2777)], accent: hex(0xFFF1B8), dark: true),
        BarTheme(id: "forest", name: tx("Forest", "Bosque"), colors: [hex(0x14532D), hex(0x365314)], accent: hex(0xA3E635), dark: true),
        BarTheme(id: "lavender", name: tx("Lavender", "Lavanda"), colors: [hex(0x7C3AED), hex(0xC026D3)], accent: hex(0xF5D0FE), dark: true),
        BarTheme(id: "candy", name: tx("Candy", "Chicle"), colors: [hex(0xFBCFE8), hex(0xBAE6FD)], accent: hex(0xDB2777), dark: false),
        BarTheme(id: "snow", name: tx("Snow", "Nieve"), colors: [hex(0xF8FAFC), hex(0xE2E8F0)], accent: hex(0x2563EB), dark: false),
    ]

    static func named(_ id: String) -> BarTheme { all.first { $0.id == id } ?? all[0] }
    static func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }

    @ViewBuilder var background: some View {
        if colors.isEmpty { Rectangle().fill(.regularMaterial) }
        else { LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing) }
    }
}

private struct AccentKey: EnvironmentKey { static let defaultValue = Color.accentColor }
extension EnvironmentValues {
    var themeAccent: Color { get { self[AccentKey.self] } set { self[AccentKey.self] = newValue } }
}

/// Opaque surfaces keep small panel text independent of the wallpaper and bar opacity.
enum FlyoutStyle {
    static func surface(dark: Bool) -> Color { BarTheme.hex(dark ? 0x25272D : 0xFFFFFF) }
    static func card(dark: Bool) -> Color { BarTheme.hex(dark ? 0x2D3037 : 0xF4F5F7) }
    static func secondary(dark: Bool) -> Color { BarTheme.hex(dark ? 0xB8BDC8 : 0x626570) }
    static func controlAccent(dark: Bool) -> Color { BarTheme.hex(dark ? 0x0A84FF : 0x007AFF) }
    static func quotaText(_ remaining: Int, dark: Bool) -> Color {
        if remaining >= 25 { return StatusColor.color(.normal, dark: dark) }
        return StatusColor.color(remaining < 10 ? .critical : .attention, dark: dark)
    }
    static func quota(_ remaining: Int, dark: Bool) -> Color {
        remaining < 25 ? quotaText(remaining, dark: dark) : StatusColor.color(.ok, dark: dark)
    }
}

/// The meaning of a status color. Every status signal in the app uses this one palette.
enum StatusTone {
    case normal      // nothing to say: regular text
    case ok          // healthy status
    case attention   // look at this
    case critical    // act now
    case pending     // something to do, not a problem

    init(_ level: SystemLevel) {
        switch level {
        case .normal: self = .normal
        case .attention: self = .attention
        case .critical: self = .critical
        }
    }
}

enum StatusColor {
    private static func hex(_ tone: StatusTone, dark: Bool) -> UInt32? {
        switch tone {
        case .normal: return nil
        case .ok: return dark ? 0x65D5AA : 0x147D59
        case .attention: return dark ? 0xFFB340 : 0xC77700
        case .critical: return dark ? 0xFF6961 : 0xD70015
        case .pending: return dark ? 0x0A84FF : 0x007AFF
        }
    }

    static func color(_ tone: StatusTone, dark: Bool) -> Color {
        hex(tone, dark: dark).map(BarTheme.hex) ?? .primary
    }

    /// Same palette, resolved against the appearance of the view that draws it.
    static func color(_ tone: StatusTone) -> Color {
        guard hex(tone, dark: false) != nil else { return .primary }
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let v = hex(tone, dark: dark) ?? 0
            return NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
                           blue: CGFloat(v & 255) / 255, alpha: 1)
        })
    }

    static func color(for level: SystemLevel, dark: Bool) -> Color { color(StatusTone(level), dark: dark) }
}

struct FlyoutSection: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 11)
        content.background(shape.fill(FlyoutStyle.card(dark: scheme == .dark)))
    }
}

/// Shared tray hover, including the combined usage target and clock.
struct TrayHighlight: View {
    @Environment(\.colorScheme) private var scheme
    let hovering: Bool
    var body: some View {
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: 6)
        shape.fill((dark ? Color.white : .black).opacity(hovering ? (dark ? 0.14 : 0.08) : 0))
            .overlay(shape.strokeBorder(Color.white.opacity(hovering && dark ? 0.10 : 0), lineWidth: 0.5))
            .padding(.vertical, 3)
    }
}

/// Native controls keep active colors even while a nonactivating panel is opening.
struct FlyoutControls: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let blue = FlyoutStyle.controlAccent(dark: scheme == .dark)
        content.tint(blue)
            .toggleStyle(FlyoutSwitchStyle())
            .environment(\.controlActiveState, .active)
    }
}

/// Explicit track paint prevents AppKit's inactive gray from hiding the on state.
struct FlyoutSwitchStyle: ToggleStyle {
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule().fill(configuration.isOn ? FlyoutStyle.controlAccent(dark: scheme == .dark) : Color.primary.opacity(0.15))
                .overlay {
                    Circle().fill(.white).frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                        .offset(x: configuration.isOn ? 8 : -8)
                }
                .frame(width: 38, height: 22)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: configuration.isOn)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }
}

/// Keeps NSSlider's drag, keyboard and accessibility behavior; the bar and thumb appearance are explicit.
final class FlyoutSliderCell: NSSliderCell {
    var activeColor = NSColor.systemBlue
    override func drawBar(inside aRect: NSRect, flipped: Bool) {
        let track = NSRect(x: aRect.minX, y: aRect.midY - 2, width: aRect.width, height: 4)
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let fraction = max(0, min(1, (doubleValue - minValue) / max(0.001, maxValue - minValue)))
        var filled = track; filled.size.width *= fraction
        activeColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
    }
    override func drawKnob(_ knobRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
        shadow.shadowBlurRadius = 2; shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knobRect).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// An NSSlider that never lets a press on it start a window drag. Windows with `isMovableByWindowBackground` ask the
/// view under the pointer; SwiftUI's own `Slider` is wrapped in hosting and portal views that answer "yes", so a drag on
/// its knob could move the whole window. Every slider in the app is this class (or hosted through it).
final class NoWindowDragSlider: NSSlider {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Settings slider: a `NoWindowDragSlider` bound to a Double, snapped to `step` like SwiftUI's `Slider(step:)`.
struct StepSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double

    final class Coordinator: NSObject {
        var parent: StepSlider
        init(_ parent: StepSlider) { self.parent = parent }
        @objc func changed(_ slider: NSSlider) {
            let p = parent
            let snapped = p.step > 0 ? (slider.doubleValue / p.step).rounded() * p.step : slider.doubleValue
            let clamped = min(max(snapped, p.range.lowerBound), p.range.upperBound)
            if slider.doubleValue != clamped { slider.doubleValue = clamped }
            if p.value != clamped { p.value = clamped }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NoWindowDragSlider {
        let slider = NoWindowDragSlider()
        slider.isContinuous = true
        slider.target = context.coordinator; slider.action = #selector(Coordinator.changed(_:))
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }
    func updateNSView(_ slider: NoWindowDragSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound; slider.maxValue = range.upperBound
        if slider.doubleValue != value { slider.doubleValue = value }
    }
}

struct FlyoutSlider: NSViewRepresentable {
    @Environment(\.colorScheme) private var scheme
    @Binding var value: Double
    var onChange: (Double) -> Void

    final class Coordinator: NSObject {
        var parent: FlyoutSlider
        init(_ parent: FlyoutSlider) { self.parent = parent }
        @objc func changed(_ slider: NSSlider) {
            parent.value = slider.doubleValue
            parent.onChange(slider.doubleValue)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSlider {
        let slider = NoWindowDragSlider()
        slider.cell = FlyoutSliderCell()
        slider.minValue = 0; slider.maxValue = 1; slider.isContinuous = true
        slider.target = context.coordinator; slider.action = #selector(Coordinator.changed(_:))
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }
    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        slider.doubleValue = value
        (slider.cell as? FlyoutSliderCell)?.activeColor = NSColor(FlyoutStyle.controlAccent(dark: scheme == .dark))
        slider.needsDisplay = true
    }
}

struct FlyoutSecondary: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.foregroundStyle(FlyoutStyle.secondary(dark: scheme == .dark))
    }
}

/// Shared by every flyout and preview; theme colors tint an opaque neutral base.

struct ThemedPanel: ViewModifier {
    @Environment(\.colorScheme) private var systemScheme
    var radius: CGFloat = 18
    var theme: BarTheme?

    func body(content: Content) -> some View {
        let t = theme ?? BarTheme.named(ConfigStore.shared.config.theme)
        let shape = RoundedRectangle(cornerRadius: radius)
        let dark = t.dark ?? (systemScheme == .dark)
        content
            .background {
                FlyoutStyle.surface(dark: dark)
                if !t.colors.isEmpty {
                    LinearGradient(colors: t.colors, startPoint: .topLeading, endPoint: .bottomTrailing).opacity(0.08)
                }
            }
            .foregroundStyle(.primary)
            .clipShape(shape)
            .overlay(shape.strokeBorder(dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(dark ? 0.24 : 0.12), radius: 12, y: 4)
            .tint(t.accent)
            .environment(\.themeAccent, t.accent)
            .environment(\.colorScheme, t.dark.map { $0 ? .dark : .light } ?? systemScheme)
    }
}
extension View {
    func themedPanel(radius: CGFloat = 18, theme: BarTheme? = nil) -> some View {
        modifier(ThemedPanel(radius: radius, theme: theme))
    }
    func flyoutSection() -> some View { modifier(FlyoutSection()) }
    func flyoutControls() -> some View { modifier(FlyoutControls()) }
    func flyoutSecondary() -> some View { modifier(FlyoutSecondary()) }
}
