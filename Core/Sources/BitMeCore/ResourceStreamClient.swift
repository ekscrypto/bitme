import Foundation

/// Events from the relay's live resource change stream
/// (`WS /bitme/session/:entity_id/resources/ws`, docs/api.md §7).
public enum ResourceStreamEvent: Equatable, Sendable {
    /// The server accepted the subscription. `anchor` is the window center
    /// tile the stream is scoped to; deltas outside it will not arrive.
    case subscribed(anchorX: Int, anchorZ: Int, width: Int, region: Int, dictVersion: Int)
    /// Tile changes in absolute world coordinates (BMD1 frame). A 0 /
    /// water-only word means the tile emptied.
    case delta(ResourceTileDelta)
    /// The server rolled the window (dictionary rotation, reseed, …) —
    /// recovery is always "re-fetch the BMR1 window".
    case resync
    /// The anchor moved (player drifted far) — re-fetch to converge.
    case moved
    /// Server heartbeat (~5 s cadence); also proves the socket is alive.
    case heartbeat(tsMs: Int64)
}

/// One WebSocket connection to the change stream. The returned
/// `AsyncStream` delivers events until the socket closes (server close,
/// error, watchdog, or termination) — reconnection policy belongs to the
/// caller (`Activity.ResourceStreamLoop`).
struct ResourceStreamClient: Sendable {
    let baseURL: URL

    static let production = ResourceStreamClient(
        baseURL: RelayClient.production.baseURL
    )

    /// Seconds without any frame (heartbeats included) before a zombie
    /// socket is hard-dropped — matches the reference client.
    private static let deadSocketAfter: TimeInterval = 15
    private static let watchdogTick: TimeInterval = 5

    private final class SocketBox: @unchecked Sendable {
        let lock = NSLock()
        var lastFrameAt = Date()
        var finished = false

        func markFrame() {
            lock.withLock { lastFrameAt = Date() }
        }

        func isDead(now: Date) -> Bool {
            lock.withLock { now.timeIntervalSince(lastFrameAt) > ResourceStreamClient.deadSocketAfter }
        }

        func finish() {
            lock.withLock { finished = true }
        }

        var isFinished: Bool { lock.withLock { finished } }
    }

    func events(entityID: String) -> AsyncStream<ResourceStreamEvent> {
        let url = websocketURL(entityID: entityID)
        let box = SocketBox()
        return AsyncStream { continuation in
            let socket = URLSession.shared.webSocketTask(with: url)
            let watchdog = Task { [box, socket] in
                while !box.isFinished {
                    try? await Task.sleep(for: .seconds(Self.watchdogTick))
                    if box.isFinished { return }
                    if box.isDead(now: Date()) {
                        // A zombie (half-open TCP after sleep/wake or a network
                        // roam) never fires an error — cancel it outright.
                        socket.cancel(with: .goingAway, reason: nil)
                        return
                    }
                }
            }
            let receive = Task { [box, socket] in
                socket.resume()
                while !Task.isCancelled {
                    do {
                        let message = try await socket.receive()
                        box.markFrame()
                        switch message {
                        case .string(let text):
                            if let event = Self.parse(text) {
                                continuation.yield(event)
                            }
                            // "gone": the server closes right after — the next
                            // receive throws and finishes the stream.
                        case .data(let data):
                            if let delta = try? ResourceTileDelta(data: data) {
                                continuation.yield(.delta(delta))
                            }
                        @unknown default:
                            break
                        }
                    } catch {
                        break
                    }
                }
                box.finish()
                continuation.finish()
            }
            continuation.onTermination = { _ in
                box.finish()
                watchdog.cancel()
                receive.cancel()
                socket.cancel(with: .normalClosure, reason: nil)
            }
        }
    }

    private func websocketURL(entityID: String) -> URL {
        var components = URLComponents()
        components.scheme = baseURL.scheme == "http" ? "ws" : "wss"
        components.host = baseURL.host
        components.port = baseURL.port
        components.path = baseURL.path + "/bitme/session/\(entityID)/resources/ws"
        return components.url ?? URL(string: "wss://relay.bitcraftsync.app")!
    }

    /// Control messages are JSON text: `{"type":"subscribed","anchor":{…}}`,
    /// `{"type":"resync"|"moved"|"gone"}`, or a `{"ts":…}` heartbeat.
    private static func parse(_ text: String) -> ResourceStreamEvent? {
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(ControlMessage.self, from: data) else {
            return nil
        }
        switch message.type {
        case "subscribed":
            guard let anchor = message.anchor else { return nil }
            return .subscribed(
                anchorX: anchor.x,
                anchorZ: anchor.z,
                width: message.width ?? 0,
                region: message.region ?? 0,
                dictVersion: message.dictVersion ?? 0
            )
        case "resync":
            return .resync
        case "moved":
            return .moved
        default:
            if let ts = message.ts { return .heartbeat(tsMs: ts) }
            return nil
        }
    }

    private struct ControlMessage: Decodable {
        let type: String?
        let ts: Int64?
        let anchor: Anchor?
        let width: Int?
        let region: Int?
        let dictVersion: Int?

        enum CodingKeys: String, CodingKey {
            case type
            case ts
            case anchor
            case width
            case region
            case dictVersion = "dict_version"
        }

        struct Anchor: Decodable {
            let x: Int
            let z: Int
        }
    }
}
