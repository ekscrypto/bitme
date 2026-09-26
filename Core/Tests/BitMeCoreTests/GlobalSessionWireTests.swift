import Testing
import Foundation
@testable import BitMeCore

/// The game session's wire contribution: the `sign_in` reducer argument.
/// Everything else (websocket handshake, v2.bsatn framing, message
/// encode/decode) lives in spacetimedb-swift-sdk and is tested there; the
/// fixture here pins BitMe's argument against the 2026-09-25 tap capture
/// and the module schema (`sign_in(_request: { owner_entity_id: u64 })`).
@Suite struct GlobalSessionWireTests {

    /// The desktop client's captured `sign_in` argument bytes (conn-03 and
    /// conn-04 identical) — the account's user entity id, little-endian.
    static let capturedArgBytes: [UInt8] = [202, 224, 7, 1, 0, 0, 0, 18]
    static let capturedEntityID: UInt64 = 1_297_036_692_699_996_362

    @Test func signInArgumentsMatchTheCapturedBytes() {
        #expect(Array(GlobalSessionClient.signInArguments(entityID: Self.capturedEntityID))
                == Self.capturedArgBytes)
    }
}
