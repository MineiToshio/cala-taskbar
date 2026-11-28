import CoreGraphics

struct MenuBarGeometry: Sendable {
    struct Screen {
        let frame: CGRect
        let menuBarHeight: CGFloat
        let unobscuredTopAreas: [CGRect]
    }

    private let regions: [CGRect]

    /// All input rectangles use AppKit coordinates, with the primary display first.
    init(screens: [Screen], fallbackHeight: CGFloat) {
        let primaryHeight = screens.first?.frame.height ?? 0
        regions = screens.flatMap { screen in
            let frame = screen.frame
            let height = screen.menuBarHeight > 0 ? screen.menuBarHeight : fallbackHeight
            let bar = CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
            let areas = screen.unobscuredTopAreas.isEmpty ? [bar] : screen.unobscuredTopAreas
            return areas.compactMap { area -> CGRect? in
                let visible = area.intersection(bar)
                guard !visible.isEmpty else { return nil }
                return CGRect(x: visible.minX, y: primaryHeight - visible.maxY,
                              width: visible.width, height: visible.height)
            }
        }
    }

    func contains(_ axPosition: CGPoint) -> Bool {
        regions.contains { $0.contains(axPosition) }
    }
}
