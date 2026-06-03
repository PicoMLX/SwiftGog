import ArgumentParser
import Foundation
import BashInterpreter

/// Authenticated requests to Google REST APIs, routed through a `GogTransport`
/// (production: `SecureTransport` over the sandbox's `SecureFetcher`; tests: a
/// fake). The bearer token comes from the injected `GogCredentialProvider`; on
/// a `401` it asks the provider for a refreshed token once — the host owns the
/// refresh (see PLAN.md "Decisions": Option A).
public struct GoogleHTTPClient {
    private let transport: any GogTransport

    /// `transport` is a test seam; in production it resolves to the task-local
    /// `GogTransportProvider.current` if set, else a fresh `SecureTransport`.
    public init(transport: (any GogTransport)? = nil) {
        self.transport = transport ?? GogTransportProvider.current ?? SecureTransport()
    }

    /// Authenticated `GET`.
    public func get(_ url: URL) async throws -> Data {
        try await perform(method: "GET", url: url, body: nil, contentType: nil)
    }

    /// Authenticated `POST` with a JSON body.
    public func post(_ url: URL, jsonBody: Data) async throws -> Data {
        try await post(url, body: jsonBody, contentType: "application/json")
    }

    /// Authenticated `POST` with an explicit content type (e.g. multipart).
    public func post(_ url: URL, body: Data, contentType: String) async throws -> Data {
        try await perform(method: "POST", url: url, body: body, contentType: contentType)
    }

    /// Authenticated `PUT` with a JSON body.
    public func put(_ url: URL, jsonBody: Data) async throws -> Data {
        try await perform(method: "PUT", url: url, body: jsonBody,
                          contentType: "application/json")
    }

    /// Authenticated `PATCH` with a JSON body (partial update).
    public func patch(_ url: URL, jsonBody: Data) async throws -> Data {
        try await perform(method: "PATCH", url: url, body: jsonBody,
                          contentType: "application/json")
    }

    /// Authenticated `DELETE`. Returns the (often empty) response body.
    public func delete(_ url: URL) async throws -> Data {
        try await perform(method: "DELETE", url: url, body: nil, contentType: nil)
    }

    /// Shared flow: bearer token, one `401` → refresh retry, then status
    /// mapping. Returns the body, or throws an `ExitCode` (7 = no creds /
    /// re-auth required; 1 = other HTTP ≥ 400) after writing a diagnostic to
    /// stderr.
    private func perform(method: String, url: URL,
                         body: Data?, contentType: String?) async throws -> Data {
        let provider = try GogRuntime.requireCredentials()
        func headers(_ token: String) -> [String: String] {
            var headers = ["Authorization": "Bearer \(token)",
                           "Accept": "application/json"]
            if let contentType { headers["Content-Type"] = contentType }
            return headers
        }
        do {
            let token: String
            do {
                token = try await provider.accessToken()
            } catch {
                Shell.bashCurrent.stderr(
                    "gog: (7) re-auth required: could not obtain an access token\n")
                throw ExitCode(7)
            }
            var response = try await transport.send(
                method: method, url: url, headers: headers(token), body: body)
            if response.status == 401 {
                let refreshed: String
                do {
                    refreshed = try await provider.refreshedAccessToken()
                } catch {
                    Shell.bashCurrent.stderr(
                        "gog: (7) re-auth required: token refresh failed\n")
                    throw ExitCode(7)
                }
                response = try await transport.send(
                    method: method, url: url, headers: headers(refreshed), body: body)
            }
            if response.status == 401 {
                Shell.bashCurrent.stderr(
                    "gog: (7) re-auth required: token rejected by Google\n")
                throw ExitCode(7)
            }
            guard response.status < 400 else {
                let detail = Self.googleErrorMessage(response.body)
                Shell.bashCurrent.stderr(
                    "gog: HTTP \(response.status)" + (detail.map { ": \($0)" } ?? "") + "\n")
                throw ExitCode(1)
            }
            return response.body
        } catch let err as NetworkError {
            Shell.bashCurrent.stderr("gog: (\(err.exitCode)) \(err.description)\n")
            throw ExitCode(Int32(err.exitCode))
        }
    }

    /// Pull `error.message` out of a Google JSON error body, if present, for a
    /// more useful diagnostic than a bare status code.
    private static func googleErrorMessage(_ body: Data) -> String? {
        struct Envelope: Decodable {
            struct APIError: Decodable { let message: String? }
            let error: APIError?
        }
        return (try? JSONDecoder().decode(Envelope.self, from: body))?.error?.message
    }
}
