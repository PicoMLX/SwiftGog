import ArgumentParser
import BashInterpreter

/// Fail-closed guards enforcing the sandbox contracts (PLAN.md §"Critical
/// contracts"). Both mirror `CurlCommand`'s behaviour: print a diagnostic to
/// the shell's stderr and exit with status 7 (`throw ExitCode(7)`, which the
/// `AsyncParsableCommandBridge` maps to `ExitStatus(7)`).
public enum GogRuntime {
    /// Contract #2 — HTTPS only through a configured network sandbox.
    /// Fails closed when the host did not attach a `NetworkConfig`.
    public static func requireNetwork() throws {
        if Shell.bashCurrent.networkConfig == nil {
            Shell.bashCurrent.stderr(
                "gog: (7) network access denied: no network configured\n")
            throw ExitCode(7)
        }
    }

    /// Contract #3 — credentials only through the injected provider.
    /// Fails closed when no `GogCredentialProvider` is bound for this run.
    @discardableResult
    public static func requireCredentials() throws -> any GogCredentialProvider {
        guard let provider = GogCredentials.current else {
            Shell.bashCurrent.stderr(
                "gog: (7) no credentials: host did not inject a GogCredentialProvider\n")
            throw ExitCode(7)
        }
        return provider
    }
}
