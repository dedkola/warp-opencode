import Foundation

/// A bounded grace period for DNS and Cloudflare edge registration after tunnel startup.
/// Authentication, certificate, and response validation failures are never transient here.
public enum PublicEndpointRetryPolicy {
    public static let maximumDuration: TimeInterval = 30
    public static let maximumAttempts = 16
    public static let requestTimeout: TimeInterval = 8
    public static let retryDelay: TimeInterval = 2

    public static func shouldRetry(statusCode: Int) -> Bool {
        [502, 503, 504, 530].contains(statusCode)
    }

    public static func shouldRetry(error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed, .networkConnectionLost,
             .notConnectedToInternet, .cannotConnectToHost, .timedOut:
            return true
        default:
            return false
        }
    }
}
