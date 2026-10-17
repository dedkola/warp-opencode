import Foundation
import Network
#if !PORTABLE_CHECKS
import XCTest
@testable import BridgeCore
#endif

private final class MockUpstream: @unchecked Sendable {
    let queue = DispatchQueue(label: "bridge.tests.upstream")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var didStart = false
    var handler: ((HTTPRequestMessage, NWConnection) -> Void)?
    var url: URL!

    func start() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                if case .ready = state, !self.didStart {
                    self.didStart = true
                    self.url = URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/upstream")!
                    continuation.resume()
                }
                if case .failed(let error) = state, !self.didStart { self.didStart = true; continuation.resume(throwing: error) }
            }
            listener.newConnectionHandler = { connection in
                self.connections.append(connection)
                connection.start(queue: self.queue)
                self.receive(connection, parser: HTTPRequestParser())
            }
            listener.start(queue: queue)
        }
    }

    private func receive(_ connection: NWConnection, parser: HTTPRequestParser) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            var parser = parser
            do {
                if let data, let request = try parser.append(data) {
                    self.handler?(request, connection)
                } else if error == nil && !complete { self.receive(connection, parser: parser) }
            } catch { XCTFail("Mock could not parse upstream request: \(error)"); connection.cancel() }
        }
    }

    func stop() {
        queue.sync { listener?.cancel(); connections.forEach { $0.cancel() }; connections.removeAll() }
    }

    static func respond(_ connection: NWConnection, status: Int = 200, body: Data,
                        type: String = "application/json", extra: String = "") {
        let head = "HTTP/1.1 \(status) Test\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\(extra)\r\n"
        var data = Data(head.utf8); data.append(body)
        connection.send(content: data, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}

private final class StreamingClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var onData: (() -> Void)?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var notified = false
    func start(_ request: URLRequest) {
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        task = session?.dataTask(with: request); task?.resume()
    }
    func cancel() { task?.cancel(); session?.invalidateAndCancel() }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if !notified { notified = true; onData?() }
    }
}

private final class ProxyEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func append(_ event: ProxyEvent) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(event.message)
    }

    var messages: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}

final class ProxyIntegrationTests: XCTestCase {
    private let token = String(repeating: "Private-Token-xYz-", count: 3)
    private let apiKey = "fake-go-test-key"

    private func server(upstream: URL, sessionMode: SessionMode = .strict, sessionResolver: SessionResolver? = nil, onEvent: @escaping @Sendable (ProxyEvent) -> Void = { _ in }) async throws -> (ProxyServer, URL) {
        for _ in 0..<20 {
            let port = UInt16.random(in: 30000...60000)
            let configuration = BridgeConfiguration(localPort: port, sessionMode: sessionMode)
            let server = ProxyServer(configuration: configuration, goAPIKey: apiKey, relayToken: token, upstreamURL: upstream, sessionResolver: sessionResolver, onEvent: onEvent)
            do { try await server.start(); return (server, URL(string: "http://127.0.0.1:\(port)")!) }
            catch { server.stop() }
        }
        throw ProxyFailure.listener("No local test port available")
    }

    private func request(_ base: URL, path: String = "/v1/chat/completions", auth: Bool = true) throws -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(String(path.dropFirst())))
        request.timeoutInterval = 5
        if auth { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if path == "/v1/chat/completions" {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("test-native-chat", forHTTPHeaderField: "x-warp-conversation-id")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "deepseek-v4.1-flash", "stream": true, "messages": [["role": "user", "content": "Test"]]])
        }
        return request
    }

    func testAuthenticationAndLocalModelsDoNotReachProvider() async throws {
        let mock = MockUpstream(); try await mock.start(); defer { mock.stop() }
        let called = expectation(description: "provider not called"); called.isInverted = true
        mock.handler = { _, _ in called.fulfill() }
        let (server, base) = try await server(upstream: mock.url); defer { server.stop() }
        let (_, denied) = try await URLSession.shared.data(for: request(base, path: "/v1/models", auth: false))
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 401)
        let (data, accepted) = try await URLSession.shared.data(for: request(base, path: "/v1/models"))
        XCTAssertEqual((accepted as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((object["data"] as? [[String: Any]])?.first?["id"] as? String, "deepseek-v4.1-flash")
        await fulfillment(of: [called], timeout: 0.15)
    }

    func testBearerSchemeAcceptsCaseVariantsAndMultipleASCIISeparators() async throws {
        let mock = MockUpstream(); try await mock.start(); defer { mock.stop() }
        let called = expectation(description: "provider not called"); called.isInverted = true
        mock.handler = { _, _ in called.fulfill() }
        let (server, base) = try await server(upstream: mock.url); defer { server.stop() }
        for scheme in ["bearer ", "bEaReR   ", "BEARER "] {
            var outgoing = try request(base, path: "/v1/models")
            outgoing.setValue(scheme + token, forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: outgoing)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        }
        await fulfillment(of: [called], timeout: 0.15)
    }

    func testRejectedAuthenticationAndRoutesHaveSafeLayerDiagnostics() async throws {
        let mock = MockUpstream(); try await mock.start(); defer { mock.stop() }
        let called = expectation(description: "provider not called"); called.isInverted = true
        mock.handler = { _, _ in called.fulfill() }
        let events = ProxyEventRecorder()
        let (server, base) = try await server(upstream: mock.url, onEvent: { events.append($0) }); defer { server.stop() }
        let wrongToken = "wrong-token-secret-fixture"
        let querySecret = "private-query-fixture"
        let bodySecret = "private-body-fixture"
        let pathSecret = "private-path-fixture"
        let headerSecret = "private-extra-header-fixture"

        let (_, missing) = try await URLSession.shared.data(for: request(base, path: "/v1/models", auth: false))
        XCTAssertEqual((missing as? HTTPURLResponse)?.statusCode, 401)
        for authorization in ["bearer " + token.uppercased(), "Bearer " + wrongToken, "Basic " + token, "Bearer", "Bearer    ", "Bearer " + token + " extra"] {
            var outgoing = URLRequest(url: URL(string: base.absoluteString + "/" + pathSecret + "?secret=" + querySecret)!)
            outgoing.httpMethod = "POST"
            outgoing.httpBody = Data(bodySecret.utf8)
            outgoing.setValue(authorization, forHTTPHeaderField: "Authorization")
            outgoing.setValue(headerSecret, forHTTPHeaderField: "X-Private-Header")
            let (_, response) = try await URLSession.shared.data(for: outgoing)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
        }

        var unsupported = URLRequest(url: base.appendingPathComponent(pathSecret))
        unsupported.httpMethod = "POST"
        unsupported.httpBody = Data(bodySecret.utf8)
        unsupported.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        unsupported.setValue(headerSecret, forHTTPHeaderField: "X-Private-Header")
        let (_, missingRoute) = try await URLSession.shared.data(for: unsupported)
        XCTAssertEqual((missingRoute as? HTTPURLResponse)?.statusCode, 404)
        unsupported.url = URL(string: base.absoluteString + "/v1/models?secret=" + querySecret)!
        let (_, invalidQuery) = try await URLSession.shared.data(for: unsupported)
        XCTAssertEqual((invalidQuery as? HTTPURLResponse)?.statusCode, 400)

        let diagnostics = events.messages.joined(separator: "\n")
        XCTAssertTrue(diagnostics.contains("HTTP 401): missing Authorization header"))
        XCTAssertTrue(diagnostics.contains("HTTP 401): invalid bridge credentials"))
        XCTAssertTrue(diagnostics.contains("HTTP 404): unsupported endpoint"))
        XCTAssertTrue(diagnostics.contains("HTTP 400): unsupported endpoint"))
        for sensitive in [token, token.uppercased(), apiKey, wrongToken, querySecret, bodySecret, pathSecret, headerSecret] {
            XCTAssertFalse(diagnostics.contains(sensitive), "Diagnostics must not contain sensitive request values")
        }
        await fulfillment(of: [called], timeout: 0.15)
    }

    func testSessionFailureProfileReportsOnlyAllowlistedCountsAndFieldShapes() async throws {
        let mock = MockUpstream(); try await mock.start(); defer { mock.stop() }
        let called = expectation(description: "provider not called"); called.isInverted = true
        mock.handler = { _, _ in called.fulfill() }
        let events = ProxyEventRecorder()
        let (server, base) = try await server(upstream: mock.url, sessionMode: .automatic, onEvent: { events.append($0) }); defer { server.stop() }
        let contentSecret = "private-message-content-fixture"
        let identitySecret = "private-conversation-identity-fixture"
        let metadataSecret = "private-metadata-identity-fixture"
        let headerSecret = "private-header-identity-fixture"
        let unknownRole = "private-unknown-role-fixture"
        let unknownBodyKey = "private-unknown-body-key-fixture"
        let unknownMetadataKey = "private-unknown-metadata-key-fixture"
        let unknownHeaderKey = "x-private-unknown-header-key-fixture"
        let roles = ["system", "developer", "user", "user", "assistant", "tool", "function", unknownRole]
        var messages: [[String: Any]] = roles.map { ["role": $0, "content": contentSecret] }
        messages.append(["content": contentSecret])
        let body: [String: Any] = [
            "model": "deepseek-v4.1-flash", "messages": messages,
            "conversation_id": "", "session_id": 27, "conversationId": identitySecret,
            "sessionId": NSNull(), "thread_id": [identitySecret], "chat_id": "", "prompt_cache_key": identitySecret,
            unknownBodyKey: identitySecret,
            "metadata": [
                "conversation_id": 27, "session_id": "", "conversationId": metadataSecret,
                "sessionId": [], "thread_id": "", "chat_id": metadataSecret, "prompt_cache_key": NSNull(),
                unknownMetadataKey: metadataSecret
            ] as [String: Any]
        ]
        var outgoing = try request(base)
        outgoing.setValue(nil, forHTTPHeaderField: "x-warp-conversation-id")
        outgoing.setValue(headerSecret, forHTTPHeaderField: "x-warp-session-id")
        outgoing.setValue(headerSecret, forHTTPHeaderField: "x-thread-id")
        outgoing.setValue(headerSecret, forHTTPHeaderField: unknownHeaderKey)
        outgoing.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (responseBody, response) = try await URLSession.shared.data(for: outgoing)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 409)
        XCTAssertTrue(String(decoding: responseBody, as: UTF8.self).contains("conversation_identity_required"))
        XCTAssertFalse(String(decoding: responseBody, as: UTF8.self).contains("Session request profile"))

        let profiles = events.messages.filter { $0.hasPrefix("Session request profile") }
        XCTAssertEqual(profiles.count, 1)
        let profile = try XCTUnwrap(profiles.first)
        XCTAssertTrue(profile.contains("(unrecognizedContinuation)"))
        XCTAssertTrue(profile.contains("roles[system=1,developer=1,user=2,assistant=1,tool=1,function=1,other=2]"))
        XCTAssertTrue(profile.contains("body[conversation_id=empty,session_id=other,conversationId=string,sessionId=other,thread_id=other,chat_id=empty,prompt_cache_key=string]"))
        XCTAssertTrue(profile.contains("metadata[conversation_id=other,session_id=empty,conversationId=string,sessionId=other,thread_id=empty,chat_id=string,prompt_cache_key=other]"))
        XCTAssertTrue(profile.contains("headers[x-opencode-session=missing,x-warp-conversation-id=missing,x-conversation-id=missing,x-session-id=missing,x-warp-session-id=string,x-thread-id=string]"))
        let diagnostics = events.messages.joined(separator: "\n")
        for sensitive in [contentSecret, identitySecret, metadataSecret, headerSecret, unknownRole, unknownBodyKey, unknownMetadataKey, unknownHeaderKey, token, apiKey] {
            XCTAssertFalse(diagnostics.contains(sensitive), "Structural diagnostics must never expose request values or unknown field names")
        }
        await fulfillment(of: [called], timeout: 0.15)
    }

    func testSSEAndToolCallsPreservedAndCredentialsReplaced() async throws {
        let mock = MockUpstream(); try await mock.start(); defer { mock.stop() }
        let checked = expectation(description: "headers checked")
        let payload = Data("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"read_file\",\"arguments\":\"{}\"}}]}}]}\n\ndata: [DONE]\n\n".utf8)
        mock.handler = { incoming, connection in
            XCTAssertEqual(incoming.headers["authorization"], "Bearer \(self.apiKey)")
            XCTAssertNotEqual(incoming.headers["authorization"], "Bearer \(self.token)")
            XCTAssertTrue(incoming.headers["x-opencode-session"]?.hasPrefix("warp_") == true)
            XCTAssertEqual(incoming.headers["user-agent"], "WarpOpenCodeBridge/0.1.0 (Warp coding agent; macOS)")
            XCTAssertNil(incoming.headers["x-warp-conversation-id"])
            checked.fulfill()
            MockUpstream.respond(connection, body: payload, type: "text/event-stream")
        }
        let (server, base) = try await server(upstream: mock.url); defer { server.stop() }
        let (data, response) = try await URLSession.shared.data(for: request(base))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")
        XCTAssertEqual(data, payload)
        await fulfillment(of: [checked], timeout: 2)
    }

    func testProviderRateLimitAndRetryAfterPreserved() async throws {
        let mock = MockUpstream(); try await mock.start(); defer { mock.stop() }
        let payload = Data("{\"error\":{\"message\":\"quota exhausted\"}}".utf8)
        mock.handler = { _, connection in MockUpstream.respond(connection, status: 429, body: payload, extra: "Retry-After: 60\r\n") }
        let (server, base) = try await server(upstream: mock.url); defer { server.stop() }
        let (data, response) = try await URLSession.shared.data(for: request(base))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 429)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"), "60")
        XCTAssertEqual(data, payload)
    }

    func testCompressedProviderStreamIsDecodedWithoutStaleEncodingHeader() async throws {
        let mock = MockUpstream(); try await mock.start(); defer { mock.stop() }
        let compressed = try XCTUnwrap(Data(base64Encoded: "H4sIAAAAAAAA/0tJLEm0UqhWSs7Iz0xOLVayiq5WSknNKUlUsgIK5ueVpOaVKFkBhZLzU1JTlGprY2u5uFLAmqJd/P1cY7m4AOhWGpJDAAAA"))
        mock.handler = { _, connection in
            MockUpstream.respond(connection, body: compressed, type: "text/event-stream", extra: "Content-Encoding: gzip\r\n")
        }
        let (server, base) = try await server(upstream: mock.url); defer { server.stop() }
        let (data, response) = try await URLSession.shared.data(for: request(base))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "data: {\"choices\":[{\"delta\":{\"content\":\"decoded\"}}]}\n\ndata: [DONE]\n\n")
        XCTAssertNil((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Encoding"))
    }

    func testFirstStreamEventArrivesBeforeProviderCompletesAndCancellationClosesProvider() async throws {
        let mock = MockUpstream(); try await mock.start(); defer { mock.stop() }
        let firstData = expectation(description: "first event received while upstream remains open")
        let disconnected = expectation(description: "provider connection cancelled")
        mock.handler = { _, connection in
            let event = "data: {\"choices\":[{\"delta\":{\"content\":\"first\"}}]}\n\n"
            let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
            let chunk = String(event.utf8.count, radix: 16) + "\r\n" + event + "\r\n"
            connection.send(content: Data((header + chunk).utf8), completion: .contentProcessed { _ in })
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, complete, error in
                if complete || error != nil { disconnected.fulfill() }
            }
        }
        let (server, base) = try await server(upstream: mock.url); defer { server.stop() }
        let client = StreamingClient(); defer { client.cancel() }
        client.onData = { firstData.fulfill() }
        client.start(try request(base))
        await fulfillment(of: [firstData], timeout: 2)
        client.cancel()
        await fulfillment(of: [disconnected], timeout: 2)
    }

    func testMissingIdentityFailsBeforeProviderCall() async throws {
        let mock = MockUpstream(); try await mock.start(); defer { mock.stop() }
        let called = expectation(description: "provider not called"); called.isInverted = true
        mock.handler = { _, _ in called.fulfill() }
        let (server, base) = try await server(upstream: mock.url); defer { server.stop() }
        var outgoing = try request(base); outgoing.setValue(nil, forHTTPHeaderField: "x-warp-conversation-id")
        let (data, response) = try await URLSession.shared.data(for: outgoing)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 409)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("conversation_identity_required"))
        await fulfillment(of: [called], timeout: 0.15)
    }

    func testSharedAutomaticResolverPreservesSessionAcrossProxyRestarts() async throws {
        let mock = MockUpstream(); try await mock.start(); defer { mock.stop() }
        mock.handler = { incoming, connection in
            let sessionID = incoming.headers["x-opencode-session"] ?? "missing"
            let payload = try! JSONSerialization.data(withJSONObject: ["received_session": sessionID])
            MockUpstream.respond(connection, body: payload)
        }
        let resolver = SessionResolver(mode: .automatic)
        let firstMessages = [["role": "user", "content": "Start a distinct coding conversation"]]
        let (firstProxy, firstBase) = try await server(upstream: mock.url, sessionMode: .automatic, sessionResolver: resolver)
        defer { firstProxy.stop() }
        var firstRequest = try request(firstBase)
        firstRequest.setValue(nil, forHTTPHeaderField: "x-warp-conversation-id")
        firstRequest.httpBody = try JSONSerialization.data(withJSONObject: ["model": "deepseek-v4.1-flash", "stream": false, "messages": firstMessages])
        let (firstData, firstResponse) = try await URLSession.shared.data(for: firstRequest)
        XCTAssertEqual((firstResponse as? HTTPURLResponse)?.statusCode, 200)
        let firstObject = try XCTUnwrap(JSONSerialization.jsonObject(with: firstData) as? [String: Any])
        let originalID = try XCTUnwrap(firstObject["received_session"] as? String)
        XCTAssertTrue(originalID.hasPrefix("warp_"))
        firstProxy.stop()
        let firstStillRunning = await firstProxy.isRunning
        XCTAssertFalse(firstStillRunning)

        let (secondProxy, secondBase) = try await server(upstream: mock.url, sessionMode: .automatic, sessionResolver: resolver)
        defer { secondProxy.stop() }
        var continuedRequest = try request(secondBase)
        continuedRequest.setValue(nil, forHTTPHeaderField: "x-warp-conversation-id")
        let continuation = firstMessages + [["role": "assistant", "content": "Ready for the next coding task"], ["role": "user", "content": "Continue the same conversation"]]
        continuedRequest.httpBody = try JSONSerialization.data(withJSONObject: ["model": "deepseek-v4.1-flash", "stream": false, "messages": continuation])
        let (continuedData, continuedResponse) = try await URLSession.shared.data(for: continuedRequest)
        XCTAssertEqual((continuedResponse as? HTTPURLResponse)?.statusCode, 200)
        let continuedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: continuedData) as? [String: Any])
        XCTAssertEqual(continuedObject["received_session"] as? String, originalID)
    }

    func testRedirectIsNotFollowed() async throws {
        let mock = MockUpstream(); try await mock.start(); defer { mock.stop() }
        mock.handler = { _, connection in
            MockUpstream.respond(connection, status: 307, body: Data("{}".utf8), extra: "Location: http://127.0.0.1:1/should-not-be-called\r\n")
        }
        let (server, base) = try await server(upstream: mock.url); defer { server.stop() }
        let (_, response) = try await URLSession.shared.data(for: request(base))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 307)
    }
}
