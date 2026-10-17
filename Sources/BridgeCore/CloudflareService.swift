import Foundation

public struct CloudflareLoginResult: Sendable, Equatable {
    public let domain: String?
    public let accountID: String?
    public let zoneID: String?

    public init(domain: String?, accountID: String?, zoneID: String?) {
        self.domain = domain
        self.accountID = accountID
        self.zoneID = zoneID
    }
}

public enum CloudflareServiceError: LocalizedError {
    case helperMissing
    case invalidHostname
    case invalidPort
    case missingCertificate
    case invalidCertificate
    case commandFailed(String)
    case invalidTunnelCredentials
    case tunnelNotConfigured
    case dnsRouteFailed
    case connectionTimeout
    case accountMismatch

    public var errorDescription: String? {
        switch self {
        case .helperMissing: return "cloudflared was not found. Choose a cloudflared executable in Settings, or use the packaged app."
        case .invalidHostname: return "Enter an active Cloudflare domain and a valid subdomain, using letters, numbers, and hyphens."
        case .invalidPort: return "Choose a local port between 1024 and 65535."
        case .missingCertificate: return "Connect your Cloudflare account first."
        case .invalidCertificate: return "The Cloudflare authorization could not be read. Reconnect Cloudflare with a current cloudflared helper."
        case .commandFailed(let operation): return "Cloudflare could not \(operation). Check your connection, Cloudflare permissions, and helper version."
        case .invalidTunnelCredentials: return "The saved tunnel credentials are missing or invalid. Run Create tunnel again."
        case .tunnelNotConfigured: return "Create your Cloudflare tunnel in Settings first."
        case .dnsRouteFailed: return "The tunnel was saved, but DNS routing failed. Confirm the selected domain and choose an unused subdomain, then try again. Existing DNS records are never overwritten."
        case .connectionTimeout: return "Cloudflare did not establish a tunnel connection. Check your internet connection and firewall, then turn the bridge on again."
        case .accountMismatch: return "The saved tunnel belongs to another Cloudflare account. Reconnect using the account that created this bridge."
        }
    }
}

struct CloudflareOriginCertificate: Decodable {
    let zoneID: String
    let accountID: String
    let apiToken: String
    let endpoint: String?

    static func decode(_ data: Data) throws -> Self {
        let text = String(decoding: data, as: UTF8.self)
        let begin = "-----BEGIN ARGO TUNNEL TOKEN-----"
        let end = "-----END ARGO TUNNEL TOKEN-----"
        guard let start = text.range(of: begin), let finish = text.range(of: end, range: start.upperBound..<text.endIndex) else { throw CloudflareServiceError.invalidCertificate }
        let base64 = text[start.upperBound..<finish.lowerBound].filter { !$0.isWhitespace }
        guard let json = Data(base64Encoded: String(base64)), let certificate = try? JSONDecoder().decode(Self.self, from: json), !certificate.zoneID.isEmpty, !certificate.accountID.isEmpty, !certificate.apiToken.isEmpty,
              certificate.endpoint == nil || certificate.endpoint == "" else { throw CloudflareServiceError.invalidCertificate }
        return certificate
    }
}

/// Locally managed named tunnels, isolated from the user's existing cloudflared setup.
public actor CloudflareService {
    public let store: ConfigurationStore
    private let runner: any ProcessRunning
    private let session: URLSession
    private let onLog: (@Sendable (String) -> Void)?
    private var child: ManagedProcess?
    private var connected = false
    private var connectionGeneration = UUID()

    public init(store: ConfigurationStore = ConfigurationStore(), runner: any ProcessRunning = ProcessRunner(), session: URLSession = .shared, onLog: (@Sendable (String) -> Void)? = nil) {
        self.store = store
        self.runner = runner
        self.session = session
        self.onLog = onLog
    }

    public var isRunning: Bool { child?.isRunning == true && connected }

    public nonisolated static func findHelper(configuredPath: String? = nil) -> URL? {
        let candidates = [
            configuredPath.map { URL(fileURLWithPath: $0) },
            Bundle.main.url(forResource: "cloudflared", withExtension: nil),
            Bundle.main.url(forAuxiliaryExecutable: "cloudflared"),
            URL(fileURLWithPath: "/opt/homebrew/bin/cloudflared"),
            URL(fileURLWithPath: "/usr/local/bin/cloudflared")
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// cloudflared itself opens Cloudflare's official login page and waits for authorization.
    /// A scoped child environment is required because upstream login hardcodes ~/.cloudflared.
    /// The current process and the user's real home directory are never changed.
    public func login(configuration: BridgeConfiguration = BridgeConfiguration(), force: Bool = false) async throws -> CloudflareLoginResult {
        try store.prepareDirectories()
        let priorData = try? Data(contentsOf: store.certificateURL)
        let priorAccount = priorData.flatMap { try? CloudflareOriginCertificate.decode($0).accountID }
        let boundAccount = (try? readTunnelCredentials().AccountTag) ?? ((configuration.tunnelID != nil) ? priorAccount : nil)
        if force, priorData != nil { try FileManager.default.removeItem(at: store.certificateURL) }
        do {
            if !FileManager.default.fileExists(atPath: store.certificateURL.path) {
                let helper = try helper(configuration)
                onLog?("Waiting for Cloudflare authorization in your browser.")
                let result = try await runner.run(executable: helper, arguments: ["tunnel", "login"], environment: helperEnvironment(), output: nil)
                try Task.checkCancellation()
                guard result.exitCode == 0 else { throw CloudflareServiceError.commandFailed("complete browser authorization") }
            }
            let certificate = try readCertificate()
            if let boundAccount, boundAccount != certificate.accountID { throw CloudflareServiceError.accountMismatch }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.certificateURL.path)
            let domain = await selectedDomain(certificate)
            try Task.checkCancellation()
            onLog?("Cloudflare account connected.")
            return CloudflareLoginResult(domain: domain, accountID: certificate.accountID, zoneID: certificate.zoneID)
        } catch {
            if force, let priorData {
                try store.writePrivate(priorData, to: store.certificateURL)
            } else if priorData == nil, FileManager.default.fileExists(atPath: store.certificateURL.path) {
                try FileManager.default.removeItem(at: store.certificateURL)
            }
            throw error
        }
    }

    /// Called only by the explicit Create tunnel action. Records the tunnel before routing DNS
    /// so failed DNS provisioning can be retried without creating another remote tunnel.
    public func provision(configuration: BridgeConfiguration) async throws -> BridgeConfiguration {
        try Self.validate(configuration)
        try store.prepareDirectories()
        let certificate = try readCertificate()
        let helper = try helper(configuration)
        let previouslySaved = try? store.load()
        var updated = configuration
        updated.isProvisioned = false

        // A previous attempt may have created a tunnel before DNS failed or the app closed.
        if updated.tunnelID == nil, let saved = previouslySaved, saved.tunnelName == updated.tunnelName {
            updated.tunnelID = saved.tunnelID
        }
        if updated.tunnelID == nil, FileManager.default.fileExists(atPath: store.tunnelCredentialsURL.path) {
            // Recover the owned credentials if the app exited just after tunnel creation.
            updated.tunnelID = try readTunnelID()
            if previouslySaved?.isProvisioned != true { try store.save(updated) }
        }
        if updated.tunnelID == nil {
            onLog?("Creating your Cloudflare tunnel.")
            let result = try await runner.run(executable: helper, arguments: managementArguments + ["create", "--output", "json", "--credentials-file", store.tunnelCredentialsURL.path, updated.tunnelName], environment: helperEnvironment(), output: nil)
            try Task.checkCancellation()
            guard result.exitCode == 0 else { throw CloudflareServiceError.commandFailed("create the tunnel") }
            updated.tunnelID = try readTunnelID()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.tunnelCredentialsURL.path)
            if previouslySaved?.isProvisioned != true { try store.save(updated) }
        }
        guard let tunnelID = updated.tunnelID, UUID(uuidString: tunnelID) != nil, try readTunnelID().lowercased() == tunnelID.lowercased() else { throw CloudflareServiceError.invalidTunnelCredentials }
        guard try readTunnelCredentials().AccountTag == certificate.accountID else { throw CloudflareServiceError.accountMismatch }
        onLog?("Connecting your public hostname. Existing DNS records will be preserved.")
        // Do not add --overwrite-dns. A pre-existing record must be an explicit user decision.
        let routed = try await runner.run(executable: helper, arguments: managementArguments + ["route", "dns", tunnelID, updated.hostname], environment: helperEnvironment(), output: nil)
        try Task.checkCancellation()
        guard routed.exitCode == 0 else { throw CloudflareServiceError.dnsRouteFailed }
        updated.isProvisioned = true
        try writeTunnelConfiguration(updated)
        try store.save(updated)
        onLog?("Cloudflare tunnel configured.")
        return updated
    }

    /// Returns after cloudflared reports at least one registered edge connection.
    /// Public HTTPS reachability is tested separately by the app.
    public func start(configuration: BridgeConfiguration) async throws {
        if child?.isRunning == true { return }
        try Self.validate(configuration)
        guard configuration.isProvisioned, let tunnelID = configuration.tunnelID, UUID(uuidString: tunnelID) != nil else { throw CloudflareServiceError.tunnelNotConfigured }
        guard try readTunnelID().lowercased() == tunnelID.lowercased() else { throw CloudflareServiceError.invalidTunnelCredentials }
        let helper = try helper(configuration)
        try writeTunnelConfiguration(configuration)
        connected = false
        let generation = UUID()
        connectionGeneration = generation
        let observer = TunnelReadinessObserver()
        let started = try runner.start(executable: helper, arguments: ["tunnel", "--config", store.tunnelConfigURL.path, "--no-autoupdate", "--loglevel", "info", "run", tunnelID], environment: helperEnvironment()) { [weak self] chunk in
            if observer.consume(chunk) {
                Task { await self?.markConnected(generation: generation) }
            }
        }
        child = started
        onLog?("Connecting to Cloudflare.")
        do {
            try await withTaskCancellationHandler {
                for _ in 0..<150 {
                    try Task.checkCancellation()
                    guard connectionGeneration == generation, started.isRunning else { throw CloudflareServiceError.commandFailed("start the tunnel") }
                    if connected {
                        onLog?("Cloudflare tunnel connected.")
                        return
                    }
                    try await Task.sleep(for: .milliseconds(200))
                }
                throw CloudflareServiceError.connectionTimeout
            } onCancel: {
                started.stop()
            }
        } catch {
            started.stop()
            child = nil
            connected = false
            throw error
        }
    }

    public func stop() async {
        let stopping = child
        connectionGeneration = UUID()
        child = nil
        connected = false
        stopping?.stop()
        if let stopping { _ = await stopping.wait() }
        onLog?("Cloudflare tunnel stopped.")
    }

    private func markConnected(generation: UUID) {
        if connectionGeneration == generation { connected = true }
    }

    private func helper(_ configuration: BridgeConfiguration) throws -> URL {
        guard let executable = Self.findHelper(configuredPath: configuration.helperPath) else { throw CloudflareServiceError.helperMissing }
        return executable
    }

    private var managementArguments: [String] { ["tunnel", "--origincert", store.certificateURL.path, "--no-autoupdate"] }

    private func helperEnvironment() -> [String: String] {
        // Prevent inherited CLI settings from redirecting endpoints or force-overwriting DNS.
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("TUNNEL_") && !$0.key.hasPrefix("CF_") && !$0.key.hasPrefix("CLOUDFLARED_") }
        environment["HOME"] = store.helperHome.path
        environment["NO_AUTOUPDATE"] = "true"
        return environment
    }

    private func readCertificate() throws -> CloudflareOriginCertificate {
        guard FileManager.default.fileExists(atPath: store.certificateURL.path) else { throw CloudflareServiceError.missingCertificate }
        return try CloudflareOriginCertificate.decode(Data(contentsOf: store.certificateURL))
    }

    private struct TunnelCredentials: Decodable { let TunnelID: String; let AccountTag: String; let TunnelSecret: String }

    private func readTunnelCredentials() throws -> TunnelCredentials {
        guard let data = try? Data(contentsOf: store.tunnelCredentialsURL), let value = try? JSONDecoder().decode(TunnelCredentials.self, from: data), UUID(uuidString: value.TunnelID) != nil, !value.AccountTag.isEmpty, let secret = Data(base64Encoded: value.TunnelSecret), secret.count >= 32 else { throw CloudflareServiceError.invalidTunnelCredentials }
        return value
    }

    private func readTunnelID() throws -> String { try readTunnelCredentials().TunnelID }

    private func writeTunnelConfiguration(_ configuration: BridgeConfiguration) throws {
        guard let tunnelID = configuration.tunnelID else { throw CloudflareServiceError.tunnelNotConfigured }
        try store.prepareDirectories()
        // JSON is valid YAML. Encoding avoids YAML injection through paths or hostnames.
        let configurationObject: [String: Any] = [
            "tunnel": tunnelID,
            "credentials-file": store.tunnelCredentialsURL.path,
            "metrics": "127.0.0.1:0",
            "ingress": [
                ["hostname": configuration.hostname, "service": "http://127.0.0.1:\(configuration.localPort)"],
                ["service": "http_status:404"]
            ]
        ]
        // YAML 1.1 parsers reject JSON's optional escaped slash (\/). cloudflared
        // reads this file through its YAML decoder even when its extension is .json.
        try store.writePrivate(JSONSerialization.data(withJSONObject: configurationObject, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), to: store.tunnelConfigURL)
    }

    private func selectedDomain(_ certificate: CloudflareOriginCertificate) async -> String? {
        guard certificate.zoneID.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil else { return nil }
        let url = URL(string: "https://api.cloudflare.com/client/v4/zones/\(certificate.zoneID)")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("Bearer \(certificate.apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("WarpOpenCodeBridge/0.1.0", forHTTPHeaderField: "User-Agent")
        // Some login-issued tokens cannot read zone metadata. The UI retains a manual domain field.
        guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any], envelope["success"] as? Bool == true,
              let zone = envelope["result"] as? [String: Any], let domain = zone["name"] as? String else { return nil }
        return domain
    }

    public nonisolated static func validate(_ configuration: BridgeConfiguration) throws {
        let domain = configuration.domain
        let subdomain = configuration.subdomain
        let labelPattern = "^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$"
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard domain.utf8.count <= 253, labels.count >= 2, labels.allSatisfy({ String($0).range(of: labelPattern, options: .regularExpression) != nil }), subdomain.range(of: labelPattern, options: .regularExpression) != nil,
              configuration.hostname.utf8.count <= 253 else { throw CloudflareServiceError.invalidHostname }
        guard configuration.localPort >= 1024 else { throw CloudflareServiceError.invalidPort }
        guard configuration.tunnelName.range(of: "^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$", options: .regularExpression) != nil else { throw CloudflareServiceError.invalidHostname }
    }
}

private final class TunnelReadinessObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var tail = ""

    func consume(_ chunk: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        tail = String((tail + chunk).suffix(1_024))
        return tail.contains("Registered tunnel connection")
    }
}
