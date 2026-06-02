import ArgumentParser
import Foundation
import BashInterpreter

/// The minimal HTTP response `GoogleHTTPClient` works in terms of. Owning this
/// (rather than exposing ShellKit's `NetworkResponse`) lets tests fake the
/// network without depending on ShellKit's response initializer, which isn't
/// available to downstream packages.
public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// The transport seam. Production goes through `SecureTransport`; tests bind a
/// fake via `GogTransportProvider.current`.
public protocol GogTransport: Sendable {
    func send(method: String, url: URL,
              headers: [String: String], body: Data?) async throws -> HTTPResponse
}

/// Production transport: every request goes through the sandbox's
/// `SecureFetcher`, so the URL allow-list is enforced. Fails closed (exit 7)
/// when the host attached no `networkConfig`.
public struct SecureTransport: GogTransport {
    public init() {}

    public func send(method: String, url: URL,
                     headers: [String: String], body: Data?) async throws -> HTTPResponse {
        guard let config = Shell.bashCurrent.networkConfig else {
            Shell.bashCurrent.stderr(
                "gog: (7) network access denied: no network configured\n")
            throw ExitCode(7)
        }
        let fetcher = try SecureFetcher(config: config)
        let response = try await fetcher.fetch(NetworkRequest(
            url: url, method: method, headers: headers, body: body))
        return HTTPResponse(status: response.status, body: response.body)
    }
}

/// Test seam: bind a fake transport around a run to exercise command happy
/// paths without real network.
public enum GogTransportProvider {
    @TaskLocal public static var current: (any GogTransport)?
}
