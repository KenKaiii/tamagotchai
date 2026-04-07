import AppKit

/// Maps raw errors to user-friendly display information for the error block UI.
enum AppError {
    case overloaded
    case authFailed
    case subscriptionRequired(String)
    case notConnected
    case timeout
    case streamInterrupted(String)
    case unknown(String)

    /// The bold title shown at the top of the error block.
    var title: String {
        switch self {
        case .overloaded:
            "Server Overloaded"
        case .authFailed:
            "Authentication Failed"
        case .subscriptionRequired:
            "Subscription Required"
        case .notConnected:
            "Not Connected"
        case .timeout:
            "Connection Timed Out"
        case .streamInterrupted:
            "Stream Interrupted"
        case .unknown:
            "Something Went Wrong"
        }
    }

    /// The descriptive message shown below the title.
    var message: String {
        switch self {
        case .overloaded:
            "The API server is under heavy load. Try again in a moment."
        case .authFailed:
            "Your session has expired. Check your API key in AI Settings."
        case let .subscriptionRequired(detail):
            detail
        case .notConnected:
            "Add an API key in AI Settings to get started."
        case .timeout:
            "Couldn't reach the API server. Check your internet and try again."
        case let .streamInterrupted(detail):
            detail.isEmpty
                ? "The response was interrupted. Try sending your message again."
                : detail
        case let .unknown(detail):
            detail.isEmpty
                ? "An unexpected error occurred. Please try again."
                : detail
        }
    }

    /// The tint color for the error block background and border.
    var tint: NSColor {
        switch self {
        case .overloaded, .streamInterrupted, .unknown, .notConnected:
            .systemRed
        case .authFailed, .subscriptionRequired:
            .systemOrange
        case .timeout:
            .systemGray
        }
    }

    /// Creates an `AppError` from any Swift `Error`.
    static func from(_ error: Error) -> AppError {
        // Handle provider store errors
        if error is ProviderStore.ProviderStoreError {
            return .notConnected
        }

        // Handle Claude service errors
        if let serviceError = error as? ClaudeService.ClaudeServiceError {
            switch serviceError {
            case .notLoggedIn:
                return .notConnected
            case let .apiError(statusCode, body):
                let lowerBody = body.lowercased()

                // Detect subscription/billing errors from any provider
                if Self.isBillingError(statusCode: statusCode, body: lowerBody) {
                    return .subscriptionRequired(
                        "This model requires a paid plan. "
                            + "Check your subscription at your provider's settings, "
                            + "or switch to a different model in AI Settings."
                    )
                }

                switch statusCode {
                case 429:
                    return .overloaded
                case 529 where lowerBody.contains("overloaded"):
                    return .overloaded
                case 401, 403:
                    return .authFailed
                default:
                    // Include the body for non-Anthropic providers so the
                    // actual error message is visible to the user.
                    let shortBody = body.count > 200 ? String(body.prefix(200)) + "…" : body
                    return .unknown("HTTP \(statusCode): \(shortBody)")
                }
            case let .streamError(msg):
                return .streamInterrupted(msg)
            }
        }

        // Handle URL/network errors
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut:
                return .timeout
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorDNSLookupFailed:
                return .timeout
            default:
                return .unknown(error.localizedDescription)
            }
        }

        return .unknown(error.localizedDescription)
    }

    /// Detects subscription, billing, or quota errors that indicate a paid plan is needed.
    private static func isBillingError(statusCode: Int, body: String) -> Bool {
        // HTTP 402 Payment Required is an explicit billing error
        if statusCode == 402 { return true }

        let billingKeywords = [
            "insufficient balance",
            "no resource package",
            "quota exceeded",
            "billing",
            "recharge",
            "subscription plan",
            "does not yet include access",
            "not supported",
            "plan does not",
            "upgrade your plan",
            "rate limit",
        ]

        // Only match on 400/403/429 to avoid false positives on unrelated errors
        guard [400, 403, 429].contains(statusCode) else { return false }
        return billingKeywords.contains { body.contains($0) }
    }
}
