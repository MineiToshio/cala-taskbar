import AppKit
import SwiftUI

struct DockerWhale: Shape {
    func path(in bounds: CGRect) -> Path {
        let scale = min(bounds.width / 18, bounds.height / 14)
        let x = bounds.midX - 9 * scale, y = bounds.midY - 7 * scale
        func point(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
            CGPoint(x: x + dx * scale, y: y + dy * scale)
        }

        var shape = Path()
        shape.move(to: point(0.4, 8.1))
        shape.addLine(to: point(12.6, 8.1))
        shape.addQuadCurve(to: point(14.7, 7.5), control: point(13.8, 8.1))
        shape.addQuadCurve(to: point(14.5, 5.0), control: point(14.1, 6.4))
        shape.addQuadCurve(to: point(16.1, 6.6), control: point(15.7, 5.5))
        shape.addQuadCurve(to: point(17.8, 6.8), control: point(17.0, 6.4))
        shape.addQuadCurve(to: point(15.5, 8.8), control: point(17.3, 8.3))
        shape.addCurve(to: point(7.5, 13.6), control1: point(13.8, 12.4), control2: point(11.0, 13.6))
        shape.addCurve(to: point(0.4, 8.1), control1: point(3.4, 13.6), control2: point(0.7, 11.8))
        shape.closeSubpath()
        for (row, columns) in [3, 2, 1].enumerated() {
            for column in 0..<columns {
                let top = point(1.5 + CGFloat(column) * 3.65, 5.45 - CGFloat(row) * 2.55)
                shape.addRoundedRect(in: CGRect(origin: top, size: CGSize(width: 3.12 * scale, height: 2.05 * scale)),
                                     cornerSize: CGSize(width: 0.26 * scale, height: 0.26 * scale))
            }
        }
        return shape
    }
}

func dockerTrayTitle(_ state: DockerEngineState, count: Int, crashes: Int) -> String {
    switch state {
    case .running:
        let title = tx("Docker · \(count) running", "Docker · \(count) en marcha")
        if crashes == 1 {
            return tx("\(title) · 1 container crashed", "\(title) · 1 contenedor falló")
        }
        if crashes > 1 {
            return tx("\(title) · \(crashes) containers crashed", "\(title) · \(crashes) contenedores fallaron")
        }
        return title
    case .starting: return tx("Docker · starting", "Docker · iniciando")
    case .stopping: return tx("Docker · stopping", "Docker · deteniendo")
    case .unreachable: return tx("Docker · unreachable", "Docker · sin conexión")
    default: return tx("Docker · off", "Docker · apagado")
    }
}

struct DockerTrayMark: View {
    @Environment(\.colorScheme) private var scheme
    let state: DockerGlyphState
    var showCount = false

    private var tint: Color {
        switch state {
        case .off: return .primary.opacity(0.45)
        case .starting: return StatusColor.color(.attention, dark: scheme == .dark)
        default: return .primary
        }
    }

    var body: some View {
        VStack(spacing: 3) {
            DockerWhale().fill(tint).frame(width: 18, height: 14)
                .overlay(alignment: .topTrailing) {
                    if case .crashed = state {
                        Circle().fill(StatusColor.color(.critical, dark: scheme == .dark))
                            .frame(width: 7, height: 7).offset(x: 4, y: -2)
                    }
                }
            if showCount {
                switch state {
                case .off: EmptyView()
                case .starting: count(tx("…", "…"))
                case .running(let number), .crashed(let number): count(String(number))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func count(_ text: String) -> some View {
        Text(text).font(.system(size: 9.5, weight: .medium)).monospacedDigit().foregroundStyle(tint)
    }
}

struct DockerOverflowGlyph: View {
    @ObservedObject private var service = DockerService.shared
    var body: some View { DockerTrayMark(state: service.glyph) }
}

private extension DockerTab {
    var title: String {
        switch self {
        case .containers: return tx("Containers", "Contenedores")
        case .images: return tx("Images", "Imágenes")
        case .volumes: return tx("Volumes", "Volúmenes")
        }
    }
}

struct DockerPane: View {
    @ObservedObject private var service: DockerService
    @Environment(\.colorScheme) private var scheme
    @Environment(\.themeAccent) private var accent
    @State private var collapsed = Set<String>()
    @State private var search = ""
    @Binding private var confirmation: DockerConfirmation?
    @State private var listHeight: CGFloat = 100
    let availableHeight: CGFloat

    @MainActor init(availableHeight: CGFloat, confirmation: Binding<DockerConfirmation?>) {
        self.availableHeight = availableHeight
        self.service = .shared
        _confirmation = confirmation
    }

    #if DEBUG
    init(availableHeight: CGFloat, fixture: DockerService, collapsed: Set<String> = [], confirmation: String? = nil) {
        self.availableHeight = availableHeight
        self.service = fixture
        _collapsed = State(initialValue: collapsed)
        _confirmation = .constant(fixture.listing.flatMap { listing in
            confirmation.map { DockerConfirmation(key: $0, listing: listing) }
        })
    }
    #endif

    private var running: Bool { service.state == .running }
    private var dark: Bool { scheme == .dark }
    private var tertiary: Color { FlyoutStyle.tertiary(dark: dark) }
    private var critical: Color { StatusColor.color(.critical, dark: dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if running {
                tabs
                if service.tab == .containers && (service.containers?.count ?? 0) > 8 {
                    searchField
                }
                ScrollView {
                    tabContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { listHeight = $0 }
                }
                .frame(height: min(max(1, listHeight), min(420, max(60, availableHeight - 240))))
            } else {
                offCard
            }
            Divider()
            footer
        }
        .onAppear { service.panelOpened() }
        .onDisappear {
            confirmation = nil
            service.panelClosed()
        }
        .onChange(of: service.endpoint?.id) { _, _ in
            collapsed.removeAll()
            search = ""
            confirmation = nil
        }
        .onChange(of: service.listing) { _, _ in confirmation = nil }
        .onChange(of: service.switchingContext) { _, switching in
            if switching { confirmation = nil }
        }
        .onChange(of: service.state) { _, state in
            if state != .running { confirmation = nil }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { _ in
            NotificationCenter.default.post(name: .flyoutRefit, object: nil)
        }
    }

    private var header: some View {
        let shown = service.endpoint
        let contexts = service.selectableContexts
        return VStack(alignment: .leading, spacing: 5) {
            Header(title: tx("Docker", "Docker"))
                .frame(minHeight: 22)
                .overlay(alignment: .trailing) {
                    HStack(spacing: 7) {
                        Circle().fill(engineColor).frame(width: 7, height: 7)
                        Text(engineTitle).font(.system(size: 11.5)).flyoutSecondary()
                        if running && service.canToggle {
                            Toggle(tx("Docker engine", "Motor de Docker"), isOn: Binding(
                                get: { running },
                                set: { service.setEngine($0, shown: shown) }
                            ))
                            .labelsHidden()
                            .disabled(service.switchingContext)
                        }
                    }
                }
            HStack(spacing: 4) {
                if !contexts.isEmpty {
                    Menu {
                        ForEach(contexts) { engine in
                            let title = engine.runtime.displayName ?? tx("Docker engine", "Motor de Docker")
                            Button(tx("\(title) · \(engine.context)", "\(title) · \(engine.context)")) {
                                service.useContext(engine)
                            }
                        }
                    } label: {
                        Text(runtimeName).font(.system(size: 11.5))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(service.switchingContext || service.state == .starting || service.state == .stopping)
                    .accessibilityLabel(tx("Docker context", "Contexto de Docker"))
                } else {
                    Text(runtimeName)
                }
                if running, let list = service.containers, !list.isEmpty {
                    Text(tx("· \(service.runningCount) of \(list.count) running", "· \(service.runningCount) de \(list.count) en marcha"))
                    if let ram = service.ram { Text(tx("· \(size(ram)) RAM", "· \(size(ram)) de RAM")) }
                }
                if service.switchingContext { ProgressView().controlSize(.small) }
            }
            .font(.system(size: 11.5)).flyoutSecondary().lineLimit(1)
            errorLine("engine")
        }
    }

    private var runtimeName: String {
        service.runtime.displayName ?? tx("Docker engine", "Motor de Docker")
    }

    private var engineTitle: String {
        switch service.state {
        case .running: return tx("Running", "En marcha")
        case .starting: return tx("Starting…", "Iniciando…")
        case .stopping: return tx("Stopping…", "Deteniendo…")
        case .unreachable: return tx("Unreachable", "Sin conexión")
        default: return tx("Off", "Apagado")
        }
    }

    private var engineColor: Color {
        switch service.state {
        case .running: return StatusColor.color(.ok, dark: dark)
        case .starting, .stopping: return StatusColor.color(.attention, dark: dark)
        case .unreachable: return critical
        default: return tertiary
        }
    }

    private var tabs: some View {
        HStack(spacing: 3) {
            ForEach(DockerTab.allCases, id: \.self) { tab in
                let selected = tab == service.tab
                Button {
                    confirmation = nil
                    service.select(tab)
                } label: {
                    Text(tab.title).font(.system(size: 11.5, weight: .medium))
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .foregroundStyle(selected ? Color.white : FlyoutStyle.secondary(dark: dark))
                        .background(selected ? FlyoutStyle.controlAccent(dark: dark) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .flyoutSection()
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").flyoutSecondary().accessibilityHidden(true)
            TextField(tx("Search containers", "Buscar contenedores"), text: $search)
                .textFieldStyle(.plain).font(.system(size: 12))
        }
        .padding(7)
        .flyoutSection()
    }

    @ViewBuilder private var tabContent: some View {
        switch service.tab {
        case .containers: containerList
        case .images: imageList
        case .volumes: volumeList
        }
    }

    @ViewBuilder private var containerList: some View {
        if let containers = service.containers {
            let filtered = containers.filter(matchesSearch)
            if containers.isEmpty {
                message("shippingbox", tx("No containers yet", "Aún no hay contenedores"),
                        tx("Create a container with `docker run` or `docker compose up`.",
                           "Crea un contenedor con `docker run` o `docker compose up`."))
            } else if filtered.isEmpty {
                message("magnifyingglass", tx("No matching containers", "No hay contenedores que coincidan"))
            } else {
                VStack(spacing: 8) {
                    ForEach(DockerGroup.build(filtered)) { group in
                        VStack(spacing: 1) {
                            if let project = group.project { projectHeader(project, group: group) }
                            if group.project.map({ !collapsed.contains($0) }) ?? true {
                                ForEach(group.containers) { container in
                                    containerRow(container).padding(.leading, group.project == nil ? 0 : 12)
                                }
                            }
                        }
                        .padding(5).flyoutSection()
                    }
                }
            }
        } else if service.failedLoads.contains(.containers) {
            loadError(tx("Couldn't load containers.", "No se pudieron cargar los contenedores."))
        } else {
            skeleton
        }
    }

    private func matchesSearch(_ container: DockerContainer) -> Bool {
        guard (service.containers?.count ?? 0) > 8 else { return true }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return true }
        return [container.name, container.displayName, container.Image, container.project]
            .compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private func projectHeader(_ project: String, group: DockerGroup) -> some View {
        let closed = collapsed.contains(project)
        let members = service.containers?.filter { $0.project == project } ?? group.containers
        let active = members.contains(where: \.isActive)
        let count = DockerGroup(project: project, containers: members).countLabel
        let busy = members.contains { service.busy[$0.id] != nil }
        let shown = service.listing
        return DockerHoverRow {
            HStack(spacing: 5) {
                Button {
                    if closed { collapsed.remove(project) } else { collapsed.insert(project) }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: closed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold)).frame(width: 10).flyoutSecondary()
                        Image(systemName: "square.stack.3d.up").flyoutSecondary()
                        Text(project).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(count).font(.system(size: 11)).monospacedDigit().foregroundStyle(tertiary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(closed ? tx("Expand project", "Expandir proyecto") : tx("Collapse project", "Contraer proyecto"))
                if busy {
                    ProgressView().controlSize(.small).frame(width: 22)
                } else {
                    iconButton(active ? "stop.fill" : "play.fill",
                               active ? tx("Stop project", "Detener proyecto") : tx("Start project", "Iniciar proyecto")) {
                        collapsed.remove(project)
                        service.act(active ? .stop : .start, on: members.filter { active ? $0.isActive : !$0.isActive }, shown: shown)
                    }
                    .disabled(service.switchingContext)
                }
            }
        }
    }

    private func containerRow(_ container: DockerContainer) -> some View {
        let action = service.busy[container.id]
        let shown = service.listing
        let name = container.displayName
        return DockerHoverRow {
            confirmable(container.id, shown: shown, title: tx("Remove \(name)?", "¿Eliminar \(name)?"), remove: {
                service.act(.remove, on: container, shown: shown)
            }) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle().fill(containerColor(container, action: action)).frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(.system(size: 13)).lineLimit(1)
                            containerSubtitle(container, action: action)
                        }
                        Spacer(minLength: 0)
                        if let publication = container.publishedPort, let url = publication.url {
                            let port = publication.number
                            Button { NSWorkspace.shared.open(url) } label: {
                                HStack(spacing: 3) {
                                    Text(verbatim: ":\(String(port))").monospacedDigit()
                                    Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
                                }
                                .font(.system(size: 10, weight: .medium)).padding(.horizontal, 5).padding(.vertical, 3)
                                .foregroundStyle(.primary).background(accent.opacity(0.14), in: Capsule())
                                .fixedSize()
                            }
                            .buttonStyle(.plain)
                            .help(tx("Open port \(String(port)) in browser", "Abrir el puerto \(String(port)) en el navegador"))
                        }
                        containerActions(container, shown: shown)
                            .disabled(action != nil)
                        iconButton(container.isActive ? "stop.fill" : "play.fill",
                                   container.isActive ? tx("Stop container", "Detener contenedor") : tx("Start container", "Iniciar contenedor")) {
                            service.act(container.isActive ? .stop : .start, on: container, shown: shown)
                        }
                        .disabled(action != nil || service.switchingContext)
                    }
                    errorLine(container.id)
                }
            }
        }
    }

    private func containerActions(_ container: DockerContainer, shown: DockerListing?) -> some View {
        let name = container.displayName
        return actionsMenu(tx("Actions for \(name)", "Acciones de \(name)")) {
            if service.dockerCLI != nil {
                Button { service.logs(container, shown: shown) } label: {
                    Label(tx("Open logs in Terminal", "Abrir registros en Terminal"), systemImage: "doc.text")
                }
                if container.isRunning {
                    Button { service.shell(container, shown: shown) } label: {
                        Label(tx("Open shell in Terminal", "Abrir consola en Terminal"), systemImage: "terminal")
                    }
                }
            }
            if container.isActive {
                Button { service.act(.restart, on: container, shown: shown) } label: {
                    Label(tx("Restart container", "Reiniciar contenedor"), systemImage: "arrow.clockwise")
                }
            } else {
                Button { askToRemove(container.id, shown: shown) } label: {
                    Label(tx("Remove container…", "Eliminar contenedor…"), systemImage: "trash")
                }
            }
        }
    }

    private func containerColor(_ container: DockerContainer, action: DockerContainerAction?) -> Color {
        if action != nil || container.State == "restarting" || container.State == "paused" {
            return StatusColor.color(.attention, dark: dark)
        }
        if service.crashed.contains(container.id) || container.exitCode.map({ $0 != 0 }) == true { return critical }
        return container.isRunning ? StatusColor.color(.ok, dark: dark) : tertiary
    }

    private func containerSubtitle(_ container: DockerContainer, action: DockerContainerAction?) -> some View {
        HStack(spacing: 0) {
            Text(containerStatus(container, action: action)).flyoutSecondary().layoutPriority(1)
            if let image = container.Image, !image.isEmpty {
                Text(verbatim: " · " + image).flyoutTertiary().layoutPriority(-1)
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private func containerStatus(_ container: DockerContainer, action: DockerContainerAction?) -> String {
        switch action {
        case .start: return tx("Starting…", "Iniciando…")
        case .stop: return tx("Stopping…", "Deteniendo…")
        case .restart: return tx("Restarting…", "Reiniciando…")
        case .remove: return tx("Removing…", "Eliminando…")
        case nil: break
        }
        if container.exitCode == 0 { return tx("Stopped", "Detenido") }
        if service.crashed.contains(container.id) {
            if let exit = container.exitCode { return tx("Crashed (\(exit))", "Falló (\(exit))") }
            return tx("Crashed", "Falló")
        }
        if let exit = container.exitCode { return tx("Exited (\(exit))", "Terminó (\(exit))") }
        switch container.State {
        case "running":
            if let elapsed = container.uptimeSeconds {
                let duration = abbreviatedUptime(elapsed)
                return tx("Running · \(duration)", "En marcha · \(duration)")
            }
            return tx("Running", "En marcha")
        case "restarting": return tx("Restarting…", "Reiniciando…")
        case "paused": return tx("Paused", "En pausa")
        case "created": return tx("Created", "Creado")
        default: return tx("Stopped", "Detenido")
        }
    }

    private func abbreviatedUptime(_ seconds: TimeInterval) -> String {
        let unit: (seconds: TimeInterval, label: String)
        switch seconds {
        case ..<60: unit = (1, tx("s", "s"))
        case ..<3_600: unit = (60, tx("min", "min"))
        case ..<86_400: unit = (3_600, tx("h", "h"))
        case ..<604_800: unit = (86_400, tx("d", "d"))
        case ..<2_592_000: unit = (604_800, tx("wk", "sem"))
        case ..<31_536_000: unit = (2_592_000, tx("mo", "mes"))
        default: unit = (31_536_000, tx("yr", "a"))
        }
        let count = (seconds / unit.seconds).rounded(.down).formatted(.number.locale(formattingLocale))
        return tx("\(count) \(unit.label)", "\(count) \(unit.label)")
    }

    @ViewBuilder private var imageList: some View {
        if let images = service.images {
            if images.isEmpty {
                message("shippingbox", tx("No images yet", "Aún no hay imágenes"))
            } else {
                VStack(spacing: 8) {
                    VStack(spacing: 1) {
                        ForEach(images) { image in imageRow(image) }
                    }.padding(5).flyoutSection()
                    pruneRow(images)
                }
            }
        } else if service.failedLoads.contains(.images) {
            loadError(tx("Couldn't load images.", "No se pudieron cargar las imágenes."))
        } else {
            skeleton
        }
    }

    private func imageRow(_ image: DockerImage) -> some View {
        let key = "image:" + image.id
        let reference = image.reference
        let title = reference?.repo ?? tx("Untagged", "Sin etiqueta")
        let removeName = reference.map { $0.repo + ($0.tag.map { ":" + $0 } ?? "") }
            ?? String(image.id.split(separator: ":", maxSplits: 1).last?.prefix(12) ?? "")
        let inUse = service.containers.map { image.inUse(by: $0) }
        let shown = service.listing
        return DockerHoverRow {
            confirmable(key, shown: shown, title: tx("Remove \(removeName)?", "¿Eliminar \(removeName)?"), remove: {
                service.removeImage(image, shown: shown)
            }) {
                itemRow(key: key, icon: "shippingbox", title: title, tag: reference?.tag,
                        subtitle: image.Created.flatMap { $0 > 0 ? relativeTime($0) : nil }) {
                    if inUse == true {
                        let ok = StatusColor.color(.ok, dark: dark)
                        Text(tx("In use", "En uso")).font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.primary).padding(.horizontal, 5).padding(.vertical, 3)
                            .background(ok.opacity(0.13), in: Capsule())
                            .fixedSize()
                    } else if let bytes = image.Size, bytes >= 0 {
                        Text(size(bytes)).font(.system(size: 11)).flyoutTertiary()
                    }
                } actions: {
                    if inUse == false {
                        actionsMenu(tx("Actions for \(removeName)", "Acciones de \(removeName)")) {
                            Button { askToRemove(key, shown: shown) } label: {
                                Label(tx("Remove image…", "Eliminar imagen…"), systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    private func pruneRow(_ images: [DockerImage]) -> some View {
        let unused = service.containers.map { containers in images.filter { !$0.inUse(by: containers) } } ?? []
        let bytes = size(dockerTotal(unused.map(\.Size)))
        let shown = service.listing
        return VStack(alignment: .leading, spacing: 4) {
            if service.pendingRows.contains("prune") {
                HStack { ProgressView().controlSize(.small); Text(tx("Removing unused images…", "Eliminando imágenes sin uso…")) }
                    .font(.system(size: 11)).flyoutSecondary().padding(6)
            } else if !unused.isEmpty {
                confirmable("prune", shown: shown, title: tx("Remove all unused images?", "¿Eliminar todas las imágenes sin uso?"), remove: {
                    service.pruneImages(shown: shown)
                }) {
                    Row(icon: "trash", title: tx("Remove unused images…", "Eliminar imágenes sin uso…"),
                        subtitle: tx("Frees up to \(bytes)", "Libera hasta \(bytes)")) { askToRemove("prune", shown: shown) }
                        .disabled(service.switchingContext)
                }
            }
            errorLine("prune")
        }
    }

    @ViewBuilder private var volumeList: some View {
        if let volumes = service.volumes {
            if volumes.isEmpty {
                message("cylinder", tx("No volumes yet", "Aún no hay volúmenes"))
            } else {
                let sizes = service.usage?.volumeSizes ?? [:]
                VStack(spacing: 1) {
                    ForEach(volumes) { volume in volumeRow(volume, bytes: sizes[volume.id]) }
                }.padding(5).flyoutSection()
            }
        } else if service.failedLoads.contains(.volumes) {
            loadError(tx("Couldn't load volumes.", "No se pudieron cargar los volúmenes."))
        } else {
            skeleton
        }
    }

    private func volumeRow(_ volume: DockerVolume, bytes: Int64?) -> some View {
        let key = "volume:" + volume.id
        let users = service.containers.map(volume.usedBy)
        let names = users?.joined(separator: ", ") ?? ""
        let shown = service.listing
        let subtitle = users.map { $0.isEmpty ? tx("Unused", "Sin uso") : tx("Used by \(names)", "En uso por \(names)") }
        return DockerHoverRow {
            confirmable(key, shown: shown, title: tx("Remove \(volume.id)?", "¿Eliminar \(volume.id)?"),
                        detail: tx("Data will be deleted forever.", "Los datos se borrarán para siempre."), remove: {
                service.removeVolume(volume, shown: shown)
            }) {
                itemRow(key: key, icon: "cylinder", title: volume.id, subtitle: subtitle, subtitleHelp: names) {
                    if let bytes {
                        Text(size(bytes)).font(.system(size: 11)).monospacedDigit().fixedSize().flyoutTertiary()
                    } else if service.usage == nil && !service.usageFailed {
                        SystemLoadingPulse { SystemSkeletonMark().frame(width: 38, height: 9) }.accessibilityHidden(true)
                    }
                } actions: {
                    if users?.isEmpty == true {
                        actionsMenu(tx("Actions for \(volume.id)", "Acciones de \(volume.id)")) {
                            Button { askToRemove(key, shown: shown) } label: {
                                Label(tx("Remove volume…", "Eliminar volumen…"), systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    private func itemRow<Value: View, Actions: View>(key: String, icon: String, title: String, tag: String? = nil,
                                                      subtitle: String?, subtitleHelp: String = "",
                                                      @ViewBuilder value: () -> Value, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: icon).frame(width: 17).flyoutSecondary().accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 0) {
                        Text(title).font(.system(size: 13))
                        if let tag { Text(verbatim: ":" + tag).font(.system(size: 11)).flyoutTertiary() }
                    }.lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 11)).flyoutSecondary().lineLimit(1)
                            .help(subtitleHelp)
                    }
                }
                Spacer(minLength: 2)
                value()
                ZStack {
                    if service.pendingRows.contains(key) { ProgressView().controlSize(.small) }
                    else { actions() }
                }
                .frame(width: 24, height: 24)
            }
            errorLine(key)
        }
    }

    private var offCard: some View {
        let shown = service.endpoint
        return VStack(spacing: 7) {
            if service.state == .starting || service.state == .stopping {
                ProgressView().controlSize(.small)
                if service.state == .starting {
                    Text(tx("This can take a few seconds.", "Puede tardar unos segundos."))
                        .font(.system(size: 11)).flyoutSecondary().multilineTextAlignment(.center)
                }
            } else {
                DockerWhale().fill(FlyoutStyle.secondary(dark: dark)).frame(width: 26, height: 21)
                    .accessibilityHidden(true)
                Text(tx("Docker isn't running", "Docker está apagado")).font(.system(size: 13, weight: .medium))
                if let count = service.containers?.count {
                    Text(count == 1 ? tx("Your container is still saved.", "Tu contenedor sigue guardado.")
                         : tx("Your \(count) containers are still saved.", "Tus \(count) contenedores siguen guardados."))
                        .font(.system(size: 11)).flyoutTertiary()
                }
                if case .unreachable(let reason) = service.state {
                    Text(reasonText(reason)).font(.system(size: 11)).flyoutTertiary()
                        .multilineTextAlignment(.center)
                }
                if service.canToggle {
                    Button {
                        service.setEngine(true, shown: shown)
                    } label: {
                        Text(tx("Start Docker", "Iniciar Docker")).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 6)
                            .background(FlyoutStyle.controlAccent(dark: dark), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .disabled(service.switchingContext)
                } else {
                    Text(tx("Start your Docker engine (e.g. colima start).", "Inicia el motor de Docker (por ejemplo, colima start)."))
                        .font(.system(size: 11)).flyoutTertiary().multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity).padding(12).flyoutSection()
    }

    private func reasonText(_ reason: DockerEngineState.Reason) -> String {
        switch reason {
        case .command: return tx("Couldn't start Docker.", "No se pudo iniciar Docker.")
        case .connection: return tx("The engine isn't responding.", "El motor no responde.")
        case .context: return tx("Choose a local Docker context.", "Elige un contexto local de Docker.")
        case .timedOut: return tx("Docker took too long to start.", "Docker tardó demasiado en iniciar.")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 1) {
            if service.signedIn {
                Text(tx("Signed in to Docker Hub", "Sesión iniciada en Docker Hub"))
                    .font(.system(size: 11)).flyoutSecondary().padding(.vertical, 3)
            } else {
                Row(icon: "person.crop.circle", title: tx("Sign in to Docker Hub…", "Iniciar sesión en Docker Hub…")) { service.login() }
                    .disabled(service.dockerCLI == nil || service.endpoint == nil || service.switchingContext)
                    .help(service.dockerCLI == nil
                          ? tx("The Docker CLI is required to sign in.", "Se necesita la CLI de Docker para iniciar sesión.")
                          : tx("Opens Terminal", "Abre Terminal"))
            }
            errorLine("login")
            if let totals = service.usage?.totals {
                let used = size(totals.used), reclaimable = size(totals.reclaimable)
                Text(tx("Docker uses \(used) · \(reclaimable) reclaimable", "Docker usa \(used) · \(reclaimable) recuperables"))
                    .font(.system(size: 11)).flyoutSecondary().padding(.vertical, 3)
            }
            if service.canOpenRuntime {
                Row(icon: "arrow.up.forward.app", title: tx("Open \(runtimeName)", "Abrir \(runtimeName)")) { service.openRuntime() }
            }
        }
    }

    private func actionsMenu<Items: View>(_ title: String, @ViewBuilder items: () -> Items) -> some View {
        Menu(content: items) {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 24, height: 24)
        .tint(FlyoutStyle.secondary(dark: dark))
        .help(title)
        .accessibilityLabel(title)
        .disabled(service.switchingContext)
    }

    private func iconButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .medium))
                .frame(width: 21, height: 23).contentShape(Rectangle())
        }
        .buttonStyle(.plain).flyoutSecondary().help(label).accessibilityLabel(label)
    }

    private func askToRemove(_ key: String, shown: DockerListing?) {
        guard let shown, shown == service.listing, !service.switchingContext else { return }
        confirmation = DockerConfirmation(key: key, listing: shown)
    }

    private func confirmable<Content: View>(_ key: String, shown: DockerListing?, title: String, detail: String? = nil,
                                             remove: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        let confirming = !service.switchingContext && confirmation?.matches(key, shown: shown) == true
        return content()
            .frame(minHeight: 30)
            .opacity(confirming ? 0 : 1)
            .allowsHitTesting(!confirming)
            .disabled(confirming)
            .accessibilityHidden(confirming)
            .overlay {
                if confirming { confirm(title, detail: detail, remove: remove) }
            }
    }

    private func confirm(_ title: String, detail: String?, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                    .lineLimit(detail == nil ? 2 : 1).truncationMode(.middle).help(title)
                if let detail {
                    Text(detail).font(.system(size: 11)).flyoutSecondary().fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { confirmation = nil } label: {
                Text(tx("Cancel", "Cancelar")).frame(minHeight: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).flyoutSecondary().keyboardShortcut(.cancelAction).fixedSize()
            Button { confirmation = nil; remove() } label: {
                Text(tx("Remove", "Eliminar")).frame(minHeight: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(critical).fixedSize()
        }
        .font(.system(size: 11, weight: .semibold))
    }

    @ViewBuilder private func errorLine(_ key: String) -> some View {
        if let error = service.errors[key] {
            Text(error).font(.system(size: 11)).foregroundStyle(critical).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var skeleton: some View {
        SystemLoadingPulse {
            VStack(spacing: 13) {
                ForEach(0..<3) { index in
                    HStack(spacing: 7) {
                        SystemSkeletonMark().frame(width: 15, height: 15)
                        VStack(alignment: .leading, spacing: 4) {
                            SystemSkeletonMark().frame(width: index == 1 ? 82 : 100, height: 9)
                            SystemSkeletonMark().frame(width: 145, height: 7)
                        }
                        Spacer()
                        SystemSkeletonMark().frame(width: 35, height: 9)
                    }
                }
            }.padding(10).flyoutSection()
        }.accessibilityHidden(true)
    }

    private func loadError(_ text: String) -> some View { message("exclamationmark.circle", text) }

    private func message(_ icon: String, _ title: String, _ subtitle: String? = nil) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 21)).flyoutSecondary().accessibilityHidden(true)
            Text(title).font(.system(size: 13, weight: .medium))
            if let subtitle {
                Text((try? AttributedString(markdown: subtitle, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                     ?? AttributedString(subtitle)).font(.system(size: 11)).flyoutTertiary().multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity).padding(12).flyoutSection()
    }

    private var formattingLocale: Locale { Locale(identifier: tx("en", "es")) }

    private func relativeTime(_ timestamp: TimeInterval) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = formattingLocale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: Date(timeIntervalSince1970: timestamp), relativeTo: Date())
    }

    private func size(_ bytes: Int64) -> String {
        Int64(bytes).formatted(.byteCount(style: .file).locale(formattingLocale))
    }
}

private struct DockerHoverRow<Content: View>: View {
    @State private var hovered = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 5).padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: 29, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hovered ? 0.09 : 0)))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}
