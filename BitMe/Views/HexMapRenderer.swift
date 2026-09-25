import SwiftUI
import BitMeCore
import UIKit

/// Pure rendering pieces shared by the vector pass and the prerendered
/// bitmap: the odd-r hex projection (y-flipped, +z north — identical to the
/// reference web client), tile styling, and hex paths. No view state.
enum HexMapRenderer {
    static let sqrt3: Double = 3.0.squareRoot()
    /// px/hex at which the vector pass takes over from the bitmap blit.
    static let vectorMinCell: Double = 4
    /// Prerendered bitmap px/hex (the whole 400×400 window, once).
    static let prerenderHexSize: Double = 2

    static let voidColor = Color(red: 16 / 255, green: 20 / 255, blue: 24 / 255)

    // MARK: - Projection

    /// Odd-r shear: `q = x − (z − (z&1)) / 2`, with `floor(z)&1` so
    /// fractional (player) positions shear correctly.
    static func shearQ(x: Double, z: Double) -> Double {
        let odd = Double(Int(z.rounded(.down)) & 1)
        return x - (z - odd) / 2
    }

    /// World-pixel of a (possibly fractional) tile position at hex size 1.
    static func worldPixel(x: Double, z: Double) -> (x: Double, y: Double) {
        let q = shearQ(x: x, z: z)
        return (sqrt3 * q + sqrt3 / 2 * z, -1.5 * z)
    }

    /// World-pixel bounds of a tile rectangle (corners + hex extent).
    static func worldPixelBounds(
        minX: Int, minZ: Int, maxX: Int, maxZ: Int
    ) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        var bounds = (minX: Double.infinity, minY: Double.infinity, maxX: -Double.infinity, maxY: -Double.infinity)
        for (x, z) in [(minX, minZ), (maxX, minZ), (minX, maxZ), (maxX, maxZ)] {
            let p = worldPixel(x: Double(x), z: Double(z))
            bounds.minX = min(bounds.minX, p.x)
            bounds.maxX = max(bounds.maxX, p.x)
            bounds.minY = min(bounds.minY, p.y)
            bounds.maxY = max(bounds.maxY, p.y)
        }
        return bounds
    }

    /// Pointy-side hex path (corners at 60i − 30 degrees), same orientation
    /// as the web map.
    static func appendHex(_ path: inout Path, center: CGPoint, size: Double) {
        for i in 0..<6 {
            let angle = (60.0 * Double(i) - 30.0) * .pi / 180
            let point = CGPoint(x: center.x + size * cos(angle), y: center.y + size * sin(angle))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
    }

    static func hexPath(center: CGPoint, size: Double) -> Path {
        var path = Path()
        appendHex(&path, center: center, size: size)
        return path
    }

    static func clampZoom(_ pxPerHex: Double) -> Double {
        min(64, max(0.8, pxPerHex))
    }

    /// Default view: 16 super-hexes (48 tiles) across the short edge.
    static func defaultZoom(for size: CGSize) -> Double {
        clampZoom(min(size.width, size.height) / (16 * 3 * sqrt3))
    }

    // MARK: - Tile styling

    /// How a tile renders. The BMR1 word is authoritative for *what* is on
    /// the tile (resource / water flag); the BME1 plane supplies elevation
    /// and water depth for the ramps.
    enum TileStyle: Hashable {
        /// Resource hex colored by its (stable, golden-angle) id hue.
        case resource(Int)
        case water(depth: Int, known: Bool)
        case land(elevation: Int16)
        /// No terrain behind this tile yet — leave the void background.
        case uncharted
    }

    static func tileStyle(
        word: UInt16,
        x: Int,
        z: Int,
        terrain: TerrainPlane?,
        entries: [Int: ResourceDictionary.Entry]
    ) -> TileStyle {
        let index = TileWord.dictIndex(word)
        let cell = terrain?.cell(atTileX: x, z: z)
        let liveCell = cell.flatMap { $0.isVoid ? nil : $0 }

        if TileWord.hasResource(word), !TileWord.isWater(word),
           let entry = entries[index], let resourceID = entry.resourceID {
            return .resource(resourceID)
        }
        if TileWord.isWater(word) {
            if let cell = liveCell, cell.waterLevel != TerrainPlane.waterNone {
                return .water(depth: max(1, Int(cell.waterLevel) - Int(cell.elevation)), known: true)
            }
            return .water(depth: 8, known: false)
        }
        guard let cell = liveCell else { return .uncharted }
        return .land(elevation: cell.elevation)
    }

    /// Dark-mode ramps from the reference client: green by elevation
    /// (0–80), blue by depth (0–40).
    static func color(_ style: TileStyle) -> Color {
        switch style {
        case .resource(let resourceID):
            return Color(resourceID: resourceID)
        case .water(let depth, _):
            let t = clamp01(Double(depth) / 40)
            return Color(hue: 210 / 360, saturation: (52 + t * 16) / 100, brightness: (34 - t * 20) / 100)
        case .land(let elevation):
            let t = clamp01(Double(elevation) / 80)
            return Color(hue: 105 / 360, saturation: (36 + t * 16) / 100, brightness: (20 + t * 12) / 100)
        case .uncharted:
            return voidColor
        }
    }

    static func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}

// MARK: - Prerendered window bitmap

/// One-off bitmap of the whole window (terrain + resources), blitted while
/// zoomed out — the mobile analogue of the web map's offscreen canvases.
enum HexMapBitmap {
    struct Rendered {
        let image: UIImage
        /// World-pixel coordinates (hex size 1) of the image's top-left.
        let worldMinX: Double
        let worldMinY: Double
        /// px per hex the bitmap was rendered at.
        let scale: Double
    }

    static func render(_ rep: MapRep, tracked: Set<Int>) -> Rendered? {
        guard let originX = rep.originX, let originZ = rep.originZ,
              let width = rep.width, !rep.words.isEmpty else { return nil }
        var bounds = HexMapRenderer.worldPixelBounds(
            minX: originX, minZ: originZ, maxX: originX + width, maxZ: originZ + width
        )
        let pad = 4.0 // hexes
        let scale = HexMapRenderer.prerenderHexSize
        bounds.minX -= pad
        bounds.minY -= pad
        bounds.maxX += pad
        bounds.maxY += pad
        let pixelWidth = (bounds.maxX - bounds.minX) * scale
        let pixelHeight = (bounds.maxY - bounds.minY) * scale
        guard pixelWidth > 0, pixelHeight > 0, pixelWidth < 8192, pixelHeight < 8192 else { return nil }

        let trackingActive = !tracked.isEmpty
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1 // device scale would balloon the bitmap to ~60 MB
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: pixelWidth, height: pixelHeight), format: format)
        let image = renderer.image { context in
            UIColor(HexMapRenderer.voidColor).setFill()
            context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

            // Color conversion is the expensive part — resolve each distinct
            // (style, faded) pair once and reuse across 160k tiles.
            var uiColors: [StyleKey: UIColor] = [:]
            var paths: [UIColor: UIBezierPath] = [:]
            for r in 0..<width {
                for c in 0..<width {
                    let word = rep.words[r * width + c]
                    guard word != 0 else { continue }
                    let x = originX + c
                    let z = originZ + r
                    let style = HexMapRenderer.tileStyle(word: word, x: x, z: z, terrain: rep.terrain, entries: rep.entries)
                    guard style != .uncharted else { continue }
                    // Untracked resources fade while tracking is active.
                    let faded: Bool
                    if trackingActive, case .resource(let resourceID) = style {
                        faded = !tracked.contains(resourceID)
                    } else {
                        faded = false
                    }
                    let key = StyleKey(style: style, faded: faded)
                    let color: UIColor
                    if let cached = uiColors[key] {
                        color = cached
                    } else {
                        var resolved = UIColor(HexMapRenderer.color(style))
                        if faded { resolved = resolved.withAlphaComponent(0.1) }
                        uiColors[key] = resolved
                        color = resolved
                    }
                    let world = HexMapRenderer.worldPixel(x: Double(x), z: Double(z))
                    appendHex(
                        to: &paths, color: color,
                        center: CGPoint(x: (world.x - bounds.minX) * scale, y: (world.y - bounds.minY) * scale),
                        size: scale
                    )
                }
            }
            for (color, path) in paths {
                color.setFill()
                path.fill()
            }
        }
        return Rendered(image: image, worldMinX: bounds.minX, worldMinY: bounds.minY, scale: scale)
    }

    private struct StyleKey: Hashable {
        let style: HexMapRenderer.TileStyle
        let faded: Bool
    }

    private static func appendHex(to paths: inout [UIColor: UIBezierPath], color: UIColor, center: CGPoint, size: Double) {
        let path = paths[color] ?? UIBezierPath()
        for i in 0..<6 {
            let angle = (60.0 * Double(i) - 30.0) * .pi / 180
            let point = CGPoint(x: center.x + size * cos(angle), y: center.y + size * sin(angle))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.close()
        paths[color] = path
    }
}
