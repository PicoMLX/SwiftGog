import ArgumentParser
import Foundation
import BashInterpreter

/// Authenticated GETs for Google REST APIs, routed through a `GogTransport`
/// (production: `SecureTransport` over the sandbox's `SecureFetcher`; tests: a
/// fake). The bearer token comes from the injected `GogCredentialProvider`; on
/// a `401` it asks the provider for a refreshed token once — the host owns the
/// refresh (see PLAN.md "Decisions": Option A).
///
// TODO(phase0): factor the exit-code mapping out into the command layer once
// there's more than one consumer; for now it mirrors GogRuntime's pattern.
public struct GoogleHTTPClient {
    private let transport: any GogTransport

    /// `transport` is a test seam; in production it resolves to the task-local
    /// `GogTransportProvider.current` if set, else a fresh `SecureTransport`.
    public init(transport: (any GogTransport)? = nil) {
        self.transport = transport ?? GogTransportProvider.current ?? SecureTransport()
    }

    /// Authenticated `GET`; returns the response body, or throws an `ExitCode`
    /// (7 = no creds / no network / re-auth required; 1 = other HTTP ≥ 400)
    /// after writing a diagnostic to stderr.
    public func get(_ url: URL) async throws -> Data {
        let provider = try GogRuntime.requireCredentials()
        do {
            let token = try await provider.accessToken()
            var response = try await transport.send(
                method: "GET", url: url, headers: Self.authHeaders(token), body: nil)
            if response.status == 401 {
                let refreshed = try await provider.refreshedAccessToken()
                response = try await transport.send(
                    method: "GET", url: url,
                    headers: Self.authHeaders(refreshed), body: nil)
            }
            if response.status == 401 {
                Shell.bashCurrent.stderr(
                    "gog: (7) re-auth required: token rejected by Google\n")
                throw ExitCode(7)
            }
            guard response.status < 400 else {
                Shell.bashCurrent.stderr("gog: HTTP \(response.status)\n")
                throw ExitCode(1)
            }
            return response.body
        } catch let err as NetworkError {
            Shell.bashCurrent.stderr("gog: (\(err.exitCode)) \(err.description)\n")
            throw ExitCode(Int32(err.exitCode))
        }
    }

    private static func authHeaders(_ token: String) -> [String: String] {
        ["Authorization": "Bearer \(token)", "Accept": "application/json"]
    }
}
