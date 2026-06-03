import Foundation

/// Renders a Google REST API error into an LLM-actionable diagnostic — the
/// SwiftGog analogue of gogcli's `errfmt`. For common, *fixable* failures it
/// appends a hint (which API to enable + the console URL, an insufficient-scope
/// note, or a rate-limit backoff cue) instead of surfacing a bare status line.
///
/// Adapted to SwiftGog's host-managed auth: where gogcli tells the user to run
/// `gog auth add …`, we point at the host, because `gog` performs no OAuth and
/// cannot enable APIs or grant scopes itself.
enum GoogleAPIError {
    /// `{ "error": { code, message, status, errors: [{ reason, message }] } }`.
    private struct Envelope: Decodable {
        struct Inner: Decodable {
            struct Item: Decodable { let reason: String?; let message: String? }
            let code: Int?
            let message: String?
            let status: String?
            let errors: [Item]?
        }
        let error: Inner?
    }

    /// Known Google API hosts → display names, for the "enable it" hint.
    private static let displayNames: [String: String] = [
        "admin.googleapis.com": "Admin SDK API",
        "calendar-json.googleapis.com": "Calendar API",
        "chat.googleapis.com": "Google Chat API",
        "cloudidentity.googleapis.com": "Cloud Identity API",
        "docs.googleapis.com": "Docs API",
        "drive.googleapis.com": "Drive API",
        "forms.googleapis.com": "Forms API",
        "gmail.googleapis.com": "Gmail API",
        "people.googleapis.com": "People API",
        "sheets.googleapis.com": "Sheets API",
        "slides.googleapis.com": "Slides API",
        "tasks.googleapis.com": "Tasks API",
        "youtube.googleapis.com": "YouTube Data API",
    ]

    /// Build the diagnostic for an HTTP error response. The caller prefixes
    /// `gog: ` and appends the trailing newline.
    static func diagnostic(status: Int, body: Data) -> String {
        let inner = (try? JSONDecoder().decode(Envelope.self, from: body))?.error
        let message = inner?.message ?? ""
        let reason = inner?.errors?.first?.reason ?? inner?.status ?? ""
        var haystack = message.lowercased()
        let extra = (inner?.errors ?? []).compactMap { $0.message?.lowercased() }
        if !extra.isEmpty { haystack += " " + extra.joined(separator: " ") }

        // 1) API not enabled (403 + accessNotConfigured / "has not been used").
        if status == 403, isDisabled(reason: reason, haystack: haystack),
           let api = apiHost(in: haystack) {
            let name = displayNames[api] ?? api
            let url = "https://console.developers.google.com/apis/api/\(api)/overview"
            return "\(name) is not enabled for this OAuth project.\n"
                + "Enable it at: \(url)\n"
                + "Then retry. (gog uses the host-injected token; enabling the API "
                + "is a host / Cloud-console action.)"
        }

        // 2) Insufficient scope — the token can't do this operation.
        if status == 403, isInsufficientScope(reason: reason, haystack: haystack) {
            return base(status: status, reason: reason, message: message) + "\n"
                + "The access token lacks the scope required for this operation. "
                + "gog performs no OAuth, so the host must grant the scope and "
                + "re-issue the token."
        }

        // 3) Rate limited — back off and retry.
        if status == 429 || isRateLimit(reason) {
            return base(status: status, reason: reason, message: message) + "\n"
                + "Rate limited by Google; retry after a short backoff."
        }

        return base(status: status, reason: reason, message: message)
    }

    private static func base(status: Int, reason: String, message: String) -> String {
        let msg = message.isEmpty ? "request failed" : message
        return reason.isEmpty
            ? "Google API error (\(status)): \(msg)"
            : "Google API error (\(status) \(reason)): \(msg)"
    }

    private static func isDisabled(reason: String, haystack: String) -> Bool {
        reason.lowercased() == "accessnotconfigured"
            || haystack.contains("has not been used")
            || haystack.contains("it is disabled")
    }

    private static func isInsufficientScope(reason: String, haystack: String) -> Bool {
        reason.lowercased().contains("insufficient")
            || haystack.contains("insufficient authentication scopes")
            || haystack.contains("insufficient permission")
    }

    private static func isRateLimit(_ reason: String) -> Bool {
        let r = reason.lowercased()
        return r.contains("ratelimit") || r == "quotaexceeded"
    }

    /// Find a `*.googleapis.com` host mentioned in the error text.
    private static func apiHost(in haystack: String) -> String? {
        for token in haystack.split(whereSeparator: {
            !($0.isLetter || $0.isNumber || $0 == "." || $0 == "-")
        }) {
            // Strip trailing sentence punctuation the split keeps (e.g. "…com.").
            var trimmed = token
            while trimmed.hasSuffix(".") || trimmed.hasSuffix("-") {
                trimmed = trimmed.dropLast()
            }
            // ".googleapis.com" is 15 chars; require a non-empty subdomain.
            if trimmed.hasSuffix(".googleapis.com"), trimmed.count > 15 {
                return String(trimmed)
            }
        }
        return nil
    }
}
