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
        subcommands: [GogVersion.self, GogMe.self, GogDrive.self, GogAuth.self])

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

/// `gog drive …` — Google Drive group.
struct GogDrive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drive",
        abstract: "Google Drive.",
        subcommands: [DriveLs.self, DriveGet.self, DriveSearch.self, DriveDownload.self],
        aliases: ["drv"])
}

/// `gog drive ls` — list Drive files (Drive v3 `files.list`). Mirrors gogcli's
/// `internal/cmd/drive_listing.go`: validate → query → emit JSON (`--json`,
/// byte-for-byte from Google) or a TSV of `id<TAB>name<TAB>mimeType`.
struct DriveLs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List Drive files.",
        aliases: ["list"])

    @Option(name: .long, help: "Only list children of this folder ID.")
    var parent: String?
    @Option(name: .long, help: "Maximum number of files to return (1–1000).")
    var max: Int = 100
    @Option(name: .long, help: "Page token from a previous listing.")
    var page: String?
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        guard max > 0, max <= 1000 else {
            Shell.bashCurrent.stderr("gog: --max must be between 1 and 1000\n")
            throw ExitCode(2)
        }

        var comps = URLComponents(
            string: "https://www.googleapis.com/drive/v3/files")!
        var query = [
            URLQueryItem(name: "pageSize", value: String(max)),
            URLQueryItem(name: "fields",
                value: "nextPageToken,files(id,name,mimeType,modifiedTime,size)"),
        ]
        if let parent {
            query.append(URLQueryItem(
                name: "q", value: "'\(parent)' in parents and trashed = false"))
        }
        if let page {
            query.append(URLQueryItem(name: "pageToken", value: page))
        }
        comps.queryItems = query

        let body = try await GoogleHTTPClient().get(comps.url!)
        try emitDriveFileList(body, json: json)
    }
}

private struct DriveFileList: Decodable {
    struct File: Decodable {
        let id: String?
        let name: String?
        let mimeType: String?
    }
    let files: [File]?
    let nextPageToken: String?
}

/// Render a Drive v3 file-list response: raw JSON (`--json`) or a TSV of
/// `id<TAB>name<TAB>mimeType`, with "No files" / next-page-token to stderr.
private func emitDriveFileList(_ body: Data, json: Bool) throws {
    if json {
        Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
        return
    }
    let listing = try JSONDecoder().decode(DriveFileList.self, from: body)
    let files = listing.files ?? []
    if files.isEmpty { Shell.bashCurrent.stderr("No files\n") }
    for file in files {
        Shell.bashCurrent.stdout(
            "\(file.id ?? "")\t\(file.name ?? "")\t\(file.mimeType ?? "")\n")
    }
    if let next = listing.nextPageToken {
        Shell.bashCurrent.stderr("next page token: \(next)\n")
    }
}

/// `gog drive get <id>` — fetch one file's metadata.
struct DriveGet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Show a Drive file's metadata.")

    @Argument(help: "Drive file ID.") var id: String
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        var comps = URLComponents(
            string: "https://www.googleapis.com/drive/v3/files/\(id)")!
        comps.queryItems = [URLQueryItem(
            name: "fields", value: "id,name,mimeType,modifiedTime,size,parents")]
        let body = try await GoogleHTTPClient().get(comps.url!)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            return
        }
        let file = try JSONDecoder().decode(DriveFileList.File.self, from: body)
        Shell.bashCurrent.stdout(
            "\(file.id ?? "")\t\(file.name ?? "")\t\(file.mimeType ?? "")\n")
    }
}

/// `gog drive search <text>` — search files by name or full text.
struct DriveSearch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search Drive files by name or content.",
        aliases: ["find"])

    @Argument(help: "Search text.") var query: String
    @Option(name: .long, help: "Maximum number of files to return (1–1000).")
    var max: Int = 100
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        guard max > 0, max <= 1000 else {
            Shell.bashCurrent.stderr("gog: --max must be between 1 and 1000\n")
            throw ExitCode(2)
        }
        // Escape the Drive query string literal (backslash, then quote).
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        var comps = URLComponents(
            string: "https://www.googleapis.com/drive/v3/files")!
        comps.queryItems = [
            URLQueryItem(name: "q",
                value: "(name contains '\(escaped)' or fullText contains '\(escaped)')"
                    + " and trashed = false"),
            URLQueryItem(name: "pageSize", value: String(max)),
            URLQueryItem(name: "fields", value: "files(id,name,mimeType)"),
        ]
        let body = try await GoogleHTTPClient().get(comps.url!)
        try emitDriveFileList(body, json: json)
    }
}

/// `gog drive download <id> --out <path>` — write a file's contents into the
/// sandbox via `Shell.bashCurrent.fileSystem` (paths outside the mounts are
/// rejected). Uses Drive's `alt=media`.
struct DriveDownload: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Download a Drive file's contents into the sandbox.",
        aliases: ["dl"])

    @Argument(help: "Drive file ID.") var id: String
    @Option(name: [.customShort("o"), .long],
            help: "Destination path inside the sandbox.")
    var out: String

    func run() async throws {
        var comps = URLComponents(
            string: "https://www.googleapis.com/drive/v3/files/\(id)")!
        comps.queryItems = [URLQueryItem(name: "alt", value: "media")]
        let data = try await GoogleHTTPClient().get(comps.url!)
        let resolved = Shell.bashCurrent.resolvePath(out)
        do {
            try await Shell.bashCurrent.fileSystem.writeData(
                data, to: resolved, append: false)
        } catch {
            Shell.bashCurrent.stderr("gog: cannot write \(out): \(error)\n")
            throw ExitCode(23)
        }
        Shell.bashCurrent.stderr("wrote \(data.count) bytes to \(out)\n")
    }
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
