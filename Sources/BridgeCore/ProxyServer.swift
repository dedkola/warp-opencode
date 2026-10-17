import CryptoKit
import Foundation
import Network

public struct ProxyEvent: Sendable {
    public enum Kind: String, Sendable { case info, warning, error }
    public let timestamp: Date
    public let kind: Kind
    public let message: String
    public init(kind: Kind = .info, message: String) {
        timestamp = Date(); self.kind = kind; self.message = message
    }
}

public enum ProxyFailure: Error, LocalizedError {
    case invalidConfiguration, listener(String)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Set a Go API key, a private relay token, a model, and a nonzero local port."
        case .listener(let message): return "The local proxy could not start: \(message)"
        }
    }
}

/// Loopback-only HTTP relay. The public surface is provided by the owned Cloudflare tunnel.
public final class ProxyServer: @unchecked Sendable {
    public static let goChatURL = URL(string: "https://opencode.ai/inference/go/openai/v1/chat/completions")!
    private let queue = DispatchQueue(label: "dev.warpgobridge.proxy")
    private let configuration: BridgeConfiguration
    private let goAPIKey: String
    private let relayToken: String
    private let upstreamURL: URL
    private let onEvent: @Sendable (ProxyEvent) -> Void
    private let sessions: SessionResolver
    private var listener: NWListener?
    private var peers: [UUID: ProxyPeer] = [:]

    public init(configuration: BridgeConfiguration, goAPIKey: String, relayToken: String,
                upstreamURL: URL = ProxyServer.goChatURL,
                sessionResolver: SessionResolver? = nil,
                onEvent: @escaping @Sendable (ProxyEvent) -> Void = { _ in }) {
        self.configuration = configuration; self.goAPIKey = goAPIKey
        self.relayToken = relayToken; self.upstreamURL = upstreamURL; self.onEvent = onEvent
        sessions = sessionResolver ?? SessionResolver(mode: configuration.sessionMode, manualSessionID: configuration.manualSessionID)
    }

    public func start() async throws {
        guard !goAPIKey.isEmpty, relayToken.utf8.count >= 32, configuration.localPort > 0,
              !configuration.modelIDs.isEmpty,
              !goAPIKey.contains("\n"), !goAPIKey.contains("\r") else { throw ProxyFailure.invalidConfiguration }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard self.listener == nil else { continuation.resume(); return }
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: self.configuration.localPort)!)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    var completed = false
                    listener.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            if !completed { completed = true; continuation.resume() }
                            self.onEvent(ProxyEvent(message: "Local proxy listening on 127.0.0.1:\(self.configuration.localPort)."))
                        case .failed(let error):
                            self.listener = nil
                            if !completed { completed = true; continuation.resume(throwing: ProxyFailure.listener(error.localizedDescription)) }
                            self.onEvent(ProxyEvent(kind: .error, message: "Local proxy listener failed."))
                        case .cancelled:
                            if !completed { completed = true; continuation.resume(throwing: CancellationError()) }
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { connection in
                        guard self.peers.count < 16 else { connection.cancel(); return }
                        let id = UUID()
                        let peer = ProxyPeer(connection: connection, queue: self.queue,
                                             configuration: self.configuration, apiKey: self.goAPIKey,
                                             relayToken: self.relayToken, upstreamURL: self.upstreamURL,
                                             sessions: self.sessions, onEvent: self.onEvent,
                                             onFinish: { [weak self] in self?.peers.removeValue(forKey: id) })
                        self.peers[id] = peer; peer.start()
                    }
                    listener.start(queue: self.queue)
                } catch { self.listener = nil; continuation.resume(throwing: error) }
            }
        }
    }

    public func stop() {
        queue.async {
            self.listener?.cancel(); self.listener = nil
            let current = Array(self.peers.values)
            current.forEach { $0.close() }
            self.peers.removeAll()
            self.onEvent(ProxyEvent(message: "Local proxy stopped."))
        }
    }

    public var isRunning: Bool {
        get async {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: self.listener?.state == .ready) }
            }
        }
    }

    public func resetSessions(manualSessionID: String) {
        sessions.reset(manualSessionID: manualSessionID)
        onEvent(ProxyEvent(kind: .warning, message: "Sessions reset. Use a new Warp chat when using history matching."))
    }
}

private final class ProxyPeer: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let configuration: BridgeConfiguration
    private let apiKey: String
    private let relayToken: String
    private let upstreamURL: URL
    private let sessions: SessionResolver
    private let onEvent: @Sendable (ProxyEvent) -> Void
    private let onFinish: () -> Void
    private var parser = HTTPRequestParser()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var receivedRequest = false
    private var closed = false
    private var sentHeaders = false
    private var streaming = false
    private var pendingBytes = 0
    private var suspended = false
    private var responseBytes = 0
    private var requestBytes = 0
    private var timeout: DispatchWorkItem?
    private var heartbeat: DispatchSourceTimer?
    private var sseBoundary = SSEBoundaryTracker()

    init(connection: NWConnection, queue: DispatchQueue, configuration: BridgeConfiguration,
         apiKey: String, relayToken: String, upstreamURL: URL, sessions: SessionResolver,
         onEvent: @escaping @Sendable (ProxyEvent) -> Void, onFinish: @escaping () -> Void) {
        self.connection = connection; self.queue = queue; self.configuration = configuration
        self.apiKey = apiKey; self.relayToken = relayToken; self.upstreamURL = upstreamURL
        self.sessions = sessions; self.onEvent = onEvent; self.onFinish = onFinish
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
            if case .cancelled = state { self?.close() }
        }
        connection.start(queue: queue)
        let deadline = DispatchWorkItem { [weak self] in self?.respondError(408, "Request timed out.") }
        timeout = deadline; queue.asyncAfter(deadline: .now() + 30, execute: deadline)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                if self.receivedRequest { self.close(); return }
                do {
                    let request = try self.parser.append(data)
                    if let headers = self.parser.headers, !self.authorized(headers) {
                        let reason = headers["authorization"] == nil ? "missing Authorization header" : "invalid bridge credentials"
                        self.onEvent(ProxyEvent(kind: .warning, message: "Bridge rejected request (HTTP 401): \(reason). Copy the bridge API key from Connect Warp into Warp's endpoint settings."))
                        self.respondError(401, "A valid bridge access token is required."); return
                    }
                    if let request {
                        self.receivedRequest = true; self.timeout?.cancel(); self.handle(request)
                    }
                } catch HTTPParseError.tooLarge { self.respondError(413, "Request exceeds 16 MB."); return }
                catch { self.respondError(400, "Malformed HTTP request."); return }
            }
            if error != nil || complete { self.close(); return }
            self.receive() // Detect downstream cancellation while the upstream stream is running.
        }
    }

    private func authorized(_ headers: [String: String]) -> Bool {
        guard let value = headers["authorization"], let separator = value.firstIndex(of: " "),
              value[..<separator].lowercased() == "bearer" else { return false }
        // HTTP auth schemes are case-insensitive; credentials remain case-sensitive.
        // RFC authentication syntax allows one or more ASCII spaces as the separator.
        let token = value[value.index(after: separator)...].drop(while: { $0 == " " })
        guard !token.isEmpty, !token.contains(where: { $0.isWhitespace }) else { return false }
        let supplied = SHA256.hash(data: Data(token.utf8))
        let expected = SHA256.hash(data: Data(relayToken.utf8))
        return zip(supplied, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func handle(_ request: HTTPRequestMessage) {
        guard let components = URLComponents(string: request.target), components.query == nil,
              components.fragment == nil else {
            onEvent(ProxyEvent(kind: .warning, message: "Bridge rejected request (HTTP 400): unsupported endpoint query or fragment. Copy the Endpoint URL from Connect Warp."))
            respondError(400, "Use the endpoint path without query parameters."); return
        }
        switch (request.method, components.path) {
        case ("GET", "/healthz"):
            respondJSON(200, ["status": "ok", "service": "warp-go-bridge"])
        case ("GET", "/v1/models"):
            respondJSON(200, ["object": "list", "data": configuration.modelIDs.map {
                ["id": $0, "object": "model", "created": 0, "owned_by": "opencode-go"] as [String: Any]
            }])
        case ("POST", "/v1/chat/completions"):
            forward(request)
        default:
            onEvent(ProxyEvent(kind: .warning, message: "Bridge rejected request (HTTP 404): unsupported endpoint path or method. Copy the Endpoint URL from Connect Warp."))
            respondError(404, "This bridge supports /v1/chat/completions, /v1/models and /healthz.")
        }
    }

    private func forward(_ incoming: HTTPRequestMessage) {
        guard let contentType = incoming.headers["content-type"], contentType.lowercased().hasPrefix("application/json"),
              let object = try? JSONSerialization.jsonObject(with: incoming.body),
              let body = object as? [String: Any], let model = body["model"] as? String,
              let messages = body["messages"] as? [[String: Any]], !messages.isEmpty else {
            respondError(400, "Send a JSON Chat Completions request with a model and messages."); return
        }
        guard configuration.modelIDs.contains(model) else { respondError(400, "This model is not enabled in bridge settings."); return }
        let resolution: SessionResolver.Resolution
        do { resolution = try sessions.resolve(headers: incoming.headers, body: body) }
        catch {
            onEvent(ProxyEvent(kind: .warning, message: error.localizedDescription))
            onEvent(ProxyEvent(kind: .warning, message: sessionRequestProfile(error: error, messages: messages, body: body, headers: incoming.headers)))
            respondError(409, error.localizedDescription, type: "conversation_identity_required"); return
        }
        onEvent(ProxyEvent(message: "Forwarding model request; session source: \(resolution.source.rawValue)."))
        requestBytes = incoming.body.count
        var request = URLRequest(url: upstreamURL)
        request.httpMethod = "POST"; request.httpBody = incoming.body
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("WarpOpenCodeBridge/0.1.0 (Warp coding agent; macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue(resolution.id, forHTTPHeaderField: "x-opencode-session")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(body["stream"] as? Bool == true ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        let delegateQueue = OperationQueue(); delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        task = session?.dataTask(with: request); task?.resume()
    }

    /// A fixed allowlist of structural facts. Never include field values, unknown names,
    /// message contents, identifiers, or their fingerprints in diagnostics.
    private func sessionRequestProfile(error: Error, messages: [[String: Any]], body: [String: Any], headers: [String: String]) -> String {
        let failure: String
        switch error as? SessionResolver.Failure {
        case .missingIdentity: failure = "missingIdentity"
        case .ambiguousHistory: failure = "ambiguousHistory"
        case .unrecognizedContinuation: failure = "unrecognizedContinuation"
        case .capacity: failure = "capacity"
        case nil: failure = "invalidRequest"
        }
        let roles = ["system", "developer", "user", "assistant", "tool", "function", "other"]
        var counts = Dictionary(uniqueKeysWithValues: roles.map { ($0, 0) })
        for message in messages {
            let role = message["role"] as? String ?? "other"
            counts[roles.contains(role) ? role : "other", default: 0] += 1
        }
        let roleProfile = roles.map { "\($0)=\(counts[$0, default: 0])" }.joined(separator: ",")
        let identityFields = ["conversation_id", "session_id", "conversationId", "sessionId", "thread_id", "chat_id", "prompt_cache_key"]
        let metadata = body["metadata"] as? [String: Any] ?? [:]
        func shape(_ value: Any?) -> String {
            guard let value else { return "missing" }
            guard let string = value as? String else { return "other" }
            return string.isEmpty ? "empty" : "string"
        }
        let bodyProfile = identityFields.map { "\($0)=\(shape(body[$0]))" }.joined(separator: ",")
        let metadataProfile = identityFields.map { "\($0)=\(shape(metadata[$0]))" }.joined(separator: ",")
        let headerFields = ["x-opencode-session", "x-warp-conversation-id", "x-conversation-id", "x-session-id", "x-warp-session-id", "x-thread-id"]
        let headerProfile = headerFields.map { "\($0)=\(shape(headers[$0]))" }.joined(separator: ",")
        return "Session request profile (\(failure)): roles[\(roleProfile)]; body[\(bodyProfile)]; metadata[\(metadataProfile)]; headers[\(headerProfile)]."
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward subscription credentials to a redirected host.
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !closed, let response = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        streaming = response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true
        let type = streaming ? "text/event-stream" : "application/json"
        var head = "HTTP/1.1 \(response.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode))\r\nContent-Type: \(type)\r\nTransfer-Encoding: chunked\r\nConnection: close\r\nCache-Control: no-store\r\nX-Accel-Buffering: no\r\n"
        for name in ["Retry-After", "x-request-id"] {
            if let value = response.value(forHTTPHeaderField: name), !value.contains("\r"), !value.contains("\n") {
                head += "\(name): \(value)\r\n"
            }
        }
        head += "\r\n"; sentHeaders = true; send(Data(head.utf8))
        onEvent(ProxyEvent(kind: response.statusCode >= 400 ? .warning : .info, message: "OpenCode returned HTTP \(response.statusCode)."))
        if streaming {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 20, repeating: 20)
            timer.setEventHandler { [weak self] in
                guard let self, !self.closed, self.pendingBytes < 64 * 1024,
                      self.sseBoundary.isAtEventBoundary else { return }
                self.sendChunk(Data(": bridge keepalive\n\n".utf8))
            }
            heartbeat = timer; timer.resume()
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !closed else { return }
        responseBytes += data.count
        if streaming { sseBoundary.observe(data) }
        sendChunk(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !closed else { return }
        heartbeat?.cancel(); heartbeat = nil
        if let error {
            onEvent(ProxyEvent(kind: .error, message: "Upstream connection ended before completion (\((error as NSError).code))."))
            if !sentHeaders { respondError(502, "OpenCode connection failed or timed out."); return }
            // Deliberately omit the terminating HTTP chunk on transport failure. The caller
            // must see a truncated stream, rather than a false successful completion.
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { [weak self] _ in self?.close() })
            return
        }
        onEvent(ProxyEvent(message: "Request complete: \(requestBytes) input bytes, \(responseBytes) output bytes."))
        send(Data("0\r\n\r\n".utf8), final: true)
    }

    private func sendChunk(_ data: Data) {
        guard !data.isEmpty else { return }
        var frame = Data(String(data.count, radix: 16).utf8)
        frame.append(Data("\r\n".utf8)); frame.append(data); frame.append(Data("\r\n".utf8))
        send(frame)
    }

    private func send(_ data: Data, final: Bool = false) {
        guard !closed else { return }
        pendingBytes += data.count
        if pendingBytes > 1024 * 1024, !suspended { suspended = true; task?.suspend() }
        connection.send(content: data, contentContext: final ? .finalMessage : .defaultMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            self.pendingBytes -= data.count
            if self.suspended, self.pendingBytes < 256 * 1024 { self.suspended = false; self.task?.resume() }
            if error != nil || final { self.close() }
        })
    }

    private func respondError(_ status: Int, _ message: String, type: String = "bridge_error") {
        respondJSON(status, ["error": ["message": message, "type": type, "code": status]])
    }

    private func respondJSON(_ status: Int, _ object: [String: Any]) {
        guard !closed, !sentHeaders, let payload = try? JSONSerialization.data(withJSONObject: object) else { close(); return }
        sentHeaders = true
        let head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        var response = Data(head.utf8); response.append(payload); send(response, final: true)
    }

    func close() {
        guard !closed else { return }; closed = true
        timeout?.cancel(); heartbeat?.cancel(); heartbeat = nil
        if suspended { task?.resume(); suspended = false }
        task?.cancel(); session?.invalidateAndCancel(); session = nil; task = nil
        connection.stateUpdateHandler = nil; connection.cancel(); onFinish()
    }
}
