import Foundation
#if !PORTABLE_CHECKS
import XCTest
@testable import BridgeCore
#endif

final class PublicEndpointRetryPolicyTests: XCTestCase {
    func testRetriesOnlyCloudflareWarmupStatuses() {
        for status in [502, 503, 504, 530] {
            XCTAssertTrue(PublicEndpointRetryPolicy.shouldRetry(statusCode: status), "HTTP \(status)")
        }
        for status in [200, 301, 400, 401, 403, 404, 408, 429, 500, 501, 520, 521, 522, 525] {
            XCTAssertFalse(PublicEndpointRetryPolicy.shouldRetry(statusCode: status), "HTTP \(status)")
        }
    }

    func testRetriesTemporaryDNSAndConnectionFailures() {
        let transient: [URLError.Code] = [.cannotFindHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .timedOut]
        for code in transient {
            XCTAssertTrue(PublicEndpointRetryPolicy.shouldRetry(error: URLError(code)), "URLError \(code)")
        }
    }

    func testDoesNotRetryCancellationCertificateOrOtherFailures() {
        let terminal: [URLError.Code] = [.cancelled, .badURL, .unsupportedURL, .userAuthenticationRequired, .userCancelledAuthentication, .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .cannotParseResponse, .badServerResponse]
        for code in terminal {
            XCTAssertFalse(PublicEndpointRetryPolicy.shouldRetry(error: URLError(code)), "URLError \(code)")
        }
        XCTAssertFalse(PublicEndpointRetryPolicy.shouldRetry(error: CancellationError()))
        XCTAssertFalse(PublicEndpointRetryPolicy.shouldRetry(error: NSError(domain: "Bridge.ModelValidation", code: 1)))
    }

    func testAttemptBudgetCoversThirtySecondsOfImmediateWarmupFailures() {
        XCTAssertEqual(PublicEndpointRetryPolicy.maximumDuration, 30)
        XCTAssertEqual(PublicEndpointRetryPolicy.requestTimeout, 8)
        XCTAssertEqual(PublicEndpointRetryPolicy.retryDelay, 2)
        XCTAssertTrue(Double(PublicEndpointRetryPolicy.maximumAttempts - 1) * PublicEndpointRetryPolicy.retryDelay >= PublicEndpointRetryPolicy.maximumDuration)
    }
}
