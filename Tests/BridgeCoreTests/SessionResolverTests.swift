import Foundation
#if !PORTABLE_CHECKS
import XCTest
@testable import BridgeCore
#endif

final class SessionResolverTests: XCTestCase {
    private func message(_ role: String, _ content: String) -> [String: Any] { ["role": role, "content": content] }

    func testNativeIdentityIsStableAcrossTurnsAndRestarts() throws {
        let headers = ["X-Warp-Conversation-ID": "chat-a"]
        let first = try SessionResolver(mode: .strict).resolve(headers: headers, body: [:])
        let second = try SessionResolver(mode: .strict).resolve(headers: headers, body: ["messages": [message("user", "follow up")]])
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.source, .metadata)
        let other = try SessionResolver(mode: .strict).resolve(headers: ["x-warp-conversation-id": "chat-b"], body: [:])
        XCTAssertNotEqual(first.id, other.id)
    }

    func testHistoryMatchesGrowingToolConversationAndIgnoresSystemUpdates() throws {
        let resolver = SessionResolver(mode: .automatic)
        let original = message("user", "Inspect project A")
        let first = try resolver.resolve(headers: [:], body: ["messages": [message("system", "old context"), original]])
        let second = try resolver.resolve(headers: [:], body: ["messages": [message("system", "new context"), original, message("assistant", "Inspecting"), message("tool", "files")]])
        let third = try resolver.resolve(headers: [:], body: ["messages": [original, message("assistant", "Inspecting"), message("tool", "files"), message("assistant", "Done"), message("user", "Now fix it")]])
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(second.id, third.id)
        XCTAssertEqual(second.source, .history)
    }

    func testIndependentOpeningsRemainSeparate() throws {
        let resolver = SessionResolver(mode: .automatic)
        let first = try resolver.resolve(headers: [:], body: ["messages": [message("user", "Project A")]])
        let second = try resolver.resolve(headers: [:], body: ["messages": [message("user", "Project B")]])
        XCTAssertNotEqual(first.id, second.id)
    }

    func testWarpThreeUserOpeningMatchesFollowupAndSeparatesChatsWithSharedContext() throws {
        let resolver = SessionResolver(mode: .automatic)
        let context = [message("user", "Shared environment"), message("user", "Shared project instructions")]
        let firstOpening = context + [message("user", "Inspect project A")]
        let otherOpening = context + [message("user", "Inspect project B")]
        let first = try resolver.resolve(headers: [:], body: ["messages": [message("system", "System context")] + firstOpening])
        let other = try resolver.resolve(headers: [:], body: ["messages": otherOpening])
        let continued = try resolver.resolve(headers: [:], body: ["messages": firstOpening + [message("assistant", "Inspecting"), message("tool", "Files"), message("assistant", "Done"), message("user", "Continue")]])
        XCTAssertEqual(first.source, .newConversation)
        XCTAssertEqual(continued.source, .history)
        XCTAssertEqual(first.id, continued.id)
        XCTAssertNotEqual(first.id, other.id)
    }

    func testIdenticalMultiUserOpeningRemainsAmbiguous() throws {
        let resolver = SessionResolver(mode: .automatic)
        let body: [String: Any] = ["messages": [message("user", "Environment"), message("user", "Instructions"), message("user", "Same opening")]]
        _ = try resolver.resolve(headers: [:], body: body)
        XCTAssertThrowsError(try resolver.resolve(headers: [:], body: body))
    }

    func testUnknownModelAndToolHistoriesCannotBootstrap() {
        for role in ["assistant", "tool", "function"] {
            let resolver = SessionResolver(mode: .automatic)
            let messages = [message("user", "Environment"), message("user", "Earlier prompt"), message(role, "Earlier result"), message("user", "Continue")]
            XCTAssertThrowsError(try resolver.resolve(headers: [:], body: ["messages": messages]))
        }
    }

    func testIdenticalOpeningFailsRatherThanCombiningChats() throws {
        let resolver = SessionResolver(mode: .automatic)
        let body: [String: Any] = ["messages": [message("user", "Same opening")]]
        _ = try resolver.resolve(headers: [:], body: body)
        XCTAssertThrowsError(try resolver.resolve(headers: [:], body: body)) { error in
            XCTAssertTrue(error is SessionResolver.Failure)
        }
    }

    func testUnknownContinuationFailsAfterRestartOrCompaction() {
        let resolver = SessionResolver(mode: .automatic)
        XCTAssertThrowsError(try resolver.resolve(headers: [:], body: ["messages": [message("user", "Earlier"), message("assistant", "Answer"), message("user", "Continue")]]))
    }

    func testStrictModeDoesNotUseAccountUserAsConversationID() {
        XCTAssertThrowsError(try SessionResolver(mode: .strict).resolve(headers: [:], body: ["user": "account-123"]))
        XCTAssertThrowsError(try SessionResolver(mode: .strict).resolve(headers: [:], body: ["prompt_cache_key": "shared-cache-bucket"]))
    }

    func testManualIDPersistsAndCanBeRotated() throws {
        let resolver = SessionResolver(mode: .manual, manualSessionID: "saved-session")
        let first = try resolver.resolve(headers: [:], body: [:])
        let restarted = try SessionResolver(mode: .manual, manualSessionID: "saved-session").resolve(headers: [:], body: [:])
        XCTAssertEqual(first.id, restarted.id)
        resolver.reset(manualSessionID: "new-session")
        XCTAssertNotEqual(first.id, try resolver.resolve(headers: [:], body: [:]).id)
    }

    func testExplicitIdentityWinsOverManualFallback() throws {
        let result = try SessionResolver(mode: .manual).resolve(headers: [:], body: ["metadata": ["session_id": "native"]])
        XCTAssertEqual(result.source, .metadata)
    }
}
