import AppKit
import SwiftUI

/// Draws a layout's small picture (geometry from `ZoneThumbnails`): the screen as a rounded outline with each zone
/// filled in the accent colour. One drawing routine for the editor's gallery and Settings (SwiftUI) and the
/// menu-bar icon's layout menus (NSImage).
enum ZoneThumbnailRenderer {
    struct Palette {
        var screenFill: CGColor
        var screenStroke: CGColor
        var zoneFill: CGColor
        var zoneStroke: CGColor

        static func make(accent: CGColor, dark: Bool) -> Palette {
            let ink = dark ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1)
            return Palette(screenFill: ink.copy(alpha: dark ? 0.08 : 0.05) ?? ink,
                           screenStroke: ink.copy(alpha: dark ? 0.38 : 0.32) ?? ink,
                           zoneFill: accent.copy(alpha: dark ? 0.42 : 0.30) ?? accent,
                           zoneStroke: accent.copy(alpha: 0.95) ?? accent)
        }
    }

    /// Draws into a context whose y axis grows down (a flipped NSImage or a SwiftUI canvas).
    static func draw(_ zones: [Zone], in context: CGContext, size: CGSize, palette: Palette, scale: CGFloat) {
        let pixel = 1 / max(scale, 1)
        let screen = CGRect(origin: .zero, size: size).insetBy(dx: pixel / 2, dy: pixel / 2)
        let radius = min(3, size.height / 6)
        context.saveGState()
        context.addPath(CGPath(roundedRect: screen, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(palette.screenFill)
        context.fillPath()
        context.addPath(CGPath(roundedRect: screen, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setStrokeColor(palette.screenStroke)
        context.setLineWidth(pixel)
        context.strokePath()

        let inset = size.height < 24 ? 1.5 : 2.5
        let gap = size.height < 24 ? 1.5 : 2
        let rects = zones.map(\.rect)
        let frames = ZoneThumbnails.frames(for: rects, size: size, inset: inset, gap: gap, scale: Double(scale))
        let zoneRadius = min(1.5, size.height / 12)
        for index in ZoneThumbnails.paintingOrder(rects) {
            let frame = frames[index]
            let path = CGPath(roundedRect: frame, cornerWidth: min(zoneRadius, frame.width / 2),
                              cornerHeight: min(zoneRadius, frame.height / 2), transform: nil)
            context.addPath(path)
            context.setFillColor(palette.zoneFill)
            context.fillPath()
            let stroke = frame.insetBy(dx: pixel / 2, dy: pixel / 2)
            guard stroke.width > 0, stroke.height > 0 else { continue }
            context.addPath(CGPath(roundedRect: stroke, cornerWidth: min(zoneRadius, stroke.width / 2),
                                   cornerHeight: min(zoneRadius, stroke.height / 2), transform: nil))
            context.setStrokeColor(palette.zoneStroke)
            context.setLineWidth(pixel)
            context.strokePath()
        }
        context.restoreGState()
    }

    /// For menu items: drawn when shown, so it follows the menu's light or dark appearance.
    static func image(_ zones: [Zone], aspect: Double, fitting box: CGSize = CGSize(width: 52, height: 20),
                      accent: NSColor = .controlAccentColor) -> NSImage {
        let size = ZoneThumbnails.size(aspect: aspect, fitting: box)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let scale = NSGraphicsContext.current.map { $0.cgContext.userSpaceToDeviceSpaceTransform.a } ?? 2
            draw(zones, in: context, size: rect.size, palette: .make(accent: accent.cgColor, dark: dark), scale: max(1, scale))
            return true
        }
        image.accessibilityDescription = tx("\(zones.count) zones", "\(zones.count) zonas")
        return image
    }

    /// Width / height of a screen, for thumbnails drawn at that screen's shape.
    static func aspect(of frame: CGRect) -> Double {
        frame.width > 0 && frame.height > 0 ? Double(frame.width / frame.height) : 16.0 / 10
    }
}

/// A layout's picture at a screen's shape, centred in its box.
struct ZoneThumbnailView: View {
    let zones: [Zone]
    let aspect: Double
    let box: CGSize
    var accent: Color = .accentColor
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var scale

    var body: some View {
        let size = ZoneThumbnails.size(aspect: aspect, fitting: box)
        let dark = scheme == .dark
        let palette = ZoneThumbnailRenderer.Palette.make(accent: NSColor(accent).cgColor, dark: dark)
        Canvas { context, canvasSize in
            context.withCGContext { cg in
                ZoneThumbnailRenderer.draw(zones, in: cg, size: canvasSize, palette: palette, scale: scale)
            }
        }
        .frame(width: size.width, height: size.height)
        .frame(width: box.width, height: box.height)
        .accessibilityHidden(true)
    }
}
