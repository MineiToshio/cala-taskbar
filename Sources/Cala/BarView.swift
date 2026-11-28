import SwiftUI
import AppKit

struct FramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func reportFrame(_ id: String, in space: String = "bar") -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: FramesKey.self, value: [id: g.frame(in: .named(space))])
        })
    }
}

let startID = "__start"
let deskID = "__desk"
let updateID = "__update"

struct BarView: View {
    @ObservedObject var model: TaskbarModel
    @ObservedObject var store: ConfigStore
    @ObservedObject private var updates = UpdateService.shared
    @ObservedObject private var attention = AppAttention.shared
    var screenKey = ""
    var onFrames: ([String: CGRect]) -> Void

    @Environment(\.colorScheme) private var systemScheme
    var theme: BarTheme { BarTheme.named(store.config.theme) }
    var centered: Bool { store.config.alignments[screenKey] == "center" }

    var icons: some View {
        HStack(spacing: 2) {
            StartButton(hovering: model.startHover).reportFrame(startID)
            ForEach(model.items) { item in
                IconButton(item: item, size: store.config.iconSize,
                           hovering: model.hovered?.id == item.id,
                           active: item.pid != nil && item.pid == model.frontPID,
                           badge: model.badge(for: item),
                           windowless: item.pid.map { model.windowless.contains($0) } ?? false,
                           launching: model.launching.contains(item.id),
                           attention: item.pid.map { attention.pids.contains($0) } ?? false)
                    // VoiceOver: the bar's clicks are handled by an event monitor, so give each icon its own action.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.name)
                    .accessibilityValue(item.pid == nil ? tx("Not running", "Cerrada") : (model.badge(for: item).map { tx("Open, \($0) notifications", "Abierta, \($0) avisos") } ?? tx("Open", "Abierta")))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { model.click(item) }
                    .reportFrame(item.id)
                    .opacity(isDragged(item) ? 0 : 1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.items.map(\.id))
    }

    func isDragged(_ item: AppItem) -> Bool { model.dragID == item.id && model.dragScreen == screenKey }

    var body: some View {
        ZStack {
            HStack(spacing: 2) {
                if !centered { icons }
                Spacer(minLength: 8)
                if let version = updates.available?.version { UpdateButton(version: version, hovering: model.updateHover).reportFrame(updateID) }
                if model.trayVisible {
                    JoinPill(model: model)
                    TrayView(model: model, screenKey: screenKey)
                    ClockView(model: model)
                }
                DeskStrip(hovering: model.deskHover).reportFrame(deskID)
            }
            .padding(.leading, centered ? 0 : 8)
            if centered { icons.frame(maxWidth: .infinity, alignment: .center) }
            if let d = model.items.first(where: { isDragged($0) }) {
                IconButton(item: d, size: store.config.iconSize, hovering: true, active: true, badge: nil)
                    .scaleEffect(1.12)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                    .frame(height: store.barHeight)
                    .position(x: model.dragX, y: store.barHeight / 2)
            } else if model.trayVisible, model.dragScreen == screenKey,
                      let id = model.dragID, store.config.barTrayIDs.contains(id) {
                TrayView(model: model, screenKey: screenKey, liftedID: id)
                    .fixedSize(horizontal: true, vertical: false)
                    .scaleEffect(1.12)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                    .frame(height: store.barHeight)
                    .position(x: model.dragX, y: store.barHeight / 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .coordinateSpace(name: "bar")
        .onPreferenceChange(FramesKey.self) { onFrames($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background.opacity(store.config.barOpacity))
        .environment(\.themeAccent, theme.accent)
        .environment(\.colorScheme, theme.dark.map { $0 ? .dark : .light } ?? systemScheme)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5) }
    }
}

/// Shown while a Cala update is available and not skipped. It is drawn like a tray cell (14 pt monochrome glyph over
/// 9.5 pt text, the tray's hover highlight) so it weighs no more than the clock or the battery. The only color is a
/// small dot in the theme accent, the same signal as the Settings sidebar, and nothing moves, so it stays calm however
/// long the update waits. Glyph and version say "new version" without relying on the dot's color.
struct UpdateButton: View {
    @Environment(\.themeAccent) private var accent
    let version: String
    var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: "arrow.down.app").font(.system(size: 14))
                .overlay(alignment: .topTrailing) {
                    Circle().fill(accent).frame(width: 6, height: 6).offset(x: 4, y: -2).accessibilityHidden(true)
                }
            Text(version).font(.system(size: 9.5, weight: .medium)).monospacedDigit().lineLimit(1).fixedSize()
        }
        .foregroundStyle(.primary.opacity(0.85))
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(TrayHighlight(hovering: hovering))
        .contentShape(Rectangle())
        .help(tx("Cala \(version) is available. Click to see what's new and install it.",
                 "Cala \(version) está disponible. Haz clic para ver las novedades e instalarla."))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tx("Cala \(version) update available", "Actualización de Cala \(version) disponible"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { UpdateWindowController.shared.show() }
    }
}

struct IconButton: View {
    @Environment(\.themeAccent) private var accent
    let item: AppItem
    let size: Double
    let hovering: Bool
    let active: Bool
    var badge: String? = nil
    var windowless = false
    var launching = false
    var attention = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let running = item.pid != nil
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(active ? 0.14 : (hovering ? 0.08 : 0)))
            if attention && reduceMotion {
                // Reduce Motion: a steady accent ring instead of the bounce.
                RoundedRectangle(cornerRadius: 6).fill(accent.opacity(0.16))
                RoundedRectangle(cornerRadius: 6).strokeBorder(accent, lineWidth: 1.5)
            }
            Image(nsImage: item.icon)
                .resizable().interpolation(.high)
                .frame(width: size, height: size)
                .modifier(AttentionBounce(active: attention && !reduceMotion))
                .modifier(LaunchPulse(active: launching))
                .frame(maxHeight: .infinity)
            if running && windowless {
                Circle().fill(Color.secondary.opacity(0.7)).frame(width: 4, height: 4).padding(.bottom, 3)
            } else if running {
                Capsule()
                    .fill(active ? accent : Color.secondary)
                    .frame(width: active ? 16 : 6, height: 2.5)
                    .padding(.bottom, 2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let badge { BadgeView(text: badge).offset(x: -2, y: 4) }
        }
        .frame(width: size + 16)
        .padding(.vertical, 3)
    }
}

/// The app asks for attention (the native Dock would bounce it): the icon hops while the request lasts.
struct AttentionBounce: ViewModifier {
    let active: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if active {
            content.keyframeAnimator(initialValue: CGFloat.zero, repeating: true) { icon, y in
                icon.offset(y: y)
            } keyframes: { _ in
                CubicKeyframe(-5, duration: 0.24)
                CubicKeyframe(0, duration: 0.24)
            }
            .transition(.identity)
        } else {
            // Removing the animator also discards its current offset, even when stopped mid-hop.
            content.transition(.identity)
        }
    }
}

struct BadgeView: View {
    let text: String
    var body: some View {
        if Int(text) != nil || text.hasSuffix("+") {
            Text(text)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 16)
                .background(Capsule().fill(Color.red))
        } else {
            Circle().fill(Color.red).frame(width: 10, height: 10)
        }
    }
}

struct DeskStrip: View {
    let hovering: Bool
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(hovering ? 0.14 : 0.0001))
            .frame(width: 10)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.25)).frame(width: 0.5) }
            .accessibilityElement()
            .accessibilityLabel(tx("Show desktop", "Mostrar escritorio"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { (NSApp.delegate as? AppDelegate)?.bar?.toggleDesktop() }
    }
}

struct StartButton: View {
    @Environment(\.themeAccent) private var accent
    let hovering: Bool

    var body: some View {
        Image(systemName: "square.grid.2x2.fill")
            .font(.system(size: 18))
            .foregroundStyle(accent)
            .frame(width: 40)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.08 : 0)).padding(.vertical, 3))
            .accessibilityLabel(tx("All apps", "Todas las apps"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { openAppLauncher() }
    }
}

let trayJoin = "__t_join"

/// "Join" button for the next meeting with a video link: from 5 minutes before it starts until it ends.
/// Clicks are routed by the app delegate (the bar is a non-activating panel), see `trayClick`.
struct JoinPill: View {
    @ObservedObject var model: TaskbarModel
    @ObservedObject private var agenda = CalendarService.shared
    @ObservedObject private var store = ConfigStore.shared
    @Environment(\.themeAccent) private var accent

    private func subtitle(_ e: UpcomingEvent, _ now: Date) -> String {
        let title = e.title.count > 22 ? String(e.title.prefix(21)) + "…" : e.title
        let minutes = Int((e.start.timeIntervalSince(now) / 60).rounded(.up))
        let when = minutes > 0 ? calendarText("in \(minutes) min", "en \(minutes) min") : calendarText("now", "ahora")
        return title + " · " + when
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            if store.config.calendarEnabled, store.config.calendarJoinEnabled,
               let e = CalendarLogic.joinCandidate(agenda.events, now: ctx.date) {
                HStack(spacing: 7) {
                    Image(systemName: "video.fill").font(.system(size: 13))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(calendarText("Join", "Unirse")).font(.system(size: 11.5, weight: .semibold))
                        Text(subtitle(e, ctx.date)).font(.system(size: 9.5)).lineLimit(1).opacity(0.9)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(Capsule().fill(accent).opacity(model.trayHover == trayJoin ? 0.8 : 1))
                .padding(.horizontal, 6)
                .frame(maxHeight: .infinity)
                .reportFrame(trayJoin)
            }
        }
    }
}

struct ClockView: View {
    @ObservedObject var model: TaskbarModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .trailing, spacing: 0) {
                Text(ctx.date, format: .dateTime.hour().minute())
                Text(ctx.date, format: .dateTime.day().month().year())
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .background(TrayHighlight(hovering: model.trayHover == trayClock))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(tx("Shows your calendar", "Muestra tu calendario"))
            .accessibilityAction {
                if let app = (NSApp.delegate as? AppDelegate)?.bar, let bar = app.bars.first { app.trayClick(trayClock, bar: bar) }
            }
            .reportFrame(trayClock)
        }
    }
}

struct TrayView: View {
    @ObservedObject var model: TaskbarModel
    var screenKey = ""
    var liftedID: String? = nil
    @ObservedObject private var store = ConfigStore.shared
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var advisor = RestartAdvisor.shared
    @ObservedObject private var mail = MailService.shared
    @ObservedObject private var docker = DockerService.shared
    @Environment(\.colorScheme) private var scheme

    static func systemSymbol(_ metric: SystemMetric) -> String {
        switch metric {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .heat: return "thermometer.medium"
        }
    }

    var body: some View {
        if let liftedID {
            item(liftedID)
        } else {
            let barIDs = store.config.barTrayIDs
            let preview = model.dragScreen == screenKey ? model.trayDragOrder : nil
            let ids = mergingTrayOrder(barIDs, with: (preview ?? []).filter(Set(barIDs).contains))
            HStack(spacing: 0) {
                if store.config.moreTrayIDs.contains(where: available) {
                    cell(nil, id: trayMore, text: nil, custom: AnyView(TrayGlyph(id: trayMore, model: model)))
                        .reportFrame(trayMore)
                }
                ForEach(ids.filter(available), id: \.self) { id in
                    item(id)
                        .reportFrame(id)
                        .opacity(isLifted(id) ? 0 : 1)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: ids)
        }
    }

    private func available(_ id: String) -> Bool {
        switch id {
        case trayMail: return !mail.accounts.isEmpty
        case trayDocker: return docker.available
        default: return model.trayAvailable(id)
        }
    }

    private func isLifted(_ id: String) -> Bool {
        model.dragID == id && model.dragScreen == screenKey
    }

    private func hovering(_ id: String) -> Bool {
        liftedID == id || ((model.trayDragOrder == nil || model.dragScreen != screenKey) && model.trayHover == id)
    }

    @ViewBuilder func item(_ id: String) -> some View {
        switch id {
        case trayKB:
            if !model.kbCode.isEmpty { cell(nil, id: trayKB, text: model.kbCode) }
        case trayBright:
            if model.hasBright { cell(nil, id: trayBright, text: nil, custom: AnyView(TrayGlyph(id: id, model: model))) }
        case trayUsage:
            UsageTrayView(model: model, hovering: hovering(id))
        case traySystem:
            let snapshot = monitor.snapshot()
            let metric = monitor.shownMetric
            let pending = advisor.visible ? RestartRules.summary(advisor.advice, lang: appLanguage)?.text : nil
            cell(nil, id: traySystem, text: nil, custom: AnyView(VStack(spacing: 3) {
                Image(systemName: Self.systemSymbol(metric)).font(.system(size: 14))
                Text(SystemRules.trayValue(metric, snapshot)).font(.system(size: 9.5, weight: .medium)).monospacedDigit()
                    .lineLimit(1).fixedSize()
            }
            .overlay(alignment: .topTrailing) { if advisor.strongVisible { Circle().fill(StatusColor.color(.pending, dark: scheme == .dark)).frame(width: 7, height: 7).offset(x: 5, y: -2) } }
            .foregroundStyle(monitorTint(monitor, dark: scheme == .dark))))
                .help(SystemRules.trayTooltip(snapshot, pending: pending))
        case trayDisk:
            if let d = model.disk {
                cell(nil, id: trayDisk, text: nil, custom: AnyView(VStack(spacing: 3) {
                    TrayGlyph(id: id, model: model)
                    Text("\(d.freePercent)%").font(.system(size: 9.5, weight: .medium)).monospacedDigit()
                }.foregroundStyle(diskTint(d))))
            }
        case trayDocker:
            if docker.available {
                let title = dockerTrayTitle(docker.state, count: docker.runningCount, crashes: docker.crashed.count)
                cell(nil, id: id, text: nil, custom: AnyView(DockerTrayMark(state: docker.glyph, showCount: true)),
                     accessibilityTitle: title).help(title)
            }
        case trayMail:
            if !mail.accounts.isEmpty {
                let title = mailTrayTitle(mail.unreadCount)
                cell(nil, id: id, text: nil, custom: AnyView(MailTrayGlyph(unread: mail.unreadCount)), accessibilityTitle: title)
                    .help(title)
            }
        case trayBatt:
            if let b = model.batt {
                cell(nil, id: trayBatt, text: nil, custom: AnyView(VStack(spacing: 3) {
                    TrayGlyph(id: id, model: model)
                    Text("\(b.pct)%").font(.system(size: 9.5, weight: .medium))
                }))
            }
        case trayWifi, trayBT, trayVol, trayUser, trayDownloads, trayTrash:
            cell(nil, id: id, text: nil, custom: AnyView(TrayGlyph(id: id, model: model)))
        default:
            EmptyView()
        }
    }

    func cell(_ icon: String?, id: String, text: String?, custom: AnyView? = nil, accessibilityTitle: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let custom { custom }
            if custom == nil, let icon { Image(systemName: icon).font(.system(size: 14)) }
            if let text { Text(text).font(.system(size: 11)) }
        }
        .foregroundStyle(.primary.opacity(0.85))
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(TrayHighlight(hovering: hovering(id)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityTitle ?? (id == trayMore ? tx("More", "Más") : (TrayItems.info(id)?.title ?? "")))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if let app = (NSApp.delegate as? AppDelegate)?.bar, let bar = app.bars.first(where: { $0.screen.key == screenKey }) ?? app.bars.first {
                app.trayClick(id, bar: bar)
            }
        }
    }
}


let trayUsage = "__t_usage_combined"

struct UsageTrayView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: TaskbarModel
    let hovering: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let states = model.usage.filter(\.available)
            if !states.isEmpty {
                HStack(spacing: 10) {
                    ForEach(states) { state in
                        let remaining = state.remaining(context.date)
                        VStack(spacing: 3) {
                            ProviderMark(provider: state.provider).frame(width: 14, height: 14)
                            Text(remaining.map { "\($0)%" } ?? tx("n/a", "n/d"))
                                .font(.system(size: 9.5, weight: .medium)).monospacedDigit().lineLimit(1)
                        }
                        .foregroundStyle(usageColor(remaining, dark: scheme == .dark))
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 9).frame(maxHeight: .infinity)
                .background(TrayHighlight(hovering: hovering))
                .contentShape(Rectangle())
                .help(tx("Claude and Codex · remaining plan usage", "Claude y Codex · uso restante del plan"))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(states.map { $0.provider.title + " " + ($0.remaining(context.date).map { tx("\($0)% left", "\($0)% restante") } ?? tx("unavailable", "no disponible")) }.joined(separator: ", "))
                .accessibilityAddTraits(.isButton)
            }
        }
    }
}

// Keep the tray monochrome except when the remaining quota needs attention.
func usageColor(_ remaining: Int?, dark: Bool = false) -> Color {
    guard let remaining else { return .secondary }
    return FlyoutStyle.quotaText(remaining, dark: dark)
}

/// Small nominative marks, drawn independently rather than tracing trademark assets.
struct ProviderMark: View {
    let provider: UsageProvider
    var colored = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Group {
            if colored { mark.foregroundStyle(providerColor(provider, dark: scheme == .dark)) }
            else { mark }
        }
        .accessibilityHidden(true)
    }
    @ViewBuilder private var mark: some View {
        if provider == .claude { ClaudeSpark().fill() }
        else { CodexPrompt().stroke(style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round)) }
    }
}

func providerColor(_ provider: UsageProvider, dark: Bool) -> Color {
    // Coral and blue/lilac app cues; the darker light-mode ink preserves small-text contrast.
    BarTheme.hex(provider == .claude ? (dark ? 0xE28A6B : 0xA94E32) : (dark ? 0xA6B4FF : 0x4758B8))
}

struct ClaudeSpark: Shape {
    func path(in r: CGRect) -> Path {
        var path = Path()
        // Nine tapered, irregular rays join a solid hub; unlike the brightness sun.
        let rays: [(CGFloat, CGFloat)] = [(-96, 1), (-58, 0.64), (-13, 0.86), (25, 0.72),
                                         (68, 0.96), (110, 0.60), (151, 0.83), (195, 1), (235, 0.70)]
        let unit = min(r.width, r.height)
        for (index, ray) in rays.enumerated() {
            let (degrees, length) = ray
            let angle = degrees * .pi / 180
            let dx = cos(angle), dy = sin(angle)
            let base = unit * 0.18, halfWidth = unit * 0.05625 // 1.8 pt across at 16 pt
            let leading = CGPoint(x: r.midX + dx * base + dy * halfWidth, y: r.midY + dy * base - dx * halfWidth)
            if index == 0 { path.move(to: leading) } else { path.addLine(to: leading) }
            path.addLine(to: CGPoint(x: r.midX + dx * unit * 0.48 * length, y: r.midY + dy * unit * 0.48 * length))
            path.addLine(to: CGPoint(x: r.midX + dx * base - dy * halfWidth, y: r.midY + dy * base + dx * halfWidth))
        }
        path.closeSubpath()
        return path
    }
}

struct CodexPrompt: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        var path = Path()
        // A soft cloud outline and the terminal prompt remain distinct at 14 pt.
        path.move(to: p(0.23, 0.85))
        path.addCurve(to: p(0.2, 0.38), control1: p(-0.03, 0.83), control2: p(-0.01, 0.44))
        path.addCurve(to: p(0.72, 0.3), control1: p(0.16, 0.04), control2: p(0.63, 0.02))
        path.addCurve(to: p(0.8, 0.85), control1: p(1.04, 0.25), control2: p(1.1, 0.83))
        path.closeSubpath()
        path.move(to: p(0.29, 0.43)); path.addLine(to: p(0.43, 0.56)); path.addLine(to: p(0.29, 0.69))
        path.move(to: p(0.55, 0.69)); path.addLine(to: p(0.72, 0.69))
        return path
    }
}
