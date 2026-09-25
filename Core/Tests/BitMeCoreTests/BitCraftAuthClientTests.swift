import Testing
import Foundation
@testable import BitMeCore

/// `BitCraftAuthClient` against a scripted URLProtocol: request shapes and
/// error mapping follow the 2026-09-25 tap capture verbatim. Serialized —
/// the stub's static handler is shared state.
@MainActor
@Suite(.serialized)
struct BitCraftAuthClientTests {

    // MARK: - URLProtocol stub

    final class StubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            do {
                let (status, body) = try handler(request)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: status,
                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    static let client: BitCraftAuthClient = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return BitCraftAuthClient(
            baseURL: URL(string: "https://api.test")!,
            urlSession: URLSession(configuration: config)
        )
    }()

    // The captured production JWT payload (hex_identity/sub/iat, exp null).
    static let capturedPayload = #"{"hex_identity":"c200cbb8c1ae61237b879e0fa0bf9cd64f9174beb983ab61c88cbacff6f4d1bb","sub":"0bea2e70-808a-4744-95de-1dae867afbb3","iss":"localhost","aud":["spacetimedb"],"iat":1750522057,"exp":null}"#

    static func testJWT() -> String {
        // header.payload.sig with base64url encoding, no padding.
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return [b64url(#"{"typ":"JWT","alg":"ES256"}"#), b64url(capturedPayload), "sig"].joined(separator: ".")
    }

    // MARK: - requestAccessCode

    @Test func requestAccessCodePostsQueryAndExpectsEmpty200() async throws {
        var seen: URLRequest?
        StubURLProtocol.handler = { request in
            seen = request
            return (200, Data())
        }
        try await Self.client.requestAccessCode(email: "ekscrypto@gmail.com")
        let request = try #require(seen)
        #expect(request.httpMethod == "POST")
        let url = try #require(request.url)
        #expect(url.path == "/authentication/request-access-code")
        // Compare decoded pairs — exact percent-encoding of `@` is the
        // client library's choice, and the server accepts either form.
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items == [URLQueryItem(name: "email", value: "ekscrypto@gmail.com")])
        #expect((request.httpBody ?? request.bodyStreamData ?? Data()).isEmpty)
    }

    @Test func requestAccessCodeSurfaces400Body() async {
        StubURLProtocol.handler = { _ in
            (400, Data(#"{"error":"invalid email"}"#.utf8))
        }
        await #expect(throws: BitCraftAuthError.badRequest("invalid email")) {
            try await Self.client.requestAccessCode(email: "nope")
        }
    }

    // MARK: - authenticate

    @Test func authenticateReturnsBareJSONStringToken() async throws {
        let jwt = Self.testJWT()
        StubURLProtocol.handler = { _ in (200, Data("\"\(jwt)\"".utf8)) }
        let token = try await Self.client.authenticate(email: "ekscrypto@gmail.com", code: "MAB9L6")
        #expect(token == jwt)
    }

    @Test func authenticateRejectsNonStringBody() async {
        StubURLProtocol.handler = { _ in (200, Data(#"{"token":"x"}"#.utf8)) }
        await #expect(throws: BitCraftAuthError.invalidResponse) {
            _ = try await Self.client.authenticate(email: "a@b.c", code: "X")
        }
    }

    @Test func authenticateSurfaces500() async {
        StubURLProtocol.handler = { _ in (500, Data()) }
        await #expect(throws: BitCraftAuthError.httpStatus(500)) {
            _ = try await Self.client.authenticate(email: "a@b.c", code: "X")
        }
    }

    // Wire-observed shapes (2026-09-25 tap, mismatched-email login attempt):
    // 401 answers RFC 7807 problem+json, 409 answers a bare JSON string.

    @Test func authenticateSurfaces401ProblemDetail() async {
        StubURLProtocol.handler = { _ in
            (401, Data(#"{"type":"https://tools.ietf.org/html/rfc9110#section-15.5.2","title":"Unauthorized","status":401,"detail":"Access code is invalid"}"#.utf8))
        }
        await #expect(throws: BitCraftAuthError.badRequest("Access code is invalid")) {
            _ = try await Self.client.authenticate(email: "a@b.c", code: "WRONG1")
        }
    }

    @Test func authenticateSurfaces409BareString() async {
        StubURLProtocol.handler = { _ in
            (409, Data("\"This steam account is already linked to a different email\"".utf8))
        }
        await #expect(throws: BitCraftAuthError.badRequest("This steam account is already linked to a different email")) {
            _ = try await Self.client.authenticate(email: "a@b.c", code: "GOOD12")
        }
    }

    // MARK: - connectionInfo

    @Test func connectionInfoDecodesCapturedShape() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"uri":"https://bitcraft-early-access.spacetimedb.com","name":"bitcraft-live-global"}"#.utf8))
        }
        let info = try await Self.client.connectionInfo()
        #expect(info == BitCraftConnectionInfo(
            uri: "https://bitcraft-early-access.spacetimedb.com",
            name: "bitcraft-live-global"
        ))
    }

    // MARK: - BitCraftAccount claims

    @Test func accountDecodesJWTClaims() {
        let account = BitCraftAccount(email: "ekscrypto@gmail.com", token: Self.testJWT())
        #expect(account.email == "ekscrypto@gmail.com")
        #expect(account.identityHex == "c200cbb8c1ae61237b879e0fa0bf9cd64f9174beb983ab61c88cbacff6f4d1bb")
        #expect(account.subject == "0bea2e70-808a-4744-95de-1dae867afbb3")
        #expect(account.issuedAt == Date(timeIntervalSince1970: 1_750_522_057))
    }

    @Test func accountToleratesGarbageToken() {
        let account = BitCraftAccount(email: "a@b.c", token: "not-a-jwt")
        #expect(account.identityHex == nil)
        #expect(account.subject == nil)
        #expect(account.issuedAt == nil)
    }
}

extension URLRequest {
    /// POSTs built with `httpBody` surface as a body stream under URLProtocol.
    var bodyStreamData: Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
