import Foundation

/// Binary wire codecs for the relay's live resource-map formats
/// (docs/api.md §6–7). Byte-for-byte compatible with the reference web
/// client (`bitcraftsync.app/x-ray`):
///
/// - **BMR1** — a `width × width` odd-r small-hex resource window anchored
///   at `origin`, one LE u16 *tile word* per tile.
/// - **BMD1** — a change-stream delta frame over the same tile-word layout
///   in absolute world coordinates (the live spawn/despawn feed).
/// - **BME1** — a super-hex terrain plane: one LE u64 per true super-hex
///   (3× tile scale, odd-r shear).
enum MapWireError: Error, Equatable {
    case badMagic(String, expected: String)
    case unsupportedVersion(Int, expected: Int)
    case truncated(byteLength: Int, minimum: Int)
}

// MARK: - Tile words (BMR1/BMD1 shared layout)

/// Bit layout of a BMR1/BMD1 tile word: 0–9 dictionary index, 10
/// origin/anchor flag, 11–13 footprint direction, 14 paving namespace,
/// 15 water. Word 0 (and water-only words, index 0) = no resource.
public enum TileWord {
    public static func dictIndex(_ word: UInt16) -> Int { Int(word & 0x3FF) }
    public static func isOrigin(_ word: UInt16) -> Bool { word & 0x0400 != 0 }
    public static func direction(_ word: UInt16) -> Int { Int((word >> 11) & 0x7) }
    public static func isPaving(_ word: UInt16) -> Bool { word & 0x4000 != 0 }
    public static func isWater(_ word: UInt16) -> Bool { word & 0x8000 != 0 }
    /// A resource occupies this tile (dictionary index present, not paving).
    public static func hasResource(_ word: UInt16) -> Bool { word & 0x3FF != 0 && word & 0x4000 == 0 }
}

// MARK: - BMR1 resource window

/// A decoded BMR1 resource window. `words` is row-major in +z rows / +x
/// columns, relative to `originX`/`originZ` (top-left tile).
public struct ResourceWindow: Equatable, Sendable {
    public let region: Int
    public let dictVersion: Int
    public let originX: Int
    public let originZ: Int
    public let width: Int
    public let words: [UInt16]

    public init(data: Data) throws {
        guard data.count >= 24 else { throw MapWireError.truncated(byteLength: data.count, minimum: 24) }
        let magic = String(bytes: data.prefix(4), encoding: .ascii) ?? ""
        guard magic == "BMR1" else { throw MapWireError.badMagic(magic, expected: "BMR1") }
        let version = data.leU16(at: 4)
        guard version == 1 else { throw MapWireError.unsupportedVersion(Int(version), expected: 1) }
        let width = Int(data.leU16(at: 6))
        let expected = 24 + width * width * 2
        guard data.count >= expected else {
            throw MapWireError.truncated(byteLength: data.count, minimum: expected)
        }
        self.region = Int(data.leU32(at: 16))
        self.dictVersion = Int(data.leU32(at: 20))
        self.originX = Int(Int32(bitPattern: data.leU32(at: 8)))
        self.originZ = Int(Int32(bitPattern: data.leU32(at: 12)))
        self.width = width
        var words = [UInt16]()
        words.reserveCapacity(width * width)
        for i in 0..<(width * width) {
            words.append(data.leU16(at: 24 + i * 2))
        }
        self.words = words
    }

    public init(region: Int, dictVersion: Int, originX: Int, originZ: Int, width: Int, words: [UInt16]) {
        self.region = region
        self.dictVersion = dictVersion
        self.originX = originX
        self.originZ = originZ
        self.width = width
        self.words = words
    }

    /// Tile word at absolute world tile (x, z); nil outside this window.
    public func word(atX x: Int, z: Int) -> UInt16? {
        guard let index = wordIndex(x: x, z: z) else { return nil }
        return words[index]
    }

    /// Row-major word index for an absolute tile; nil outside the window.
    public func wordIndex(x: Int, z: Int) -> Int? {
        let c = x - originX
        let r = z - originZ
        guard c >= 0, r >= 0, c < width, r < width else { return nil }
        return r * width + c
    }

    /// Center tile of the window (the anchor the session endpoint centers on).
    public var centerX: Int { originX + width / 2 }
    public var centerZ: Int { originZ + width / 2 }
}

// MARK: - BMD1 change-stream delta

/// One decoded BMD1 frame: world-coordinate tile changes sharing the
/// window's word layout. A 0 / water-only word means the tile emptied.
public struct ResourceTileDelta: Equatable, Sendable {
    public struct TileChange: Equatable, Sendable {
        public let x: Int
        public let z: Int
        public let word: UInt16

        public init(x: Int, z: Int, word: UInt16) {
            self.x = x
            self.z = z
            self.word = word
        }
    }

    public let region: Int
    public let dictVersion: Int
    public let changes: [TileChange]

    public init(data: Data) throws {
        guard data.count >= 16 else { throw MapWireError.truncated(byteLength: data.count, minimum: 16) }
        let magic = String(bytes: data.prefix(4), encoding: .ascii) ?? ""
        guard magic == "BMD1" else { throw MapWireError.badMagic(magic, expected: "BMD1") }
        let version = data.leU16(at: 4)
        guard version == 1 else { throw MapWireError.unsupportedVersion(Int(version), expected: 1) }
        let count = Int(data.leU16(at: 14))
        let expected = 16 + count * 10
        guard data.count >= expected else {
            throw MapWireError.truncated(byteLength: data.count, minimum: expected)
        }
        self.region = Int(data.leU32(at: 6))
        self.dictVersion = Int(data.leU32(at: 10))
        var changes = [TileChange]()
        changes.reserveCapacity(count)
        for i in 0..<count {
            let o = 16 + i * 10
            changes.append(TileChange(
                x: Int(Int32(bitPattern: data.leU32(at: o))),
                z: Int(Int32(bitPattern: data.leU32(at: o + 4))),
                word: data.leU16(at: o + 8)
            ))
        }
        self.changes = changes
    }

    public init(region: Int, dictVersion: Int, changes: [TileChange]) {
        self.region = region
        self.dictVersion = dictVersion
        self.changes = changes
    }
}

// MARK: - BME1 terrain plane

/// The game's terrain lattice: a true hex grid at 3× tile scale (odd super
/// rows sheared one tile east). Axial, each component rounded to the
/// nearest third, back to odd-r at super scale; corner tiles resolve to
/// the nearest super.
public enum SuperHexMath {
    /// Floor division (JS `Math.floor(a / b)` semantics for negative a).
    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        let r = a % b
        return (r != 0 && (r < 0) != (b < 0)) ? q - 1 : q
    }

    /// World tile (odd-r) → super-hex N/E offset. Exact integer form of the
    /// reference `q = x - (z - (z & 1)) / 2; Q = floorDiv(q + 1, 3)` with q
    /// kept scaled ×2 (q is always n.0 or n.5, so `floor((q+1)/3)` equals
    /// `floorDiv(2q + 2, 6)`).
    public static func tileToSuperOffset(x: Int, z: Int) -> (x: Int, z: Int) {
        let q2 = 2 * x - (z - (z & 1))
        let bigQ = floorDiv(q2 + 2, 6)
        let n = floorDiv(z + 1, 3)
        return (bigQ + (n - (n & 1)) / 2, n)
    }

    /// Super N/E offset → its center tile.
    public static func centerTile(n: Int, e: Int) -> (x: Int, z: Int) {
        (e * 3 + (n & 1), n * 3)
    }
}

/// A decoded BME1 v2 terrain plane. Cells are row-major in super offset
/// space: cell (r, c) is the super at `origin + (c, r)`. Cell (0,0)'s
/// center tile is carried in the header; the super origin is recovered
/// from it (`center tile of super (X, Z) is (3X + (Z&1), 3Z)`).
public struct TerrainPlane: Equatable, Sendable {
    public static let waterNone = Int16.min

    public struct Cell: Equatable, Sendable {
        /// Low u32: bits 0–15 elevation, 16–31 original elevation (i16s).
        public let lo: UInt32
        /// High u32: bits 0–15 water level (i16, `waterNone` = none),
        /// 16–23 water body type.
        public let hi: UInt32

        public var elevation: Int16 { Int16(bitPattern: UInt16(truncatingIfNeeded: lo)) }
        public var originalElevation: Int16 { Int16(bitPattern: UInt16(truncatingIfNeeded: lo >> 16)) }
        public var waterLevel: Int16 { Int16(bitPattern: UInt16(truncatingIfNeeded: hi)) }
        public var waterBodyType: Int { Int((hi >> 16) & 0xFF) }
        /// Both halves zero — the cell is outside the region.
        public var isVoid: Bool { lo == 0 && hi == 0 }
        public var isUnderwater: Bool { waterLevel != TerrainPlane.waterNone && elevation < waterLevel }
    }

    public let region: Int
    public let generation: Int
    public let originSuperX: Int
    public let originSuperZ: Int
    public let width: Int
    public let height: Int
    public let lo: [UInt32]
    public let hi: [UInt32]

    public init(data: Data) throws {
        guard data.count >= 26 else { throw MapWireError.truncated(byteLength: data.count, minimum: 26) }
        let magic = String(bytes: data.prefix(4), encoding: .ascii) ?? ""
        guard magic == "BME1" else { throw MapWireError.badMagic(magic, expected: "BME1") }
        let version = data.leU16(at: 4)
        guard version == 2 else { throw MapWireError.unsupportedVersion(Int(version), expected: 2) }
        let width = Int(data.leU16(at: 6))
        let height = Int(data.leU16(at: 8))
        let count = width * height
        let expected = 26 + count * 8
        guard data.count >= expected else {
            throw MapWireError.truncated(byteLength: data.count, minimum: expected)
        }
        let originCenterX = Int(Int32(bitPattern: data.leU32(at: 10)))
        let originCenterZ = Int(Int32(bitPattern: data.leU32(at: 14)))
        self.region = Int(data.leU32(at: 18))
        self.generation = Int(data.leU32(at: 22))
        let originSuperZ = SuperHexMath.floorDiv(originCenterZ, 3)
        let originSuperX = SuperHexMath.floorDiv(originCenterX - (originSuperZ & 1), 3)
        self.originSuperX = originSuperX
        self.originSuperZ = originSuperZ
        self.width = width
        self.height = height
        var lo = [UInt32]()
        var hi = [UInt32]()
        lo.reserveCapacity(count)
        hi.reserveCapacity(count)
        for i in 0..<count {
            let o = 26 + i * 8
            lo.append(data.leU32(at: o))
            hi.append(data.leU32(at: o + 4))
        }
        self.lo = lo
        self.hi = hi
    }

    public init(
        region: Int, generation: Int, originSuperX: Int, originSuperZ: Int,
        width: Int, height: Int, lo: [UInt32], hi: [UInt32]
    ) {
        self.region = region
        self.generation = generation
        self.originSuperX = originSuperX
        self.originSuperZ = originSuperZ
        self.width = width
        self.height = height
        self.lo = lo
        self.hi = hi
    }

    /// Terrain cell covering a world tile (its nearest super); nil when the
    /// tile's super falls outside this plane.
    public func cell(atTileX x: Int, z: Int) -> Cell? {
        let s = SuperHexMath.tileToSuperOffset(x: x, z: z)
        let c = s.x - originSuperX
        let r = s.z - originSuperZ
        guard c >= 0, r >= 0, c < width, r < height else { return nil }
        let i = r * width + c
        return Cell(lo: lo[i], hi: hi[i])
    }

    /// Whether the plane's super-grid bounds cover a world tile (the cell
    /// may still be void — coverage, not validity).
    public func coversTile(x: Int, z: Int) -> Bool {
        cell(atTileX: x, z: z) != nil
    }
}

// MARK: - Little-endian reads

private extension Data {
    func leU16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func leU32(at offset: Int) -> UInt32 {
        UInt32(self[startIndex + offset])
            | UInt32(self[startIndex + offset + 1]) << 8
            | UInt32(self[startIndex + offset + 2]) << 16
            | UInt32(self[startIndex + offset + 3]) << 24
    }
}
