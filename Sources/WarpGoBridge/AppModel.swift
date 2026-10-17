import AppKit
import BridgeCore
import Combine
import Foundation
import SwiftUI

@MainActor
enum BridgePhase: Equatable {
    case off, connecting, ready, error

    var title: String {
        switch self {
        case .off: "Off"
        case .connecting: "Connecting"
        case .ready: "Ready"
        case .error: "Error"
        }
    }

    var symbol: String {
        switch self {
        case .off: "circle"
        case .connecting: "arrow.triangle.2.circlepath"
        case .ready: "checkmark.circle.fill"
        case .error: "exclamationmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .off: .secondary
        case .connecting: .orange
        case .ready: .green
        case .error: .red
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var phase: BridgePhase = .off
    @Published var domain = ""
    @Published var subdomain = "warp-go"
    @Published var goAPIKey = ""
    @Published var modelID = "deepseek-v4.1-flash"
    @Published private(set) var relayToken = ""
    @Published private(set) var hasSavedGoKey = false
    @Published private(set) var cloudflareAuthorized = false
    @Published private(set) var helperAvailable = false
    @Published private(set) var helperStatus = "Tunnel helper not found"
    @Published private(set) var isBusy = false
    @Published private(set) var isAuthorizing = false
    @Published private(set) var operationStatus = ""
    @Published private(set) var latestError: String?
    @Published var presentError = false
    @Published private(set) var connectionTestStatus = ""
    @Published private(set) var connectionTestSucceeded = false
    @Published private(set) var proxyStatus = "Stopped"
    @Published private(set) var tunnelStatus = "Stopped"
    @Published private(set) var diagnosticsText = ""
    @Published private(set) var eventCount = "0"
    @Published var sessionMode: SessionMode = .automatic {
        didSet {
            guard sessionMode != oldValue else { return }
            configuration.sessionMode = sessionMode
            retainedSessionResolver = nil
            do { try store.save(configuration) }
            catch { report(error) }
        }
    }

    private let store: ConfigurationStore
    private let credentials: any CredentialStoring
    private var configuration: BridgeConfiguration
    private var savedGoKey: String?
    private var proxy: ProxyServer?
    private var retainedSessionResolver: SessionResolver?
    private var operation: Task<Void, Never>?
    private var operationID = UUID()
    private var monitor: Task<Void, Never>?
    private var events: [String] = []
    private var totalEvents = 0
    private lazy var cloudflare = CloudflareService(store: store, onLog: { [weak self] message in
        Task { @MainActor in self?.record(message) }
    })

    var endpointURL: String { configuration.tunnelID == nil ? "" : configuration.endpointURL }
    var configuredModels: [String] { configuration.modelIDs }
    var isConfigured: Bool { configuration.isProvisioned && configuration.tunnelID != nil && hasSavedGoKey && !relayToken.isEmpty }
    var canPrepare: Bool {
        cloudflareAuthorized && helperAvailable && !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !subdomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (hasSavedGoKey || !goAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    var manualSessionDisplay: String { String(configuration.manualSessionID.prefix(12)) + "…" }
    var sessionModeExplanation: String {
        switch sessionMode {
        case .automatic:
            "Prefers an explicit conversation ID. Otherwise it matches full message-history prefixes in memory while this app runs, including across Off/On. This is a best-effort fallback; trimmed or ambiguous histories are rejected."
        case .strict:
            "Requires a stable conversation identifier in every request. If Warp omits that metadata, the request is rejected with a clear explanation."
        case .manual:
            "Use only one Warp conversation through this bridge at a time. Click New session before starting a different chat; all model calls share this session until you change it."
        }
    }

    init(store: ConfigurationStore = ConfigurationStore(), credentials: any CredentialStoring = KeychainCredentialStore()) {
        self.store = store
        self.credentials = credentials
        var startupError: Error?
        do { configuration = try store.load() }
        catch {
            configuration = BridgeConfiguration()
            startupError = error
        }
        domain = configuration.domain
        subdomain = configuration.subdomain
        modelID = configuration.modelIDs.joined(separator: ", ")
        sessionMode = configuration.sessionMode
        do {
            savedGoKey = try credentials.get(.goAPIKey)
            hasSavedGoKey = savedGoKey?.isEmpty == false
            relayToken = try credentials.get(.relayToken) ?? ""
        } catch { startupError = error }
        refreshHelperStatus()
        cloudflareAuthorized = FileManager.default.fileExists(atPath: store.certificateURL.path)
        if let startupError { report(startupError, showAlert: false) }
    }

    func chooseHelper() {
        let panel = NSOpenPanel()
        panel.title = "Choose the cloudflared executable"
        panel.message = "Use the official cloudflared executable from Cloudflare or Homebrew."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            report(AppError.message("The selected file is not an executable cloudflared helper."))
            return
        }
        configuration.helperPath = url.path
        do {
            try store.save(configuration)
            refreshHelperStatus()
            record("Selected tunnel helper: \(url.lastPathComponent).")
        } catch { report(error) }
    }

    func loginCloudflare() {
        guard !isBusy && phase != .ready else { return }
        beginOperation(status: "Opening Cloudflare login…", authorizing: true) { [self] in
            let result = try await cloudflare.login(configuration: configuration, force: cloudflareAuthorized)
            try Task.checkCancellation()
            cloudflareAuthorized = FileManager.default.fileExists(atPath: store.certificateURL.path)
            domain = result.domain ?? ""
            record("Cloudflare authorization saved.\(domain.isEmpty ? " Enter the domain you authorized." : " Domain: \(domain).")")
        }
    }

    func prepareConnection() {
        guard canPrepare && !isBusy && phase != .ready else { return }
        beginOperation(status: "Creating tunnel and DNS…") { [self] in
            var candidate = configuration
            candidate.domain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            candidate.subdomain = subdomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var seenModels = Set<String>()
            candidate.modelIDs = modelID.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seenModels.insert($0).inserted }
            candidate.sessionMode = sessionMode
            let newKey = goAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newKey.isEmpty {
                try credentials.set(newKey, for: .goAPIKey)
                savedGoKey = newKey
                hasSavedGoKey = true
                goAPIKey = ""
            }
            if relayToken.isEmpty {
                let generatedToken = try KeychainCredentialStore.generateRelayToken()
                try credentials.set(generatedToken, for: .relayToken)
                relayToken = generatedToken
            }
            candidate = try await cloudflare.provision(configuration: candidate)
            try Task.checkCancellation()
            try store.save(candidate)
            configuration = candidate
            domain = candidate.domain
            subdomain = candidate.subdomain
            connectionTestStatus = "Bridge created. Turn it on, then copy the settings into Warp."
            connectionTestSucceeded = false
            record("Bridge configured for \(candidate.hostname).")
        }
    }

    func start() {
        guard isConfigured && !isBusy && phase != .ready && phase != .connecting else { return }
        phase = .connecting
        beginOperation(status: "Starting local proxy and tunnel…") { [self] in
            try await startComponents()
        }
    }

    func stop() {
        guard operationStatus != "Stopping…" else { return }
        phase = .off
        let pendingOperation = operation
        pendingOperation?.cancel()
        let stopID = UUID()
        operationID = stopID
        operation = nil
        monitor?.cancel()
        monitor = nil
        proxy?.stop()
        proxy = nil
        proxyStatus = "Stopped"
        isBusy = true
        isAuthorizing = false
        operationStatus = "Stopping…"
        operation = Task { [self] in
            await cloudflare.stop()
            // The canceled start may still be unwinding its catch/cleanup. Keep
            // the switch disabled until it can no longer stop a later tunnel.
            await pendingOperation?.value
            guard operationID == stopID else { return }
            tunnelStatus = "Stopped"
            phase = .off
            isBusy = false
            operationStatus = ""
            operation = nil
            record("Bridge stopped.")
        }
    }

    func shutdown() async {
        let pendingOperation = operation
        pendingOperation?.cancel()
        operationID = UUID()
        operation = nil
        monitor?.cancel()
        proxy?.stop()
        proxy = nil
        await cloudflare.stop()
        await pendingOperation?.value
        phase = .off
    }

    func cancelOperation() {
        guard isAuthorizing else { return }
        operation?.cancel()
        isAuthorizing = false
        operationStatus = "Canceling authorization…"
        record("Cloudflare authorization canceled.")
    }

    func newSession() {
        let previousID = configuration.manualSessionID
        configuration.manualSessionID = UUID().uuidString
        do {
            try store.save(configuration)
            resolverForCurrentConfiguration().reset(manualSessionID: configuration.manualSessionID)
            record("Started a new manual session. Use a new Warp conversation.")
        } catch {
            configuration.manualSessionID = previousID
            report(error)
        }
    }

    func resetHistory() {
        resolverForCurrentConfiguration().reset(manualSessionID: configuration.manualSessionID)
        record("Conversation routing history reset. Start new Warp chats.")
    }

    func testConnection() {
        guard isConfigured && !isBusy else { return }
        beginOperation(status: "Testing public connection…") { [self] in
            if phase != .ready {
                phase = .connecting
                try await startComponents()
            }
            connectionTestStatus = "Checking the public endpoint…"
            connectionTestSucceeded = false
            let url = URL(string: configuration.endpointURL + "/models")!
            var request = URLRequest(url: url)
            request.setValue("Bearer \(relayToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await probePublicEndpoint(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode.description ?? "unknown"
                throw AppError.message("The public bridge returned HTTP \(code). DNS may still be propagating; wait briefly and test again.")
            }
            struct ModelList: Decodable {
                struct Model: Decodable { let id: String }
                let object: String
                let data: [Model]
            }
            guard let list = try? JSONDecoder().decode(ModelList.self, from: data), list.object == "list", Set(list.data.map(\.id)) == Set(configuration.modelIDs) else {
                throw AppError.message("The public URL did not return this bridge’s model list. Check Cloudflare routing and any access or browser challenge rules for this hostname.")
            }
            connectionTestStatus = "Public endpoint and bridge token verified. No model request was sent."
            connectionTestSucceeded = true
            record("Public HTTPS models endpoint verified with bridge authentication.")
        }
    }

    private func probePublicEndpoint(_ originalRequest: URLRequest) async throws -> (Data, URLResponse) {
        let deadline = ProcessInfo.processInfo.systemUptime + PublicEndpointRetryPolicy.maximumDuration
        var finalResponse: (Data, URLResponse)?
        var finalNetworkError: Error?
        for attempt in 1...PublicEndpointRetryPolicy.maximumAttempts {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            var request = originalRequest
            request.timeoutInterval = min(PublicEndpointRetryPolicy.requestTimeout, remaining)
            do {
                let result = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()
                guard let http = result.1 as? HTTPURLResponse,
                      PublicEndpointRetryPolicy.shouldRetry(statusCode: http.statusCode) else {
                    return result
                }
                finalResponse = result
                finalNetworkError = nil
            } catch {
                try Task.checkCancellation()
                guard PublicEndpointRetryPolicy.shouldRetry(error: error) else { throw error }
                finalNetworkError = error
                finalResponse = nil
            }
            let waitRemaining = deadline - ProcessInfo.processInfo.systemUptime
            guard attempt < PublicEndpointRetryPolicy.maximumAttempts, waitRemaining > 0 else { break }
            connectionTestStatus = "Waiting for public endpoint…"
            operationStatus = "Waiting for public endpoint…"
            try await Task.sleep(for: .seconds(min(PublicEndpointRetryPolicy.retryDelay, waitRemaining)))
        }
        try Task.checkCancellation()
        if let finalNetworkError { throw finalNetworkError }
        if let finalResponse { return finalResponse }
        throw AppError.message("The public endpoint did not become reachable within 30 seconds. Check your connection and try again.")
    }

    func refreshDiagnostics() {
        refreshHelperStatus()
        let generation = operationID
        Task { [self] in
            let running = await cloudflare.isRunning
            let localRunning = await proxy?.isRunning ?? false
            guard operationID == generation else { return }
            tunnelStatus = running ? "Running" : "Stopped"
            proxyStatus = localRunning ? "Listening locally" : "Stopped"
            if phase == .ready && (!running || !localRunning) {
                proxy?.stop()
                proxy = nil
                proxyStatus = "Stopped"
                phase = .error
                latestError = running
                    ? "The local proxy stopped. Turn the bridge off and on to reconnect."
                    : "The Cloudflare tunnel stopped. Turn the bridge off and on to reconnect."
                record(latestError!)
                monitor?.cancel()
                monitor = nil
                await cloudflare.stop()
                if operationID == generation { tunnelStatus = "Stopped" }
            }
        }
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func openWarp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.warp.Warp-Stable") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        } else if let url = URL(string: "warp://") {
            NSWorkspace.shared.open(url)
        }
    }

    func openDataFolder() {
        do {
            try store.prepareDirectories()
            NSWorkspace.shared.open(store.root)
        } catch { report(error) }
    }

    private func resolverForCurrentConfiguration() -> SessionResolver {
        if let retainedSessionResolver { return retainedSessionResolver }
        let resolver = SessionResolver(mode: configuration.sessionMode, manualSessionID: configuration.manualSessionID)
        retainedSessionResolver = resolver
        return resolver
    }

    private func startComponents() async throws {
        guard let key = savedGoKey, !key.isEmpty else { throw AppError.message("Add your OpenCode Go key in Setup.") }
        latestError = nil
        proxyStatus = "Starting"
        let server = ProxyServer(configuration: configuration, goAPIKey: key, relayToken: relayToken, sessionResolver: resolverForCurrentConfiguration(), onEvent: { [weak self] event in
            Task { @MainActor in self?.record(event.message) }
        })
        proxy = server
        do {
            try await server.start()
            try Task.checkCancellation()
            proxyStatus = "Listening locally"
            tunnelStatus = "Connecting"
            try await cloudflare.start(configuration: configuration)
            try Task.checkCancellation()
            tunnelStatus = "Running"
            phase = .ready
            record("Bridge ready. Session routing: \(configuration.sessionMode.rawValue).")
            startMonitoring()
        } catch {
            server.stop()
            proxy = nil
            proxyStatus = "Stopped"
            await cloudflare.stop()
            tunnelStatus = "Stopped"
            throw error
        }
    }

    private func startMonitoring() {
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, self.phase == .ready else { break }
                self.refreshDiagnostics()
            }
        }
    }

    private func beginOperation(status: String, authorizing: Bool = false, action: @escaping @MainActor () async throws -> Void) {
        let id = UUID()
        operationID = id
        isBusy = true
        isAuthorizing = authorizing
        operationStatus = status
        latestError = nil
        operation = Task { [self] in
            defer {
                if operationID == id {
                    isBusy = false
                    isAuthorizing = false
                    operationStatus = ""
                    operation = nil
                }
            }
            do { try await action() }
            catch is CancellationError { }
            catch {
                if operationID == id {
                    if phase == .connecting { phase = .error }
                    report(error)
                }
            }
        }
    }

    private func refreshHelperStatus() {
        if let helper = CloudflareService.findHelper(configuredPath: configuration.helperPath) {
            helperAvailable = true
            helperStatus = "Tunnel helper ready"
            if configuration.helperPath == nil { configuration.helperPath = helper.path }
        } else {
            helperAvailable = false
            helperStatus = "Tunnel helper not found"
        }
    }

    private func record(_ message: String) {
        // Core emits routing/status events only. Do not append requests or response bodies here.
        let stamp = Date.now.formatted(date: .omitted, time: .standard)
        let sanitized = message
            .replacingOccurrences(of: relayToken.isEmpty ? "\u{0}" : relayToken, with: "[redacted]")
            .replacingOccurrences(of: savedGoKey?.isEmpty == false ? savedGoKey! : "\u{0}", with: "[redacted]")
        events.append("[\(stamp)] \(sanitized)")
        if events.count > 300 { events.removeFirst(events.count - 300) }
        totalEvents += 1
        eventCount = String(totalEvents)
        diagnosticsText = events.joined(separator: "\n")
    }

    private func report(_ error: Error, showAlert: Bool = true) {
        latestError = error.localizedDescription
        presentError = showAlert
        record(error.localizedDescription)
    }
}

private enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { value } else { nil } }
}

@MainActor
final class BridgeAppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?
    private var terminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating, let model = Self.model else { return .terminateNow }
        terminating = true
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
