import AppKit

/// Draws the Dock icon of a stack, on the standard macOS 1024 px icon grid.
@MainActor
enum IconRenderer {
    nonisolated static let canvas: CGFloat = 1024
    /// The rounded tile of a macOS app icon: 824 px with a 100 px margin.
    nonisolated static let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    nonisolated static let tileRadius: CGFloat = 185

    /// Bump when the drawing changes, so existing Dock icons are drawn again.
    static let version = 2

    /// Finished stack icons. Views ask for them on every redraw; they are only drawn again when
    /// something they show changed, including an app icon that finished loading.
    private static var cache: [String: NSImage] = [:]

    static func image(for stack: AppStack, pixels: Int = 1024) -> NSImage {
        let catalog = AppCatalog.shared
        let items = stack.orderedItems.prefix(9)
        let key = "\(stack.iconStyle.rawValue)|\(stack.tint.rawValue)|\(pixels)|"
            + items.map { $0.path + (catalog.fullIcon(forPath: $0.path) == nil ? "~" : "") }.joined(separator: "|")
        if let cached = cache[key] { return cached }
        let icons = items.map { catalog.fullIcon(forPath: $0.path) ?? catalog.icon(for: $0) }
        let image = image(style: stack.iconStyle, tint: stack.tint, icons: Array(icons), pixels: pixels)
        if cache.count > 120 { cache.removeAll() }
        cache[key] = image
        return image
    }

    /// Pure drawing; safe to run off the main thread.
    nonisolated static func image(style: IconStyle, tint: StackTint, icons: [NSImage], pixels: Int = 1024) -> NSImage {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
        else { return NSImage(size: NSSize(width: pixels, height: pixels)) }
        rep.size = NSSize(width: canvas, height: canvas)

        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = context
        context?.imageInterpolation = .high
        switch style {
        case .folder: drawFolder(tint: tint, icons: icons)
        case .pile: drawPile(tint: tint, icons: icons)
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: canvas, height: canvas))
        image.addRepresentation(rep)
        return image
    }

    // MARK: Folder (Launchpad style)

    nonisolated private static func drawFolder(tint: StackTint, icons: [NSImage]) {
        let tile = NSBezierPath(roundedRect: tileRect, xRadius: tileRadius, yRadius: tileRadius)

        // Soft drop shadow, as on standard macOS icons.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.shadowBlurRadius = 24
        shadow.set()
        NSColor.black.withAlphaComponent(0.25).setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Body: a gentle vertical gradient, slightly see-through like glass.
        NSGraphicsContext.saveGraphicsState()
        tile.addClip()
        NSColor.clear.set()
        tileRect.fill(using: .copy)
        let (top, bottom) = tint.gradient
        NSGradient(starting: top, ending: bottom)?.draw(in: tile, angle: -90)

        // Specular sheen on the upper half.
        let sheen = NSGradient(colors: [NSColor.white.withAlphaComponent(0.35), NSColor.white.withAlphaComponent(0)])
        sheen?.draw(in: CGRect(x: tileRect.minX, y: tileRect.midY, width: tileRect.width, height: tileRect.height / 2), angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // Thin rim light.
        NSColor.white.withAlphaComponent(0.55).setStroke()
        let rim = NSBezierPath(roundedRect: tileRect.insetBy(dx: 3, dy: 3), xRadius: tileRadius - 3, yRadius: tileRadius - 3)
        rim.lineWidth = 6
        rim.stroke()

        // 3 × 3 grid of mini icons, filled row by row from the top left like a Launchpad folder.
        let inset: CGFloat = 96
        let gap: CGFloat = 36
        let cell = (tileRect.width - inset * 2 - gap * 2) / 3
        for slot in 0..<9 {
            let row = slot / 3, column = slot % 3
            let rect = CGRect(
                x: tileRect.minX + inset + CGFloat(column) * (cell + gap),
                y: tileRect.maxY - inset - cell - CGFloat(row) * (cell + gap),
                width: cell, height: cell)
            if slot < icons.count {
                // App icons carry their own transparent margin (~10 %), so draw them slightly larger.
                icons[slot].draw(in: rect.insetBy(dx: -cell * 0.06, dy: -cell * 0.06),
                                 from: .zero, operation: .sourceOver, fraction: 1)
            } else if icons.isEmpty {
                NSColor.white.withAlphaComponent(0.28).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 8, dy: 8), xRadius: 40, yRadius: 40).fill()
            }
        }
    }

    // MARK: Pile (native stack style)

    /// Three cards stacked straight up, like a native Dock stack: the first app in front, each card
    /// behind it a little smaller and peeking out at the top. Missing apps become cards in the stack's
    /// color, so even a stack with one app never looks like that app alone.
    nonisolated private static func drawPile(tint: StackTint, icons: [NSImage]) {
        let front: CGFloat = 744  // art size of the front card
        let step: CGFloat = 40    // how far each card behind peeks out
        for layer in (0..<3).reversed() {
            let art = front * (1 - 0.06 * CGFloat(layer))
            let top = tileRect.minY + front + step * CGFloat(layer)
            let center = CGPoint(x: canvas / 2, y: top - art / 2)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
            shadow.shadowOffset = NSSize(width: 0, height: -6)
            shadow.shadowBlurRadius = 10
            shadow.set()
            if layer < icons.count {
                // App icons carry the standard margin of the 1024 grid around their art.
                let size = art * canvas / tileRect.width
                icons[layer].draw(in: CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size),
                                  from: .zero, operation: .sourceOver, fraction: 1)
            } else {
                let rect = CGRect(x: center.x - art / 2, y: center.y - art / 2, width: art, height: art)
                let radius = art * tileRadius / tileRect.width
                let card = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
                NSColor.black.withAlphaComponent(0.2).setFill()
                card.fill()
                NSGraphicsContext.restoreGraphicsState()
                NSGraphicsContext.saveGraphicsState()
                let (topColor, bottomColor) = tint.gradient
                NSGradient(starting: topColor, ending: bottomColor)?.draw(in: card, angle: -90)
                NSColor.white.withAlphaComponent(0.55).setStroke()
                let rim = NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 3), xRadius: radius - 3, yRadius: radius - 3)
                rim.lineWidth = 6
                rim.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Colorful placeholder app icons, used for DockStacks' own app icon.
    static func sampleTiles() -> [NSImage] {
        let tints: [StackTint] = [.blue, .orange, .green, .purple, .red, .teal, .yellow, .pink, .graphite]
        return tints.map { tint in
            NSImage(size: NSSize(width: 256, height: 256), flipped: false) { _ in
                let rect = CGRect(x: 26, y: 26, width: 204, height: 204)
                let path = NSBezierPath(roundedRect: rect, xRadius: 46, yRadius: 46)
                let (top, bottom) = tint.gradient
                NSGradient(starting: top.withAlphaComponent(1), ending: bottom.withAlphaComponent(1))?.draw(in: path, angle: -90)
                NSColor.white.withAlphaComponent(0.9).setFill()
                NSBezierPath(ovalIn: CGRect(x: 98, y: 98, width: 60, height: 60)).fill()
                return true
            }
        }
    }

    // MARK: Export

    nonisolated static func pngData(_ image: NSImage) -> Data? {
        guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Writes an .iconset folder (for iconutil) with all standard sizes.
    static func writeIconset(style: IconStyle, tint: StackTint, icons: [NSImage], to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let image = image(style: style, tint: tint, icons: icons, pixels: base * scale)
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try pngData(image)?.write(to: folder.appendingPathComponent(name))
            }
        }
    }
}
