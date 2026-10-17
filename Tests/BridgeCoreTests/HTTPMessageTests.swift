import Foundation
#if !PORTABLE_CHECKS
import XCTest
@testable import BridgeCore
#endif

final class HTTPMessageTests: XCTestCase {
    func testSSEKeepaliveCannotBeInsertedInsideFragmentedEvent() {
        var boundary = SSEBoundaryTracker()
        XCTAssertTrue(boundary.isAtEventBoundary)
        boundary.observe(Data("data: {\"choices\":".utf8))
        XCTAssertFalse(boundary.isAtEventBoundary)
        boundary.observe(Data("[]}\r\n\r".utf8))
        XCTAssertFalse(boundary.isAtEventBoundary)
        boundary.observe(Data("\n".utf8))
        XCTAssertTrue(boundary.isAtEventBoundary)
        boundary.observe(Data("data: next\n".utf8))
        XCTAssertFalse(boundary.isAtEventBoundary)
        boundary.observe(Data("\n".utf8))
        XCTAssertTrue(boundary.isAtEventBoundary)
    }

    func testIncrementalBodyAndCaseInsensitiveHeaders() throws {
        var parser = HTTPRequestParser()
        XCTAssertNil(try parser.append(Data("POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 5\r\nAuthorization: Bearer abc\r\n\r\nhe".utf8)))
        XCTAssertEqual(parser.headers?["authorization"], "Bearer abc")
        let result = try XCTUnwrap(parser.append(Data("llo".utf8)))
        XCTAssertEqual(result.method, "POST")
        XCTAssertEqual(result.body, Data("hello".utf8))
    }

    func testChunkedRequestBody() throws {
        var parser = HTTPRequestParser()
        let result = try XCTUnwrap(parser.append(Data("POST /v1/chat/completions HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhe\r\n3\r\nllo\r\n0\r\n\r\n".utf8)))
        XCTAssertEqual(result.body, Data("hello".utf8))
    }

    func testSmugglingAndAbsoluteTargetsAreRejected() {
        for request in [
            "POST / HTTP/1.1\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n",
            "POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n",
            "GET https://attacker.example/ HTTP/1.1\r\n\r\n",
            "GET //attacker.example/ HTTP/1.1\r\n\r\n",
            "POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n"
        ] {
            var parser = HTTPRequestParser()
            XCTAssertThrowsError(try parser.append(Data(request.utf8)))
        }
    }

    func testOversizeBodyRejectedBeforeAllocation() {
        var parser = HTTPRequestParser()
        XCTAssertThrowsError(try parser.append(Data("POST / HTTP/1.1\r\nContent-Length: 9999999999\r\n\r\n".utf8)))
    }
}
