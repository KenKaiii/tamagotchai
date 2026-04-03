import AppKit

/// Maps raw errors to user-friendly display information for the error block UI.
enum AppError {
    case overloaded
    case authFailed
    case serverIssue(Int)
    case notConnected
    case timeout
    case streamInterrupted(String)
    case loginFailed(String)
    case unknown(String)

    /// The bold title shown at the top of the error block.
    var title: String {
        switch self {
        case .overloaded:
            "Claude is Overloaded"
        case .authFailed:
            "Authentication Failed"
        case .serverIssue:
            "Claude is Having Issues"
        case .notConnected:
            "Not Connected"
        case .timeout:
            "Connection Timed Out"
        case .streamInterrupted:
            "Stream Interrupted"
        case .loginFailed:
            "Login Failed"
        case .unknown:
            "Something Went Wrong"
        }
    }

    /// The descriptive message shown below the title.
    var message: String {
        switch self {
        case .overloaded:
            "Anthropic's servers are under heavy load. Try again in a moment."
        case .authFailed:
            "Your Claude session has expired. Log in again to continue."
        case let .serverIssue(code):
            "Anthropic's servers are experiencing problems (HTTP \(code)). Try again shortly."
        case .notConnected:
            "Log in to Claude from the menu bar to get started."
        case .timeout:
            "Couldn't reach Anthropic's servers. Check your internet and try again."
        case let .streamInterrupted(detail):
            detail.isEmpty
                ? "The response was interrupted. Try sending your message again."
                : detail
        case let .loginFailed(detail):
            detail.isEmpty
                ? "Couldn't connect to Anthropic. Please try again."
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
        case .overloaded, .serverIssue, .streamInterrupted, .unknown:
            .systemRed
        case .authFailed, .notConnected, .loginFailed:
            .systemOrange
        case .timeout:
            .systemGray
        }
    }

    /// Creates an `AppError` from any Swift `Error`.
    static func from(_ error: Error) -> AppError {
        // Handle Claude service errors
        if let serviceError = error as? ClaudeService.ClaudeServiceError {
            switch serviceError {
            case .notLoggedIn:
                return .notConnected
            case let .apiError(statusCode, body):
                switch statusCode {
                case 429:
                    return .overloaded
                case 529 where body.contains("overloaded"):
                    return .overloaded
                case 401, 403:
                    return .authFailed
                case 500, 502, 503:
                    return .serverIssue(statusCode)
                default:
                    return .serverIssue(statusCode)
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
}
