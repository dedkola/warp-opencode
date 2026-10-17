import Foundation
#if !PORTABLE_CHECKS
import XCTest
@testable import BridgeCore
#endif

final class CloudflareServiceTests: XCTestCase {
    private var temporaryRoot: URL!
    private let tunnelID = "116a0b7e-5aaf-4508-a200-65469a717e1b"

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("WarpGoBridge-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryRoot)
    }

    func testConfigurationRoundTripContainsNoSecretsAndUsesPrivatePermissions() throws {
        let store = ConfigurationStore(root: temporaryRoot)
        var configuration = BridgeConfiguration(domain: "example.com", sessionMode: .manual)
        configuration.tunnelID = tunnelID
        try store.save(configuration)
        XCTAssertEqual(try store.load(), configuration)
        XCTAssertEqual(configuration.endpointURL, "https://warp-go.example.com/v1")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.configurationURL)) as? [String: Any])
        XCTAssertNil(object["goAPIKey"])
        XCTAssertNil(object["relayToken"])
        let mode = try FileManager.default.attributesOfItem(atPath: store.configurationURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testBrowserLoginIsolatedFromRealCloudflaredDirectoryAndDomainLookupFallsBack() async throws {
        let store = ConfigurationStore(root: temporaryRoot)
        let runner = StubProcessRunner { request in
            XCTAssertEqual(request.arguments, ["tunnel", "login"])
            XCTAssertEqual(request.environment?["HOME"], store.helperHome.path)
            try self.writeCertificate(store)
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
        let priorHome = ProcessInfo.processInfo.environment["HOME"]
        let service = CloudflareService(store: store, runner: runner, session: stubSession())
        let result = try await service.login(configuration: BridgeConfiguration(helperPath: "/bin/sh"))
        XCTAssertEqual(result.accountID, "test-account")
        XCTAssertNil(result.domain)
        XCTAssertEqual(ProcessInfo.processInfo.environment["HOME"], priorHome)
        XCTAssertEqual(runner.requests.count, 1)
        _ = try await service.login(configuration: BridgeConfiguration(helperPath: "/bin/sh"))
        XCTAssertEqual(runner.requests.count, 1, "Reconnect must not overwrite an existing certificate")
    }

    func testProvisionRetriesDNSWithoutCreatingAnotherTunnelAndNeverOverwritesDNS() async throws {
        let store = ConfigurationStore(root: temporaryRoot)
        try store.prepareDirectories()
        try writeCertificate(store)
        let retryState = RetryState()
        let runner = StubProcessRunner { request in
            XCTAssertFalse(request.arguments.contains("--overwrite-dns"))
            XCTAssertFalse(request.arguments.contains("-f"))
            if request.arguments.contains("create") {
                try self.writeTunnelCredentials(store)
                return ProcessResult(exitCode: 0, stdout: "{}", stderr: "")
            }
            if request.arguments.contains("route") {
                return ProcessResult(exitCode: retryState.nextCode(), stdout: "", stderr: "")
            }
            XCTFail("Unexpected command")
            return ProcessResult(exitCode: 1, stdout: "", stderr: "")
        }
        let service = CloudflareService(store: store, runner: runner, session: stubSession())
        let configuration = BridgeConfiguration(domain: "example.com", helperPath: "/bin/sh")
        do {
            _ = try await service.provision(configuration: configuration)
            XCTFail("First DNS route should fail")
        } catch {
            XCTAssertTrue(error is CloudflareServiceError)
        }
        XCTAssertEqual(try store.load().tunnelID, tunnelID)
        XCTAssertFalse(try store.load().isProvisioned)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.tunnelConfigURL.path))
        let retried = try await service.provision(configuration: configuration)
        XCTAssertEqual(retried.tunnelID, tunnelID)
        XCTAssertTrue(retried.isProvisioned)
        XCTAssertTrue(try store.load().isProvisioned)
        XCTAssertEqual(runner.requests.filter { $0.arguments.contains("create") }.count, 1)
        XCTAssertEqual(runner.requests.filter { $0.arguments.contains("route") }.count, 2)
        let tunnel = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.tunnelConfigURL)) as? [String: Any])
        let ingress = try XCTUnwrap(tunnel["ingress"] as? [[String: String]])
        XCTAssertEqual(ingress.first?["service"], "http://127.0.0.1:17891")
        XCTAssertEqual(ingress.last?["service"], "http_status:404")
        let serialized = try String(contentsOf: store.tunnelConfigURL, encoding: .utf8)
        XCTAssertFalse(serialized.contains("\\/"), "cloudflared's YAML decoder rejects JSON escaped slashes")
        XCTAssertTrue(serialized.contains("http://127.0.0.1:17891"))
    }

    func testFailedHostnameChangePreservesWorkingConfiguration() async throws {
        let store = ConfigurationStore(root: temporaryRoot)
        try store.prepareDirectories()
        try writeCertificate(store)
        try writeTunnelCredentials(store)
        let working = BridgeConfiguration(domain: "example.com", tunnelID: tunnelID, helperPath: "/bin/sh", isProvisioned: true)
        try store.save(working)
        let originalTunnelData = Data("{\"tunnel\":\"\(tunnelID)\",\"ingress\":[{\"hostname\":\"warp-go.example.com\",\"service\":\"http://127.0.0.1:17891\"},{\"service\":\"http_status:404\"}]}".utf8)
        try store.writePrivate(originalTunnelData, to: store.tunnelConfigURL)
        let originalSettingsData = try Data(contentsOf: store.configurationURL)
        let runner = StubProcessRunner { request in
            XCTAssertTrue(request.arguments.contains("route"))
            XCTAssertTrue(request.arguments.contains("different.example.com"))
            return ProcessResult(exitCode: 1, stdout: "", stderr: "")
        }
        let service = CloudflareService(store: store, runner: runner, session: stubSession())
        var changed = working
        changed.subdomain = "different"
        do {
            _ = try await service.provision(configuration: changed)
            XCTFail("DNS route should fail")
        } catch { XCTAssertTrue(error is CloudflareServiceError) }
        XCTAssertEqual(try Data(contentsOf: store.configurationURL), originalSettingsData)
        XCTAssertEqual(try Data(contentsOf: store.tunnelConfigURL), originalTunnelData)
        XCTAssertTrue(try store.load().isProvisioned)
        XCTAssertEqual(try store.load().hostname, "warp-go.example.com")
    }

    func testGeneratedTunnelConfigurationPassesCloudflaredYAMLValidation() async throws {
        let store = ConfigurationStore(root: temporaryRoot)
        try store.prepareDirectories()
        try writeCertificate(store)
        let runner = StubProcessRunner { request in
            if request.arguments.contains("create") { try self.writeTunnelCredentials(store) }
            return ProcessResult(exitCode: 0, stdout: "{}", stderr: "")
        }
        let service = CloudflareService(store: store, runner: runner, session: stubSession())
        _ = try await service.provision(configuration: BridgeConfiguration(domain: "example.com", helperPath: "/bin/sh"))

        // This validates the actual serialized file with cloudflared's YAML decoder,
        // rather than assuming that every valid JSON escape is also valid YAML.
        // ingress validate is offline: it creates no connection, tunnel, or DNS record.
        let explicitHelper = ProcessInfo.processInfo.environment["WARP_GO_CLOUDFLARED_PATH"].map { URL(fileURLWithPath: $0) }
        let helper = try XCTUnwrap(explicitHelper ?? CloudflareService.findHelper(), "Set WARP_GO_CLOUDFLARED_PATH to the path returned by scripts/fetch-cloudflared.sh before running tests.")
        let validation = try await ProcessRunner().run(executable: helper, arguments: ["tunnel", "--config", store.tunnelConfigURL.path, "ingress", "validate"])
        XCTAssertEqual(validation.exitCode, 0, "cloudflared rejected the generated tunnel configuration")
        XCTAssertTrue(validation.stdout.contains("OK"))
    }

    func testLegacySettingsDoNotAssumeTunnelWasFullyProvisioned() throws {
        let configuration = BridgeConfiguration(domain: "example.com", tunnelID: tunnelID, isProvisioned: true)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        object.removeValue(forKey: "isProvisioned")
        let decoded = try JSONDecoder().decode(BridgeConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(decoded.isProvisioned)
        XCTAssertEqual(decoded.tunnelID, tunnelID)
    }

    func testFailedForceReconnectRestoresPreviousAuthorization() async throws {
        let store = ConfigurationStore(root: temporaryRoot)
        try store.prepareDirectories()
        try writeCertificate(store)
        let original = try Data(contentsOf: store.certificateURL)
        let runner = StubProcessRunner { _ in
            try store.writePrivate(Data("partial failed login".utf8), to: store.certificateURL)
            return ProcessResult(exitCode: 1, stdout: "", stderr: "")
        }
        let service = CloudflareService(store: store, runner: runner, session: stubSession())
        do {
            _ = try await service.login(configuration: BridgeConfiguration(helperPath: "/bin/sh"), force: true)
            XCTFail("Login must fail")
        } catch { XCTAssertTrue(error is CloudflareServiceError) }
        XCTAssertEqual(try Data(contentsOf: store.certificateURL), original)
    }

    func testForceReconnectRejectsAnAccountDifferentFromSavedTunnel() async throws {
        let store = ConfigurationStore(root: temporaryRoot)
        try store.prepareDirectories()
        try writeCertificate(store)
        try writeTunnelCredentials(store)
        let original = try Data(contentsOf: store.certificateURL)
        let runner = StubProcessRunner { _ in
            let json = Data("{\"zoneID\":\"00112233445566778899001122334455\",\"accountID\":\"different-account\",\"apiToken\":\"test-token\"}".utf8)
            let pem = "-----BEGIN ARGO TUNNEL TOKEN-----\n\(json.base64EncodedString())\n-----END ARGO TUNNEL TOKEN-----\n"
            try store.writePrivate(Data(pem.utf8), to: store.certificateURL)
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
        let service = CloudflareService(store: store, runner: runner, session: stubSession())
        do {
            _ = try await service.login(configuration: BridgeConfiguration(tunnelID: tunnelID, helperPath: "/bin/sh"), force: true)
            XCTFail("Changing the tunnel account must fail")
        } catch { XCTAssertTrue(error is CloudflareServiceError) }
        XCTAssertEqual(try Data(contentsOf: store.certificateURL), original)
    }

    func testProcessRunnerDrainsBothPipesAndReturnsExitStatus() async throws {
        let result = try await ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf stdout; printf stderr >&2; exit 7"])
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(result.stdout, "stdout")
        XCTAssertEqual(result.stderr, "stderr")
    }

    func testStartAndStopOwnOnlyTheirChildProcess() async throws {
        let store = ConfigurationStore(root: temporaryRoot)
        try store.prepareDirectories()
        try writeTunnelCredentials(store)
        let runner = StubProcessRunner { _ in ProcessResult(exitCode: 0, stdout: "", stderr: "") }
        let unrelated = try ProcessRunner().start(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"])
        defer { unrelated.stop() }
        let service = CloudflareService(store: store, runner: runner, session: stubSession())
        let configuration = BridgeConfiguration(domain: "example.com", tunnelID: tunnelID, helperPath: "/bin/sh", isProvisioned: true)
        try await service.start(configuration: configuration)
        let running = await service.isRunning
        XCTAssertTrue(running)
        await service.stop()
        let stopped = await service.isRunning
        XCTAssertFalse(stopped)
        XCTAssertTrue(unrelated.isRunning)
    }

    func testInvalidHostnameIsRejectedBeforeAnyProvisioningCommand() async throws {
        let runner = StubProcessRunner { _ in XCTFail("Must not execute a helper"); return ProcessResult(exitCode: 1, stdout: "", stderr: "") }
        let service = CloudflareService(store: ConfigurationStore(root: temporaryRoot), runner: runner, session: stubSession())
        do {
            _ = try await service.provision(configuration: BridgeConfiguration(domain: "example.com\ningress: injected"))
            XCTFail("Invalid hostname should fail")
        } catch { XCTAssertTrue(error is CloudflareServiceError) }
        XCTAssertTrue(runner.requests.isEmpty)
    }

    func testMalformedCertificateAndCredentialsAreRejected() throws {
        XCTAssertThrowsError(try CloudflareOriginCertificate.decode(Data("not a certificate".utf8)))
        let token = try KeychainCredentialStore.generateRelayToken()
        XCTAssertEqual(token.count, 43)
        XCTAssertFalse(token.contains("="))
    }

    private func writeCertificate(_ store: ConfigurationStore) throws {
        let json = Data("{\"zoneID\":\"00112233445566778899001122334455\",\"accountID\":\"test-account\",\"apiToken\":\"test-only-token\"}".utf8)
        let pem = "-----BEGIN ARGO TUNNEL TOKEN-----\n\(json.base64EncodedString())\n-----END ARGO TUNNEL TOKEN-----\n"
        try store.writePrivate(Data(pem.utf8), to: store.certificateURL)
    }

    private func writeTunnelCredentials(_ store: ConfigurationStore) throws {
        let object = ["TunnelID": tunnelID, "AccountTag": "test-account", "TunnelSecret": Data(repeating: 0, count: 32).base64EncodedString()]
        try store.writePrivate(JSONSerialization.data(withJSONObject: object), to: store.tunnelCredentialsURL)
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeniedZoneURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private struct RecordedProcessRequest {
    let arguments: [String]
    let environment: [String: String]?
}

private final class StubProcessRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RecordedProcessRequest] = []
    private let respond: (RecordedProcessRequest) throws -> ProcessResult

    init(respond: @escaping (RecordedProcessRequest) throws -> ProcessResult) { self.respond = respond }

    var requests: [RecordedProcessRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    private func record(_ request: RecordedProcessRequest) {
        lock.lock()
        storage.append(request)
        lock.unlock()
    }

    func run(executable: URL, arguments: [String], environment: [String: String]?, output: (@Sendable (String) -> Void)?) async throws -> ProcessResult {
        let request = RecordedProcessRequest(arguments: arguments, environment: environment)
        record(request)
        return try respond(request)
    }

    func start(executable: URL, arguments: [String], environment: [String: String]?, output: (@Sendable (String) -> Void)?) throws -> ManagedProcess {
        record(RecordedProcessRequest(arguments: arguments, environment: environment))
        return try ProcessRunner().start(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo 'Registered tunnel connection' >&2; exec sleep 60"], environment: environment, output: output)
    }
}

private final class RetryState {
    private var attempts = 0
    func nextCode() -> Int32 { attempts += 1; return attempts == 1 ? 1 : 0 }
}

private final class DeniedZoneURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"success\":false}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
