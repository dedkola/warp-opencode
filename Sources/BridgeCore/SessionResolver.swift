import CryptoKit
import Foundation

/// Only fingerprints are retained. Request text never leaves memory or enters diagnostics.
public final class SessionResolver: @unchecked Sendable {
    public enum Source: String, Sendable { case metadata, history, newConversation, manual }
    public struct Resolution: Sendable {
        public let id: String
        public let source: Source
    }
    public enum Failure: Error, LocalizedError {
        case missingIdentity, ambiguousHistory, unrecognizedContinuation, capacity
        public var errorDescription: String? {
            switch self {
            case .missingIdentity:
                return "No conversation ID was supplied. Use Automatic matching, or Manual mode for one chat."
            case .ambiguousHistory:
                return "Conversation history is ambiguous. Start a distinct Warp chat, or use Manual mode for one chat."
            case .unrecognizedContinuation:
                return "This conversation is not recognized. History may have been compacted or the bridge restarted. Start a new Warp chat, or use Manual mode for one chat."
            case .capacity:
                return "The conversation limit was reached. Stop active requests, reset sessions, and start new Warp chats."
            }
        }
    }

    private struct Fingerprint: Hashable { let count: Int; let hash: String }
    private let lock = NSLock()
    private let mode: SessionMode
    private var manualID: String
    private var histories: [String: [Fingerprint]] = [:]
    private let maximumSessions = 512

    public init(mode: SessionMode, manualSessionID: String = UUID().uuidString) {
        self.mode = mode
        manualID = manualSessionID
    }

    public func reset(manualSessionID: String) {
        lock.lock(); defer { lock.unlock() }
        histories.removeAll()
        manualID = manualSessionID
    }

    public func resolve(headers: [String: String], body: [String: Any]) throws -> Resolution {
        lock.lock(); defer { lock.unlock() }
        if let identity = Self.explicitIdentity(headers: headers, body: body) {
            return Resolution(id: "warp_" + Self.digest(Data(identity.utf8)), source: .metadata)
        }
        if mode == .manual {
            return Resolution(id: "warp_" + Self.digest(Data(manualID.utf8)), source: .manual)
        }
        guard mode == .automatic else { throw Failure.missingIdentity }
        guard let allMessages = body["messages"] as? [[String: Any]] else { throw Failure.missingIdentity }
        // System context can change between turns. Match the actual user/assistant/tool transcript.
        let messages = allMessages.filter { ["user", "assistant", "tool", "function"].contains($0["role"] as? String ?? "") }
        guard !messages.isEmpty else { throw Failure.missingIdentity }
        let fingerprint = try Self.fingerprint(messages)
        var matches = Set<String>()
        let counts = Set(histories.values.flatMap { $0.map(\.count) }).filter { $0 <= messages.count }
        let prefixes = try Self.prefixFingerprints(messages, counts: Set(counts))
        for (id, fingerprints) in histories {
            if fingerprints.contains(where: { prefixes[$0.count] == $0 }) { matches.insert(id) }
        }
        guard matches.count <= 1 else { throw Failure.ambiguousHistory }
        if let id = matches.first {
            // With no native ID, an identical request could be either a retry or an independent
            // chat with the same opening. Never silently combine those conversations.
            if histories[id]?.contains(fingerprint) == true { throw Failure.ambiguousHistory }
            histories[id, default: []].append(fingerprint)
            // Keep the initial identity and a bounded window of recent request fingerprints.
            if histories[id]!.count > 33 { histories[id]!.remove(at: 1) }
            return Resolution(id: id, source: .history)
        }
        // Warp sends its opening context and prompt as several user-role messages.
        // Anchor the entire opening, so shared context alone never identifies a chat.
        // An unknown transcript containing model/tool history is still a continuation.
        guard messages.allSatisfy({ $0["role"] as? String == "user" }) else {
            throw Failure.unrecognizedContinuation
        }
        guard histories.count < maximumSessions else { throw Failure.capacity }
        let id = "warp_" + UUID().uuidString.lowercased()
        histories[id] = [fingerprint]
        return Resolution(id: id, source: .newConversation)
    }

    private static func fingerprint(_ messages: [[String: Any]]) throws -> Fingerprint {
        return try prefixFingerprints(messages, counts: [messages.count])[messages.count]!
    }

    private static func prefixFingerprints(_ messages: [[String: Any]], counts: Set<Int>) throws -> [Int: Fingerprint] {
        guard !counts.isEmpty else { return [:] }
        var hasher = SHA256()
        hasher.update(data: Data("[".utf8))
        var results: [Int: Fingerprint] = [:]
        for (offset, message) in messages.enumerated() {
            if offset > 0 { hasher.update(data: Data(",".utf8)) }
            hasher.update(data: try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]))
            if counts.contains(offset + 1) {
                var completed = hasher
                completed.update(data: Data("]".utf8))
                results[offset + 1] = Fingerprint(count: offset + 1, hash: completed.finalize().map { String(format: "%02x", $0) }.joined())
            }
        }
        return results
    }

    private static func explicitIdentity(headers: [String: String], body: [String: Any]) -> String? {
        let normalized = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        for key in ["x-opencode-session", "x-warp-conversation-id", "x-conversation-id", "x-session-id"] {
            if let value = valid(normalized[key]) { return "header:\(key):\(value)" }
        }
        for key in ["conversation_id", "session_id"] {
            if let value = valid(body[key] as? String) { return "body:\(key):\(value)" }
        }
        if let metadata = body["metadata"] as? [String: Any] {
            for key in ["conversation_id", "session_id"] {
                if let value = valid(metadata[key] as? String) { return "metadata:\(key):\(value)" }
            }
        }
        return nil
    }

    private static func valid(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
