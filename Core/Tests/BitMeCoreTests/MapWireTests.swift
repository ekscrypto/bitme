import Testing
import Foundation
@testable import BitMeCore

/// Binary wire format tests for the resource-map endpoints (docs/api.md
/// §6–7). Buffers are hand-packed little-endian bytes matching the layout
/// the reference web client decodes; the super-hex math table was
/// cross-checked against that client's implementation.
struct MapWireTests {
    // MARK: - Byte pack helpers

    private func le16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    private func le32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }

    private func i32(_ value: Int32) -> Data {
        le32(UInt32(bitPattern: value))
    }

    private func magic(_ text: String) -> Data {
        Data(text.utf8)
    }

    // MARK: - Tile words

    @Test func tileWordBits() {
        #expect(TileWord.dictIndex(0x0405) == 5)
        #expect(TileWord.isOrigin(0x0405))
        #expect(TileWord.direction(0x1C00) == 3)
        #expect(TileWord.isPaving(0x4007))
        #expect(TileWord.isWater(0x8005))
        // hasResource: index present and not the paving namespace.
        #expect(TileWord.hasResource(0x0005))
        #expect(TileWord.hasResource(0x8005)) // fishing spots live on water
        #expect(!TileWord.hasResource(0x4007))
        #expect(!TileWord.hasResource(0x8000)) // water-only = emptied
        #expect(!TileWord.hasResource(0x0000))
    }

    // MARK: - BMR1

    @Test func bmr1DecodesHeaderAndWords() throws {
        let width = 4
        var data = magic("BMR1")
        data.append(le16(1))                       // version
        data.append(le16(UInt16(width)))           // width
        data.append(i32(-10))                      // origin_x
        data.append(i32(20))                       // origin_z
        data.append(le32(7))                       // region
        data.append(le32(5))                       // dict_version
        var words = [UInt16](repeating: 0, count: width * width)
        words[0] = 0x0205                          // (x -10, z 20)
        words[2 * width + 1] = 0x8007              // (x -9 + 1, z 22)
        for word in words { data.append(le16(word)) }

        let window = try ResourceWindow(data: data)
        #expect(window.region == 7)
        #expect(window.dictVersion == 5)
        #expect(window.originX == -10)
        #expect(window.originZ == 20)
        #expect(window.width == 4)
        #expect(window.words == words)
        #expect(window.word(atX: -10, z: 20) == 0x0205)
        #expect(window.word(atX: -9, z: 22) == 0x8007)
        #expect(window.word(atX: -11, z: 20) == nil) // outside
        #expect(window.word(atX: -10 + 4, z: 20) == nil)
        #expect(window.centerX == -8)
        #expect(window.centerZ == 22)
    }

    @Test func bmr1RejectsBadBuffers() throws {
        #expect(throws: MapWireError.self) {
            try ResourceWindow(data: magic("XXXX") + Data(repeating: 0, count: 64))
        }
        var wrongVersion = magic("BMR1")
        wrongVersion.append(le16(2))
        #expect(throws: MapWireError.self) {
            try ResourceWindow(data: wrongVersion + Data(repeating: 0, count: 64))
        }
        #expect(throws: MapWireError.self) {
            try ResourceWindow(data: magic("BMR1")) // truncated header
        }
    }

    // MARK: - BMD1

    @Test func bmd1DecodesWorldCoordinateChanges() throws {
        var data = magic("BMD1")
        data.append(le16(1))      // version
        data.append(le32(14))     // region
        data.append(le32(104_049_8922))
        data.append(le16(2))      // count
        data.append(i32(-5)); data.append(i32(7)); data.append(le16(0x8CDB))
        data.append(i32(28_919)); data.append(i32(19_960)); data.append(le16(0x8000))

        let delta = try ResourceTileDelta(data: data)
        #expect(delta.region == 14)
        #expect(delta.dictVersion == 1_040_498_922)
        #expect(delta.changes.count == 2)
        #expect(delta.changes[0] == .init(x: -5, z: 7, word: 0x8CDB))
        #expect(delta.changes[1] == .init(x: 28_919, z: 19_960, word: 0x8000))
    }

    @Test func bmd1RejectsTruncatedBody() {
        var data = magic("BMD1")
        data.append(le16(1))
        data.append(le32(14))
        data.append(le32(1))
        data.append(le16(3)) // claims 3 changes, only room for none
        #expect(throws: MapWireError.self) {
            try ResourceTileDelta(data: data)
        }
    }

    // MARK: - BME1

    @Test func bme1DecodesTerrainPlane() throws {
        // 2×1 plane whose cell (0,0) super center tile is (10, 6):
        // originSuperZ = floor(6/3) = 2; originSuperX = floor((10 - 1)/3) = 3.
        var data = magic("BME1")
        data.append(le16(2))      // version
        data.append(le16(2))      // width (super columns)
        data.append(le16(1))      // height (super rows)
        data.append(i32(10))      // origin_center_world_x
        data.append(i32(6))       // origin_center_world_z
        data.append(le32(7))      // region
        data.append(le32(41))     // generation
        // Cell 0: land — elevation 40, original 42, no water.
        let landLo = UInt32(UInt16(bitPattern: 40)) | UInt32(UInt16(bitPattern: 42)) << 16
        let landHi = UInt32(UInt16(bitPattern: TerrainPlane.waterNone))
        // Cell 1: underwater — elevation 5, water 10, body type 3.
        let waterLo = UInt32(UInt16(bitPattern: 5)) | UInt32(UInt16(bitPattern: 5)) << 16
        let waterHi = UInt32(UInt16(bitPattern: 10)) | 3 << 16
        data.append(le32(landLo)); data.append(le32(landHi))
        data.append(le32(waterLo)); data.append(le32(waterHi))

        let plane = try TerrainPlane(data: data)
        #expect(plane.region == 7)
        #expect(plane.generation == 41)
        #expect(plane.originSuperX == 3)
        #expect(plane.originSuperZ == 2)
        #expect(plane.width == 2)
        #expect(plane.height == 1)

        // Tile (10, 6) → super (3, 2) → cell (0, 0): land.
        let land = try #require(plane.cell(atTileX: 10, z: 6))
        #expect(!land.isVoid)
        #expect(land.elevation == 40)
        #expect(land.originalElevation == 42)
        #expect(land.waterLevel == TerrainPlane.waterNone)
        #expect(!land.isUnderwater)

        // Tile (12, 6) → super (4, 2) → cell (0, 1): underwater.
        let water = try #require(plane.cell(atTileX: 12, z: 6))
        #expect(water.elevation == 5)
        #expect(water.waterLevel == 10)
        #expect(water.waterBodyType == 3)
        #expect(water.isUnderwater)

        // Far-away tile maps outside the plane.
        #expect(plane.cell(atTileX: 900, z: 900) == nil)
        #expect(!plane.coversTile(x: 900, z: 900))
        #expect(plane.coversTile(x: 10, z: 6))
        #expect(plane.coversTile(x: 12, z: 6))
    }

    // MARK: - Super-hex math (cross-checked against the reference client)

    @Test func tileToSuperOffsetMatchesReferenceClient() {
        // (x, z) → (super E, super N)
        let reference: [((Int, Int), (Int, Int))] = [
            ((0, 0), (0, 0)),
            ((5, 5), (2, 2)),
            ((-5, -5), (-2, -2)),
            ((28_910, 19_839), (9_636, 6_613)),
            ((11_173, 13_848), (3_724, 4_616)),
            ((-1, -2), (-1, -1)),
            ((7, -8), (2, -3)),
            ((10_213, 12_367), (3_404, 4_122)),
            ((-400_001, -400_002), (-133_334, -133_334)),
        ]
        for ((x, z), expected) in reference {
            let superOffset = SuperHexMath.tileToSuperOffset(x: x, z: z)
            #expect(superOffset.x == expected.0, "super E for tile (\(x), \(z))")
            #expect(superOffset.z == expected.1, "super N for tile (\(x), \(z))")
        }
    }

    @Test func superOffsetRoundTripsThroughCenterTile() {
        for n in [-13, -2, 0, 1, 2, 7, 6613] {
            for e in [-13, -2, 0, 1, 2, 9636] {
                let center = SuperHexMath.centerTile(n: n, e: e)
                #expect(center.x == e * 3 + (n & 1))
                #expect(center.z == n * 3)
                let back = SuperHexMath.tileToSuperOffset(x: center.x, z: center.z)
                #expect(back.x == e)
                #expect(back.z == n)
            }
        }
    }

    // MARK: - ResourceMapEngine

    private var sampleWindow: ResourceWindow {
        var words = [UInt16](repeating: 0, count: 16)
        words[0] = 0x0003              // (0,0) resource 3
        words[1] = 0x0003              // (1,0) resource 3
        words[2] = 0x4004              // (2,0) paving — not tallied
        words[15] = 0x8005             // (3,3) resource 5 on water
        return ResourceWindow(
            region: 7, dictVersion: 5,
            originX: 98, originZ: 98, width: 4, words: words
        )
    }

    @Test func tallyCountsResourceTilesOnly() {
        let (counts, populated) = ResourceMapEngine.tally(of: sampleWindow)
        #expect(counts == [3: 2, 5: 1])
        #expect(populated == 3)
    }

    @Test func applyingDeltaUpdatesWordsAndReportsTransitions() throws {
        let applied = try #require(ResourceMapEngine.applying(
            ResourceTileDelta(region: 7, dictVersion: 5, changes: [
                .init(x: 98, z: 98, word: 0x0000),       // despawn resource 3
                .init(x: 99, z: 98, word: 0x8006),       // replace 3 → 6
                .init(x: 500, z: 500, word: 0x0007),     // out of window — ignored
                .init(x: 100, z: 98, word: 0x4004),      // identical — skipped
            ]),
            to: sampleWindow
        ))
        #expect(applied.transitions.map(\.newIndex) == [0, 6])
        #expect(applied.window.word(atX: 98, z: 98) == 0)
        #expect(applied.window.word(atX: 99, z: 98) == 0x8006)
        #expect(applied.window.word(atX: 101, z: 101) == 0x8005) // untouched
    }

    @Test func applyingDeltaRejectsDictionaryGenerationMismatch() {
        let stale = ResourceMapEngine.applying(
            ResourceTileDelta(region: 7, dictVersion: 6, changes: [
                .init(x: 98, z: 98, word: 0x0000),
            ]),
            to: sampleWindow
        )
        #expect(stale == nil)
    }

    @Test func applyingAllNoOpDeltaKeepsWindow() throws {
        let applied = try #require(ResourceMapEngine.applying(
            ResourceTileDelta(region: 7, dictVersion: 5, changes: [
                .init(x: 98, z: 98, word: 0x0003), // identical word
            ]),
            to: sampleWindow
        ))
        #expect(applied.transitions.isEmpty)
        #expect(applied.window == sampleWindow)
    }
}
