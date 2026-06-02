import ArgumentParser
import Foundation
import BashInterpreter

/// Minimal authenticated GET client for Google REST APIs, routed entirely
/// through the SwiftBash sandbox: HTTPS via `SecureFetcher` (allow-list
/// enforced) and the bearer token from the injected `GogCredentialProvider`.
/// On a `401` it asks the provider for a refreshed token once — the host owns
/// the refresh (see the "OAuth token refresh ownership" open question in
/// PLAN.md).
///
/// `fetcher` is a test seam mirroring `CurlCommand.run(argv:fetcher:)`; in
/// production it is `nil` and a `SecureFetcher` is built from the shell's
/// `networkConfig` (fail-closed if absent).
///
// TODO(phase0): factor the exit-code mapping out into the command layer once
// there's more than one consumer; for now it mirrors GogRuntime's pattern.
public struct GoogleHTTPClient {
    private let injected: SecureFetcher?

    public init(fetcher: SecureFetcher? = nil) { self.injected = fetcher }

    /// Authenticated `GET`; returns the response body or throws an
    /// `ExitCode` (7 = no network / no creds / re-auth required) after
    /// writing a diagnostic to stderr.
    public func get(_ url: URL) async throws -> Data {
        let provider = try GogRuntime.requireCredentials()
        let fetcher = try resolveFetcher()
        do {
            let token = try await provider.accessToken()
            var response = try await fetcher.fetch(authorizedGET(url, token: token))
            if response.status == 401 {
                let refreshed = try await provider.refreshedAccessToken()
                response = try await fetcher.fetch(authorizedGET(url, token: refreshed))
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

    private func authorizedGET(_ url: URL, token: String) -> NetworkRequest {
        NetworkRequest(
            url: url,
            method: "GET",
            headers: ["Authorization": "Bearer \(token)",
                      "Accept": "application/json"],
            body: nil)
    }

    private func resolveFetcher() throws -> SecureFetcher {
        if let injected { return injected }
        guard let config = Shell.bashCurrent.networkConfig else {
            Shell.bashCurrent.stderr(
                "gog: (7) network access denied: no network configured\n")
            throw ExitCode(7)
        }
        do {
            return try SecureFetcher(config: config)
        } catch let err as NetworkError {
            Shell.bashCurrent.stderr("gog: (\(err.exitCode)) \(err.description)\n")
            throw ExitCode(Int32(err.exitCode))
        }
    }
}
