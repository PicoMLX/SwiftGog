import BashInterpreter

/// The seam by which the **host app** supplies Google OAuth access tokens to
/// `gog`. `SwiftGog` performs no OAuth itself (no browser flow, no token
/// endpoint, no Keychain) — it consumes whatever token the host injects and,
/// on a `401`, asks the host for a refreshed one.
///
/// Trust boundary: a provider is a *trusted* capability bound by the host
/// around a run. It is never exposed to LLM-authored bash, and the token it
/// returns must never be written to the shell environment, the command argv,
/// or the mounted filesystem — only attached as an `Authorization` header by
/// `GogCore`'s HTTP layer.
public protocol GogCredentialProvider: Sendable {
    /// A currently-valid OAuth access token for the active account/tenant.
    func accessToken() async throws -> String

    /// Called after a `401`: return a freshly-refreshed access token (or throw).
    ///
    /// Per the *OAuth token refresh ownership* open question in PLAN.md, the
    /// default assumes the **host** owns refresh; the default implementation
    /// just re-requests `accessToken()`.
    func refreshedAccessToken() async throws -> String

    /// Optional account/tenant label, surfaced by `gog auth status`.
    var accountHint: String? { get }
}

public extension GogCredentialProvider {
    func refreshedAccessToken() async throws -> String { try await accessToken() }
    var accountHint: String? { nil }
}

/// Task-local binding of the active provider. The host binds it around each
/// run, e.g.:
///
/// ```swift
/// try await GogCredentials.$current.withValue(tenant.provider) {
///     try await shell.runCapturing("gog drive ls --json")
/// }
/// ```
///
/// Keeping it out-of-band (rather than in `Shell.environment` or argv) is what
/// stops `printenv` / `echo $TOKEN` from leaking it to model-authored bash.
public enum GogCredentials {
    @TaskLocal public static var current: (any GogCredentialProvider)?
}
