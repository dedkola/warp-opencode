import Foundation

public enum SessionMode: String, Codable, CaseIterable, Sendable {
    case automatic, strict, manual
}

/// Non-secret preferences only. Provider and relay credentials belong in Keychain.
public struct BridgeConfiguration: Codable, Equatable, Sendable {
    public var domain: String
    public var subdomain: String
    public var localPort: UInt16
    public var modelIDs: [String]
    public var tunnelID: String?
    public var tunnelName: String
    public var helperPath: String?
    public var sessionMode: SessionMode
    public var manualSessionID: String
    public var isProvisioned: Bool

    public init(domain: String = "", subdomain: String = "warp-go", localPort: UInt16 = 17891, modelIDs: [String] = ["deepseek-v4.1-flash"], tunnelID: String? = nil, tunnelName: String = "warp-go-bridge-" + UUID().uuidString.prefix(8).lowercased(), helperPath: String? = nil, sessionMode: SessionMode = .automatic, manualSessionID: String = UUID().uuidString, isProvisioned: Bool = false) {
        self.domain = domain
        self.subdomain = subdomain
        self.localPort = localPort
        self.modelIDs = modelIDs
        self.tunnelID = tunnelID
        self.tunnelName = tunnelName
        self.helperPath = helperPath
        self.sessionMode = sessionMode
        self.manualSessionID = manualSessionID
        self.isProvisioned = isProvisioned
    }

    private enum CodingKeys: String, CodingKey {
        case domain, subdomain, localPort, modelIDs, tunnelID, tunnelName, helperPath, sessionMode, manualSessionID, isProvisioned
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BridgeConfiguration()
        self.init(
            domain: try values.decodeIfPresent(String.self, forKey: .domain) ?? defaults.domain,
            subdomain: try values.decodeIfPresent(String.self, forKey: .subdomain) ?? defaults.subdomain,
            localPort: try values.decodeIfPresent(UInt16.self, forKey: .localPort) ?? defaults.localPort,
            modelIDs: try values.decodeIfPresent([String].self, forKey: .modelIDs) ?? defaults.modelIDs,
            tunnelID: try values.decodeIfPresent(String.self, forKey: .tunnelID),
            tunnelName: try values.decodeIfPresent(String.self, forKey: .tunnelName) ?? defaults.tunnelName,
            helperPath: try values.decodeIfPresent(String.self, forKey: .helperPath),
            sessionMode: try values.decodeIfPresent(SessionMode.self, forKey: .sessionMode) ?? defaults.sessionMode,
            manualSessionID: try values.decodeIfPresent(String.self, forKey: .manualSessionID) ?? defaults.manualSessionID,
            isProvisioned: try values.decodeIfPresent(Bool.self, forKey: .isProvisioned) ?? false
        )
    }

    public var hostname: String { domain.isEmpty ? "" : "\(subdomain).\(domain)" }
    public var endpointURL: String { hostname.isEmpty ? "" : "https://\(hostname)/v1" }
}

public struct ConfigurationStore: Sendable {
    public let root: URL
    public var helperHome: URL { root.appendingPathComponent("Cloudflare", isDirectory: true) }
    public var certificateURL: URL { helperHome.appendingPathComponent(".cloudflared/cert.pem") }
    public var tunnelCredentialsURL: URL { root.appendingPathComponent("tunnel-credentials.json") }
    public var configurationURL: URL { root.appendingPathComponent("settings.json") }
    public var tunnelConfigURL: URL { root.appendingPathComponent("tunnel.json") }

    public init(root: URL? = nil) {
        // Preserve the original directory so existing tunnel authorization survives renames.
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WarpGoBridge", isDirectory: true)
    }

    public func prepareDirectories() throws {
        for directory in [root, helperHome, certificateURL.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    public func load() throws -> BridgeConfiguration {
        guard FileManager.default.fileExists(atPath: configurationURL.path) else { return BridgeConfiguration() }
        return try JSONDecoder().decode(BridgeConfiguration.self, from: Data(contentsOf: configurationURL))
    }

    public func save(_ configuration: BridgeConfiguration) throws {
        try prepareDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writePrivate(encoder.encode(configuration), to: configurationURL)
    }

    public func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
