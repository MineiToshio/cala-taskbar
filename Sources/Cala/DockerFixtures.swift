#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum DockerFixtures {
    private struct PaneSample {
        let name: String
        var state: DockerEngineState = .running
        var tab: DockerTab = .containers
        var confirmation: String?
        var empty = false
    }

    private static let desktop = [
        container("api", image: "node:22", state: "running", status: "Up 3 hours", project: "tienda-api", port: 3000),
        container("postgres", image: "postgres:16", state: "running", status: "Up 3 hours",
                  project: "tienda-api", volume: "tienda-api_postgres"),
        container("redis", image: "redis:7", state: "restarting", project: "tienda-api"),
        container("web", image: "wordpress:6", state: "exited", status: "Exited (0)", project: "blog"),
        container("db", image: "mariadb:11", state: "exited", status: "Exited (0)", project: "blog"),
        container("mailpit", image: "axllent/mailpit:latest", state: "running", status: "Up 25 minutes", port: 8025),
        container("minio", image: "minio/minio:latest", state: "exited", status: "Exited (0)", volume: "minio_data"),
        container("worker", image: "tienda-worker:dev", state: "exited", status: "Exited (137)")
    ]

    private static func container(_ name: String, image: String, state: String, status: String? = nil,
                                  project: String? = nil, port: Int? = nil, volume: String? = nil) -> DockerContainer {
        let fullName = project.map { "\($0)-\(name)-1" } ?? name
        return DockerContainer(Id: name, Names: ["/" + fullName], Image: image, ImageID: image,
                               State: state, Status: status, Created: nil,
                               Ports: port.map { [DockerPort(PrivatePort: $0, PublicPort: $0, Type: "tcp", IP: "0.0.0.0")] },
                               Labels: project.map { ["com.docker.compose.project": $0, "com.docker.compose.service": name] },
                               Mounts: volume.map { [DockerMount(Type: "volume", Name: $0)] }, SizeRw: 8_000_000)
    }

    private static func volume(_ name: String, size: Int64, references: Int) -> DockerVolume {
        DockerVolume(Name: name, Driver: "local", CreatedAt: nil, Labels: nil,
                     UsageData: .init(Size: size, RefCount: references))
    }

    private static func service(for sample: PaneSample) -> DockerService {
        let containers = sample.empty ? [] : Array(desktop.prefix(sample.state == .stopped ? 7 : desktop.count))
        let running = sample.state == .running
        let now = Date().timeIntervalSince1970
        let images: [DockerImage] = [
            .init(Id: "node:22", RepoTags: ["node:22"], Size: 1_120_000_000, Created: now - 3 * 86_400, Containers: 1),
            .init(Id: "postgres:16", RepoTags: ["postgres:16"], Size: 435_000_000, Created: now - 7 * 86_400, Containers: 1),
            .init(Id: "alpine:3.21", RepoTags: ["alpine:3.21"], Size: 8_200_000, Created: now - 14 * 86_400, Containers: 0),
            .init(Id: "dangling", RepoTags: ["<none>:<none>"], Size: 318_000_000, Created: now - 2 * 86_400, Containers: 0)
        ]
        let volumes = [
            volume("tienda-api_postgres", size: 358_000_000, references: 1),
            volume("minio_data", size: 780_000_000, references: 1),
            volume("blog_backup", size: 96_000_000, references: 0)
        ]
        let usage = DockerDiskUsage(LayersSize: 2_140_000_000, Images: images, Containers: containers,
                                    Volumes: volumes, BuildCache: nil, ImageUsage: nil, ContainerUsage: nil,
                                    VolumeUsage: nil, BuildCacheUsage: nil)
        return .fixture(state: sample.state, tab: sample.tab, containers: containers, images: running ? images : nil,
                        volumes: running ? volumes : nil, usage: running && !sample.empty ? usage : nil,
                        ram: running ? (sample.empty ? 0 : 1_420_000_000) : nil,
                        crashed: running && !sample.empty ? ["worker"] : [])
    }

    static func run(dir: String, language: String) -> Never {
        _ = NSApplication.shared
        appLanguageOverride = language
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        let panes = [
            PaneSample(name: "01-containers"),
            PaneSample(name: "02-remove-confirm", confirmation: "minio"),
            PaneSample(name: "03-images", tab: .images),
            PaneSample(name: "04-volumes", tab: .volumes),
            PaneSample(name: "05-off", state: .stopped),
            PaneSample(name: "06-starting", state: .starting),
            PaneSample(name: "07-empty", empty: true)
        ]
        let tray: [(String, DockerGlyphState)] = [
            ("08-tray-running", .running(4)), ("09-tray-starting", .starting),
            ("10-tray-off", .off), ("11-tray-crashed", .crashed(4))
        ]
        let spanish = language == "es"
        let selectedPanes = spanish ? panes.filter { ["01-containers", "03-images", "05-off"].contains($0.name) } : panes
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for dark in spanish ? [true] : [false, true] {
                for sample in selectedPanes {
                    let fixture = service(for: sample)
                    let pane = DockerPane(availableHeight: 700, fixture: fixture, collapsed: ["blog"],
                                          confirmation: sample.confirmation)
                        .padding(18).frame(width: 380)
                        .flyoutControls().themedPanel(theme: .named("system"))
                    try png(pane, name: spanish ? sample.name + "-es" : sample.name, dark: dark, in: directory)
                }
                for (name, state) in spanish ? [] : tray {
                    let strip = DockerTrayMark(state: state, showCount: true)
                        .foregroundStyle(.primary.opacity(0.85))
                        .padding(.horizontal, 8)
                        .frame(maxHeight: .infinity)
                        .frame(width: 104, height: 48)
                        .background(BarTheme.named(dark ? "graphite" : "snow").background)
                    try png(strip, name: name, dark: dark, in: directory)
                }
            }
            exit(0)
        } catch {
            fputs("Docker render failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private final class SnapshotWindow: NSWindow {
        override var backingScaleFactor: CGFloat { 2 }
    }

    private enum RenderError: Error { case bitmapUnavailable(String) }

    private static func png<V: View>(_ view: V, name: String, dark: Bool, in directory: URL) throws {
        let filename = "\(name)-\(dark ? "dark" : "light").png"
        let host = NSHostingView(rootView: view.fixedSize()
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.displayScale, 2))
        let window = SnapshotWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 380, height: 600),
                                    styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.close() }

        // The scroll content reports its height back to the pane after the first layout.
        window.orderFrontRegardless()
        for _ in 0..<2 {
            let size = host.fittingSize
            window.setContentSize(size)
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        host.displayIfNeeded()
        let size = host.bounds.size
        let pixelsWide = Int((size.width * 2).rounded(.up))
        let pixelsHigh = Int((size.height * 2).rounded(.up))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw RenderError.bitmapUnavailable(filename)
        }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.bitmapUnavailable(filename)
        }
        try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
        print("\(filename) → \(pixelsWide)×\(pixelsHigh) px")
    }
}
#endif
