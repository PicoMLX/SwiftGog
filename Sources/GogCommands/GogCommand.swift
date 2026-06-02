import ArgumentParser
import Foundation
import BashInterpreter
import GogCore

/// Root of the `gog` command tree. One `shell.install(GogCommand.self, …)`
/// registration exposes the whole nested subcommand tree — the same pattern
/// SwiftPorts' `gh` uses (`install(GhCommand.self)`), dispatched by
/// `BashCommandKit`'s `AsyncParsableCommandBridge` via `parseAsRoot`.
public struct GogCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "gog",
        abstract: "Google Workspace CLI (sandboxed, SwiftBash-native).",
        version: GogVersionInfo.version,
        subcommands: [GogVersion.self, GogMe.self, GogAuth.self])

    public init() {}
}

/// `gog version` — prints the version, or (with `--out`) writes it to a path
/// *inside the sandbox*, exercising the file-I/O contract (#1): all writes go
/// through `Shell.bashCurrent.fileSystem`, so a path outside the mounts is
/// rejected by `MountedFileSystem`.
struct GogVersion: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print the gog version.")

    @Option(name: .long,
            help: "Write the version to a sandbox path instead of stdout.")
    var out: String?

    func run() async throws {
        let line = "gog \(GogVersionInfo.version)\n"
        if let out {
            let resolved = Shell.bashCurrent.resolvePath(out)
            try await Shell.bashCurrent.fileSystem.writeData(
                Data(line.utf8), to: resolved, append: false)
        } else {
            Shell.bashCurrent.stdout(line)
        }
    }
}

/// `gog me` / `gog whoami` — the caller's Google profile via the People API.
/// The first command to actually hit Google: it exercises `GoogleHTTPClient`
/// → `SecureFetcher` with the injected bearer token.
struct GogMe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "me",
        abstract: "Show your Google profile.",
        aliases: ["whoami"])

    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        let url = URL(string: "https://people.googleapis.com/v1/people/me"
            + "?personFields=names,emailAddresses")!
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
        } else {
            let me = try JSONDecoder().decode(PeopleMe.self, from: body)
            let name = me.names?.first?.displayName ?? "(unknown)"
            let email = me.emailAddresses?.first?.value ?? ""
            Shell.bashCurrent.stdout(
                "\(name)\(email.isEmpty ? "" : " <\(email)>")\n")
        }
    }
}

private struct PeopleMe: Decodable {
    struct Name: Decodable { let displayName: String? }
    struct Email: Decodable { let value: String? }
    let names: [Name]?
    let emailAddresses: [Email]?
}

/// `gog auth …` — group. Credentials are host-managed (see PLAN.md); the only
/// MVP leaf is `status`.
struct GogAuth: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Auth/config status (credentials are host-managed).",
        subcommands: [GogAuthStatus.self])
}

/// `gog auth status` — reports whether the sandbox can reach Google with an
/// injected credential. Naturally exercises the network (#2) and credential
/// (#3) fail-closed contracts.
struct GogAuthStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show whether network + injected credentials are available.")

    @Flag(name: [.customShort("j"), .long], help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        try GogRuntime.requireNetwork()
        let provider = try GogRuntime.requireCredentials()
        let account = provider.accountHint ?? "unknown"
        if json {
            // Encode rather than interpolate: accountHint is host-supplied and
            // may contain quotes/backslashes that would break manual JSON.
            struct Status: Encodable { let status: String; let account: String }
            let data = try JSONEncoder().encode(
                Status(status: "ready", account: account))
            Shell.bashCurrent.stdout(String(decoding: data, as: UTF8.self) + "\n")
        } else {
            Shell.bashCurrent.stdout("ready: authenticated as \(account)\n")
        }
    }
}
