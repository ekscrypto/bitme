import SwiftUI
import BitMeCore
import UIKit

/// The odd-r hex grid map — the mobile counterpart of the X-Ray web map,
/// and X-Ray's root screen.
///
/// Rendering follows the reference client's strategy: the BMR1 window is
/// prerendered once into a bitmap (2 px/hex) and blitted while zoomed out;
/// at ≥ 4 px/hex the visible tiles are drawn as vector hexes (crisper, and
/// anchor dots make multi-tile footprints legible). Terrain colors come
/// from the BME1 plane (elevation ramp / water depth), resource colors are
/// a stable golden-angle hue per resource id. Deltas from the change
/// stream bump `MapRep.tileVersion`, which re-keys the prerender.
struct MapScreen: View {
    let machine: StateMachine
    let ingest: @Sendable (Sendable) async -> Void

    @State private var rep: MapRep = .empty
    /// The tracked character's session (stamina, bush, running actions) for
    /// the gathering HUD — the map itself renders from `rep` (MapRep).
    @State private var session: ViewRep.Session?
    @State private var camera = Camera()
    @State private var follow = true
    @State private var didInitCamera = false
    @State private var bitmap: HexMapBitmap.Rendered?
    @State private var selectedTile: TileCoordinate?
    @State private var lastDragDelta: CGSize = .zero
    @State private var pinchBaseZoom: Double?
    /// Tracked resource ids (JSON in UserDefaults, like the web client's
    /// localStorage). Empty set = show everything.
    @AppStorage("map.trackedResourceIds") private var trackedData = Data()
    @State private var filterVisible = ProcessInfo.processInfo.arguments.contains("-uitest-map-filter")
    /// UI-testing hook: present the dashboard cover immediately on launch.
    @State private var showDashboard = ProcessInfo.processInfo.arguments.contains("-uitest-dashboard")
    @State private var searchText = ""

    private var tracked: Set<Int> {
        get {
            (try? JSONDecoder().decode([Int].self, from: trackedData)).map(Set.init) ?? []
        }
        nonmutating set {
            trackedData = (try? JSONEncoder().encode(newValue.sorted())) ?? Data()
        }
    }

    private var trackedKey: String {
        tracked.sorted().map(String.init).joined(separator: ",")
    }

    struct Camera: Equatable {
        var centerX: Double = 0
        var centerZ: Double = 0
        var pxPerHex: Double = 5
    }

    var body: some View {
        ZStack {
            Color(white: 0.055).ignoresSafeArea()
            TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
                Canvas { context, size in
                    draw(in: &context, size: size, pulse: timeline.date.timeIntervalSinceReferenceDate)
                }
                .simultaneousGesture(panGesture)
                .simultaneousGesture(zoomGesture)
                .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                    selectTile(at: tap.location, size: canvasSize)
                })
            }
            chrome
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showDashboard) {
            ActivityScreen(machine: machine, ingest: ingest)
        }
        .task { await subscribe() }
        .task {
            for await viewRep in machine.viewRep.values {
                switch viewRep {
                case .session(let session): self.session = session
                case .onboarding: self.session = nil
                case .bitCraftSignIn: break // no session while signing in
                }
            }
        }
        .task(id: "\(rep.tileVersion)|\(trackedKey)") { await prerender() }
    }

    // MARK: - Subscription

    private func subscribe() async {
        for await next in machine.mapRep.values {
            rep = next
            if follow, let player = next.player, player.dimension == 1 {
                camera.centerX = player.worldX
                camera.centerZ = player.worldZ
            }
            if !didInitCamera, next.width != nil {
                didInitCamera = true
                if let player = next.player, player.dimension == 1 {
                    camera.centerX = player.worldX
                    camera.centerZ = player.worldZ
                } else {
                    camera.centerX = Double(next.originX ?? 0) + Double(next.width ?? 0) / 2
                    camera.centerZ = Double(next.originZ ?? 0) + Double(next.width ?? 0) / 2
                }
                if ProcessInfo.processInfo.arguments.contains("-uitest-map-fit") {
                    fitWindow() // UI hook: start zoomed out on the bitmap-blit path
                } else {
                    camera.pxPerHex = HexMapRenderer.defaultZoom(for: canvasSize)
                }
            }
        }
    }

    /// Debounced bitmap regeneration — deltas arrive in bursts, and the
    /// 160k-tile render stays off the main thread. Keyed on tile version
    /// *and* the tracked set: tracking changes re-fade the bitmap.
    private func prerender() async {
        guard rep.width != nil else { return }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        let snapshot = rep
        let trackedSet = tracked
        let rendered = await Task.detached(priority: .userInitiated) {
            HexMapBitmap.render(snapshot, tracked: trackedSet)
        }.value
        guard !Task.isCancelled else { return }
        bitmap = rendered
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize, pulse: TimeInterval) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(HexMapRenderer.voidColor))

        guard rep.width != nil, !rep.words.isEmpty else { return }

        if camera.pxPerHex >= HexMapRenderer.vectorMinCell || bitmap == nil {
            drawVectorTiles(in: &context, size: size)
        } else if let bitmap {
            blit(bitmap, in: &context, size: size)
        }
        drawTarget(in: &context, size: size)
        drawSelectedTile(in: &context, size: size)
        drawPlayer(in: &context, size: size, pulse: pulse)
    }

    private func drawVectorTiles(in context: inout GraphicsContext, size: CGSize) {
        let visible = visibleTileBounds(size: size)
        guard let originX = rep.originX, let originZ = rep.originZ, let width = rep.width else { return }

        let minX = max(visible.minX, originX)
        let maxX = min(visible.maxX, originX + width - 1)
        let minZ = max(visible.minZ, originZ)
        let maxZ = min(visible.maxZ, originZ + width - 1)
        guard minX <= maxX, minZ <= maxZ else { return }

        let trackingActive = !tracked.isEmpty
        var fills: [Color: Path] = [:]
        var anchors: [CGPoint] = []
        let k = camera.pxPerHex

        for z in minZ...maxZ {
            for x in minX...maxX {
                let word = rep.words[(z - originZ) * width + (x - originX)]
                guard word != 0 else { continue }
                guard let center = screenPixel(x: Double(x), z: Double(z), size: size) else { continue }
                let style = HexMapRenderer.tileStyle(word: word, x: x, z: z, terrain: rep.terrain, entries: rep.entries)
                guard style != .uncharted else { continue }
                var color = HexMapRenderer.color(style)
                // Untracked resources fade while tracking is active (the
                // web client's 10%-alpha treatment).
                let resourceID = rep.entries[TileWord.dictIndex(word)]?.resourceID
                let faded = trackingActive && resourceID.map { !tracked.contains($0) } ?? false
                if faded { color = color.opacity(0.1) }
                var path = fills[color] ?? Path()
                HexMapRenderer.appendHex(&path, center: center, size: k)
                fills[color] = path
                if k >= 8, !faded,
                   TileWord.hasResource(word), TileWord.isOrigin(word), !TileWord.isWater(word) {
                    anchors.append(center)
                }
            }
        }
        for (color, path) in fills {
            context.fill(path, with: .color(color))
        }
        if !anchors.isEmpty {
            var dots = Path()
            let r = max(1.2, k * 0.1)
            for point in anchors {
                dots.addEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
            }
            context.fill(dots, with: .color(.black.opacity(0.42)))
        }
    }

    private func blit(_ bitmap: HexMapBitmap.Rendered, in context: inout GraphicsContext, size: CGSize) {
        let k = camera.pxPerHex
        let scale = bitmap.scale
        guard let topLeft = screenPixel(worldX: bitmap.worldMinX, worldY: bitmap.worldMinY, size: size) else { return }
        let width = bitmap.image.size.width / scale * k
        let height = bitmap.image.size.height / scale * k
        context.draw(Image(uiImage: bitmap.image), in: CGRect(x: topLeft.x, y: topLeft.y, width: width, height: height))
    }

    private func drawTarget(in context: inout GraphicsContext, size: CGSize) {
        guard let target = rep.target,
              let center = screenPixel(x: Double(target.tileX), z: Double(target.tileZ), size: size) else { return }
        context.stroke(
            HexMapRenderer.hexPath(center: center, size: camera.pxPerHex),
            with: .color(.orange),
            lineWidth: 2.5
        )
    }

    private func drawSelectedTile(in context: inout GraphicsContext, size: CGSize) {
        guard let tile = selectedTile,
              let center = screenPixel(x: Double(tile.x), z: Double(tile.z), size: size) else { return }
        context.stroke(
            HexMapRenderer.hexPath(center: center, size: camera.pxPerHex),
            with: .color(.white),
            lineWidth: 1.5
        )
    }

    private func drawPlayer(in context: inout GraphicsContext, size: CGSize, pulse: TimeInterval) {
        guard let player = rep.player, player.dimension == 1,
              let point = screenPixel(x: player.worldX, z: player.worldZ, size: size) else { return }

        if player.isWalking,
           let destinationX = player.destinationWorldX, let destinationZ = player.destinationWorldZ,
           let destination = screenPixel(x: destinationX, z: destinationZ, size: size) {
            var line = Path()
            line.move(to: point)
            line.addLine(to: destination)
            context.stroke(line, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
        }

        let radius = player.isWalking ? 6 * (1 + 0.25 * sin(pulse * 3.5)) : 6
        var ring = Path()
        ring.addEllipse(in: CGRect(x: point.x - radius - 3, y: point.y - radius - 3, width: (radius + 3) * 2, height: (radius + 3) * 2))
        context.fill(ring, with: .color(.black.opacity(0.8)))
        var dot = Path()
        dot.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        context.fill(dot, with: .color(player.isWalking ? Color(red: 0.22, green: 0.74, blue: 0.97) : .red))
    }

    // MARK: - Projection

    /// Screen-space pixel of a world tile center (or fractional position).
    private func screenPixel(x: Double, z: Double, size: CGSize) -> CGPoint? {
        let world = HexMapRenderer.worldPixel(x: x, z: z)
        return screenPixel(worldX: world.x, worldY: world.y, size: size)
    }

    private func screenPixel(worldX: Double, worldY: Double, size: CGSize) -> CGPoint? {
        guard size.width > 0, size.height > 0 else { return nil }
        let cameraWorld = HexMapRenderer.worldPixel(x: camera.centerX, z: camera.centerZ)
        let k = camera.pxPerHex
        return CGPoint(
            x: (worldX - cameraWorld.x) * k + size.width / 2,
            y: (worldY - cameraWorld.y) * k + size.height / 2
        )
    }

    private func worldPixel(screenX: Double, screenY: Double, size: CGSize) -> (x: Double, y: Double) {
        let cameraWorld = HexMapRenderer.worldPixel(x: camera.centerX, z: camera.centerZ)
        let k = camera.pxPerHex
        return (
            (screenX - size.width / 2) / k + cameraWorld.x,
            (screenY - size.height / 2) / k + cameraWorld.y
        )
    }

    /// Conservative tile bounds covering the viewport (±3 tiles padding —
    /// the odd-r shear shifts rows by half a tile).
    private func visibleTileBounds(size: CGSize) -> (minX: Int, maxX: Int, minZ: Int, maxZ: Int) {
        let corners = [
            worldPixel(screenX: 0, screenY: 0, size: size),
            worldPixel(screenX: size.width, screenY: 0, size: size),
            worldPixel(screenX: 0, screenY: size.height, size: size),
            worldPixel(screenX: size.width, screenY: size.height, size: size),
        ]
        var xs: [Double] = []
        var zs: [Double] = []
        for corner in corners {
            let z = -corner.y / 1.5
            // Inverting px = √3·q + √3/2·z with x = q + (z − odd)/2 cancels
            // the z terms: x ≈ px/√3 ± the half-tile shear.
            let x = corner.x / HexMapRenderer.sqrt3
            xs.append(x)
            zs.append(z)
        }
        return (
            Int(xs.min()!.rounded(.down)) - 3,
            Int(xs.max()!.rounded(.up)) + 3,
            Int(zs.min()!.rounded(.down)) - 3,
            Int(zs.max()!.rounded(.up)) + 3
        )
    }

    // MARK: - Gestures

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                follow = false
                let delta = CGSize(
                    width: value.translation.width - lastDragDelta.width,
                    height: value.translation.height - lastDragDelta.height
                )
                lastDragDelta = value.translation
                camera.centerX -= Double(delta.width) / (HexMapRenderer.sqrt3 * camera.pxPerHex)
                camera.centerZ += Double(delta.height) / (1.5 * camera.pxPerHex)
            }
            .onEnded { _ in lastDragDelta = .zero }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                // `value` is the cumulative scale since the gesture began —
                // capture the starting zoom once and scale from it.
                if pinchBaseZoom == nil { pinchBaseZoom = camera.pxPerHex }
                camera.pxPerHex = HexMapRenderer.clampZoom(pinchBaseZoom! * Double(value))
            }
            .onEnded { _ in pinchBaseZoom = nil }
    }

    private func selectTile(at point: CGPoint, size: CGSize) {
        let world = worldPixel(screenX: Double(point.x), screenY: Double(point.y), size: size)
        let zApprox = Int((-world.y / 1.5).rounded())
        let xApprox = Int((world.x / HexMapRenderer.sqrt3).rounded())
        var best: TileCoordinate?
        var bestDistance = camera.pxPerHex * camera.pxPerHex
        for dz in -1...1 {
            for dx in -1...1 {
                let candidate = TileCoordinate(x: xApprox + dx, z: zApprox + dz)
                let center = HexMapRenderer.worldPixel(x: Double(candidate.x), z: Double(candidate.z))
                let dxx = center.x - world.x
                let dyy = center.y - world.y
                let distance = dxx * dxx + dyy * dyy
                if distance < bestDistance {
                    bestDistance = distance
                    best = candidate
                }
            }
        }
        if let best, best == selectedTile {
            selectedTile = nil // tap again to dismiss
        } else {
            selectedTile = best
        }
    }

    // MARK: - Chrome

    private var canvasSize: CGSize {
        // The Canvas fills the safe-area-ignoring ZStack; GeometryReader-free
        // best effort (only used for default zoom / hit-testing margins).
        UIScreen.main.bounds.size
    }

    private var chrome: some View {
        VStack {
            HStack {
                Button {
                    showDashboard = true
                } label: {
                    Image(systemName: "gauge.with.needle")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .accessibilityLabel("Activity dashboard")
                statusPill
                    .frame(maxWidth: .infinity)
                Button {
                    fitWindow()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(.horizontal, 12)
            Spacer()
            if !hasWindow {
                Text("Waiting for the map — the player must be live in the overworld.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            }
            if let tile = selectedTile, !filterVisible {
                tileInfoCard(tile)
            }
            if filterVisible {
                filterPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                HStack(spacing: 10) {
                    MapButton(icon: "minus") { zoom(by: 1 / 1.3) }
                    MapButton(icon: "line.3.horizontal.decrease.circle", active: !tracked.isEmpty) {
                        withAnimation(.easeOut(duration: 0.2)) { filterVisible = true }
                    }
                    MapButton(icon: "location", active: follow) {
                        follow = true
                        if let player = rep.player {
                            camera.centerX = player.worldX
                            camera.centerZ = player.worldZ
                        }
                    }
                    MapButton(icon: "plus") { zoom(by: 1.3) }
                }
                .padding(.bottom, 8)
            }
        }
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.2), value: gatheringInfo != nil)
        // Gathering HUD: pinned to the left edge, just below the vertical
        // midpoint — the followed player sits at screen center, so the two
        // can never overlap.
        .overlay(alignment: .topLeading) {
            if gatheringInfo != nil {
                gatheringBanner
                    .padding(.leading, 10)
                    .padding(.top, canvasSize.height / 2 + 16)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
    }

    // MARK: - Gathering HUD

    /// Non-nil while the tracked character is actively gathering: an
    /// Extract action running against a known resource.
    private var gatheringInfo: (name: String, endsAtMs: Double?)? {
        guard let session,
              session.actions.contains(where: { $0.actionType == "Extract" }),
              let bush = session.bush else { return nil }
        let endsAtMs = [bush.depletesAtMs, bush.windowEndsAtMs]
            .compactMap { $0 }
            .min()
        return (bush.name, endsAtMs)
    }

    /// ¼-width × ⅒-height banner: resource name, time until depleted, and
    /// the stamina meter. Its own timeline keeps the countdown ticking
    /// without re-rendering the map canvas.
    @ViewBuilder
    private var gatheringBanner: some View {
        if let gathering = gatheringInfo, let stamina = session?.stamina {
            TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
                let relayOffset = session?.nowMs.map {
                    $0 - Date().timeIntervalSince1970 * 1_000
                } ?? 0
                let nowMs = timeline.date.timeIntervalSince1970 * 1_000 + relayOffset
                VStack(spacing: 5) {
                    Text(gathering.name)
                        .font(.caption2)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    if let endsAtMs = gathering.endsAtMs {
                        Text(Format.mmss(endsAtMs - nowMs))
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                    } else {
                        Text("harvesting")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: stamina.pct)
                        .tint(stamina.pct < 0.15 ? .red : .yellow)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "Gathering \(gathering.name), stamina \(Int((stamina.pct * 100).rounded())) percent"
                )
            }
            .frame(width: canvasSize.width / 4, height: canvasSize.height / 10)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.yellow.opacity(0.35), lineWidth: 1)
            )
        }
    }

    private var hasWindow: Bool { rep.width != nil && !rep.words.isEmpty }

    private var statusPill: some View {
        HStack(spacing: 6) {
            switch rep.stream {
            case .live:
                Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.cyan)
                Text(streamText).font(.caption).bold().foregroundStyle(.green)
            case .connecting, .reconnecting:
                Image(systemName: "bolt.slash").font(.caption2).foregroundStyle(.orange)
                Text(streamText).font(.caption).bold().foregroundStyle(.orange)
            case .off:
                Image(systemName: "bolt.slash").font(.caption2).foregroundStyle(.gray)
                Text(streamText).font(.caption).foregroundStyle(.gray)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
    }

    private var streamText: String {
        if !hasWindow { return "waiting…" }
        switch rep.stream {
        case .live: return "live map"
        case .connecting: return "connecting…"
        case .reconnecting: return "reconnecting…"
        case .off: return "map paused"
        }
    }

    private func tileInfoCard(_ tile: TileCoordinate) -> some View {
        let word = rep.word(at: tile)
        let entry = word.flatMap { TileWord.dictIndex($0) != 0 ? rep.entries[TileWord.dictIndex($0)] : nil }
        let superOffset = SuperHexMath.tileToSuperOffset(x: tile.x, z: tile.z)
        let terrain = rep.terrain?.cell(atTileX: tile.x, z: tile.z)

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry?.name ?? (word == nil || word == 0 ? "uncharted" : "unknown resource"))
                    .font(.subheadline.bold())
                Spacer()
                Text("N \(superOffset.z) · E \(superOffset.x)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                if let entry {
                    if entry.harvestable == true { Text("harvestable").font(.caption2) }
                    if let maxHealth = entry.maxHealth { Text("HP \(Int(maxHealth))").font(.caption2) }
                    if let respawn = entry.respawnTimeSecs, respawn > 0 {
                        Text("respawn \(Int(respawn))s").font(.caption2)
                    }
                }
                if let terrain, !terrain.isVoid {
                    Text(terrain.isUnderwater
                         ? "water · depth \(terrain.waterLevel - terrain.elevation)m"
                         : "land · elev \(terrain.elevation)m")
                        .font(.caption2)
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Resource filter panel

    /// One row per resource id (dictionary indices repeat per resource;
    /// counts sum across them).
    struct ResourceRow: Identifiable {
        let id: Int // resource_id
        let name: String
        let count: Int
    }

    private var resourceRows: [ResourceRow] {
        var info: [Int: (name: String, count: Int)] = [:]
        for (index, entry) in rep.entries {
            guard entry.paving != true, let resourceID = entry.resourceID else { continue }
            var row = info[resourceID] ?? (entry.name ?? "resource \(resourceID)", 0)
            row.count += rep.tally[index] ?? 0
            info[resourceID] = row
        }
        return info.map { ResourceRow(id: $0.key, name: $0.value.name, count: $0.value.count) }
    }

    /// Count-sorted matches — while searching these are all matches,
    /// otherwise only resources present in the window.
    private var nearbyRows: [ResourceRow] {
        let rows = searchText.isEmpty
            ? resourceRows
            : resourceRows.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        return rows
            .filter { searchText.isEmpty ? $0.count > 0 : true }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    /// The long tail (absent from the window) — hidden while searching.
    private var otherRows: [ResourceRow] {
        guard searchText.isEmpty else { return [] }
        return resourceRows
            .filter { $0.count == 0 }
            .sorted { $0.name < $1.name }
    }

    private var trackingStatusText: String {
        if tracked.isEmpty { return "Showing all resources" }
        let nearby = resourceRows.filter { tracked.contains($0.id) }.reduce(0) { $0 + $1.count }
        let plural = tracked.count == 1 ? "resource" : "resources"
        return "Tracking \(tracked.count) \(plural) — \(nearby) nearby · others faded"
    }

    private var filterPanel: some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(.white.opacity(0.35))
                .frame(width: 36, height: 4)
                .padding(.top, 8)

            HStack {
                Text("Resources")
                    .font(.subheadline.bold())
                Spacer()
                if !tracked.isEmpty {
                    Button("Show all") { tracked = [] }
                        .font(.caption.bold())
                        .foregroundStyle(.cyan)
                }
                Button {
                    withAnimation(.easeIn(duration: 0.15)) { filterVisible = false }
                } label: {
                    Image(systemName: "chevron.down.circle.fill")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .accessibilityLabel("Close filter panel")
            }

            Text(trackingStatusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Search resources", text: $searchText)
                    .font(.caption)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            if rep.entries.isEmpty {
                Text("Waiting for region data…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if !nearbyRows.isEmpty {
                            panelSection(searchText.isEmpty ? "Nearby" : "Matches")
                        }
                        ForEach(nearbyRows) { row in
                            filterRow(row)
                        }
                        if !otherRows.isEmpty {
                            panelSection("All resources")
                        }
                        ForEach(otherRows) { row in
                            filterRow(row)
                        }
                        if nearbyRows.isEmpty && otherRows.isEmpty {
                            Text("No resources match “\(searchText)”.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 12)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .frame(height: 400)
        .background(
            Color(white: 0.08).opacity(0.97),
            in: UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16)
        )
    }

    private func panelSection(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.bold())
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func filterRow(_ row: ResourceRow) -> some View {
        let isTracked = tracked.contains(row.id)
        return Button {
            if isTracked {
                tracked.subtract([row.id])
            } else {
                tracked.insert(row.id)
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(resourceID: row.id))
                    .frame(width: 9, height: 9)
                Text(row.name)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer()
                if row.count > 0 {
                    Text("×\(row.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Image(systemName: isTracked ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(isTracked ? Color.cyan : Color.secondary.opacity(0.4))
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Camera moves

    private func zoom(by factor: Double) {
        camera.pxPerHex = HexMapRenderer.clampZoom(camera.pxPerHex * factor)
    }

    private func fitWindow() {
        guard let originX = rep.originX, let originZ = rep.originZ, let width = rep.width else { return }
        let bounds = HexMapRenderer.worldPixelBounds(
            minX: originX, minZ: originZ, maxX: originX + width, maxZ: originZ + width
        )
        let size = canvasSize
        let margin: Double = 60
        let kx = (size.width - margin) / max(1, bounds.maxX - bounds.minX)
        let ky = (size.height - margin) / max(1, bounds.maxY - bounds.minY)
        camera.pxPerHex = HexMapRenderer.clampZoom(min(kx, ky))
        camera.centerX = Double(originX) + Double(width) / 2
        camera.centerZ = Double(originZ) + Double(width) / 2
        follow = false
    }
}

// MARK: - Shared pieces

struct TileCoordinate: Equatable {
    let x: Int
    let z: Int
}

private struct MapButton: View {
    let icon: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body.bold())
                .frame(width: 38, height: 38)
                .background(.black.opacity(0.55), in: Circle())
                .foregroundStyle(active ? .cyan : .white.opacity(0.9))
        }
    }
}

extension MapRep {
    /// Tile word at an absolute tile; nil outside the window.
    func word(at tile: TileCoordinate) -> UInt16? {
        guard let originX, let originZ, let width else { return nil }
        let c = tile.x - originX
        let r = tile.z - originZ
        guard c >= 0, r >= 0, c < width, r < width else { return nil }
        return words[r * width + c]
    }
}
