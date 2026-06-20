import ArgumentParser
import Foundation
import BashInterpreter
import GogCore

/// gogcli's `--fail-empty` (aliases `--non-empty` / `--require-results`): a
/// reusable flag for list commands so a script can branch on "no results"
/// without parsing the payload. Mixed into a command via `@OptionGroup`.
struct FailEmptyFlag: ParsableArguments {
    @Flag(name: [.customLong("fail-empty"), .customLong("non-empty"),
                 .customLong("require-results")],
          help: "Exit 3 if the listing has no results.")
    var failEmpty: Bool = false

    init() {}
}

/// Emit the "No <label>" hint for an empty listing, then — when the caller
/// passed `--fail-empty` — exit 3 (gogcli's empty-results code). List commands
/// and the gated mutations never share a command, so reusing 3 is unambiguous.
func emitEmpty(_ label: String, failEmpty: Bool) throws {
    Shell.bashCurrent.stderr("No \(label)\n")
    if failEmpty { throw ExitCode(3) }
}

/// `--json --fail-empty` helper: decode the body with the *same* typed model the
/// human-readable path uses and report whether the command's own result
/// collection is empty and the listing is exhausted. Decoding the real model —
/// rather than scanning for "the first array" — means an omitted collection
/// counts as empty (Gmail, Tasks, People and Sheets all omit the array when there
/// are no results, matching the non-JSON `field ?? []` paths), and a sibling array
/// such as Calendar's `defaultReminders` can't trigger a false positive. A decode
/// failure ⇒ `false` (don't fail); this paginated overload also holds off while a
/// `nextPageToken` promises more.
func jsonListingEmpty<T: Decodable, E>(
    from body: Data, items: KeyPath<T, [E]?>, token: KeyPath<T, String?>) -> Bool {
    guard let decoded = try? JSONDecoder().decode(T.self, from: body) else { return false }
    if decoded[keyPath: token] != nil { return false }
    return (decoded[keyPath: items] ?? []).isEmpty
}

/// Non-paginated variant for responses without a `nextPageToken` (e.g. Gmail
/// labels, a single thread's messages, Sheets values, contact search).
func jsonListingEmpty<T: Decodable, E>(
    from body: Data, items: KeyPath<T, [E]?>) -> Bool {
    guard let decoded = try? JSONDecoder().decode(T.self, from: body) else { return false }
    return (decoded[keyPath: items] ?? []).isEmpty
}

/// Build a Google API URL from a constant base, an optional path-escaped id,
/// and query items. Never force-unwraps, so a hostile id can't crash the
/// process — it fails with exit 2 instead.
private func googleURL(_ base: String, id: String? = nil,
                       query: [URLQueryItem] = []) throws -> URL {
    var string = base
    if let id {
        string += "/" + (id.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? "")
    }
    guard var components = URLComponents(string: string) else {
        Shell.bashCurrent.stderr("gog: could not build a valid request URL\n")
        throw ExitCode(2)
    }
    if !query.isEmpty { components.queryItems = query }
    guard let url = components.url else {
        Shell.bashCurrent.stderr("gog: could not build a valid request URL\n")
        throw ExitCode(2)
    }
    return url
}

/// Host-policy gate for write commands: the tier the host granted
/// (`GogPolicies.current.writeTier`) must be at least `required`, else exit 3.
/// Read from the task-local policy only — never a flag or environment variable —
/// so LLM-authored bash can't escalate its own access.
private func requireWriteTier(_ required: GogWriteTier) throws {
    let granted = GogPolicies.current.writeTier
    if granted < required {
        Shell.bashCurrent.stderr(
            "gog: this command needs write tier '\(required)', but host policy "
                + "grants '\(granted)' (read-only by default)\n")
        throw ExitCode(3)
    }
}

/// Percent-encode a value that is a *single* path segment (an id, a user/group
/// key, a Sheets range): unlike `.urlPathAllowed` it also escapes "/" so a
/// stray separator becomes %2F instead of restructuring the request path.
private func pathSegment(_ value: String) -> String {
    let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

/// Root of the `gog` command tree. One `shell.install(GogCommand.self, …)`
/// registration exposes the whole nested subcommand tree — the same pattern
/// SwiftPorts' `gh` uses (`install(GhCommand.self)`), dispatched by
/// `BashCommandKit`'s `AsyncParsableCommandBridge` via `parseAsRoot`.
public struct GogCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "gog",
        abstract: "Google Workspace CLI (sandboxed, SwiftBash-native).",
        version: GogVersionInfo.version,
        subcommands: [
            GogVersion.self, GogMe.self,
            GogDrive.self, GogGmail.self, GogCalendar.self,
            GogContacts.self, GogTasks.self, GogDocs.self, GogSheets.self,
            GogChat.self, GogSlides.self, GogForms.self, GogYouTube.self,
            GogAdmin.self, GogAuth.self,
            // Top-level aliases (mirrors gogcli's `gog ls` / `gog send`).
            DriveLs.self, GmailSend.self,
        ])

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
        subcommands: [
            DriveLs.self, DriveGet.self, DriveSearch.self,
            DriveDownload.self, DriveUpload.self,
            DriveTrash.self, DriveUntrash.self, DriveRename.self, DriveMkdir.self,
            DriveCopy.self, DriveMove.self, DriveShare.self, DriveUnshare.self,
            DrivePermissions.self, DriveRevisions.self, DriveAbout.self,
        ],
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
    @OptionGroup var failEmptyFlag: FailEmptyFlag

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
        var fileQuery = "trashed = false"
        if let parent {
            let escaped = parent
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            fileQuery = "'\(escaped)' in parents and trashed = false"
        }
        query.append(URLQueryItem(name: "q", value: fileQuery))
        if let page {
            query.append(URLQueryItem(name: "pageToken", value: page))
        }
        comps.queryItems = query

        let body = try await GoogleHTTPClient().get(comps.url!)
        try emitDriveFileList(body, json: json, failEmpty: failEmptyFlag.failEmpty)
    }
}

/// `gog drive upload <path> --name … --parent …` — upload a sandbox file to
/// Drive via a multipart/related request (metadata + media). Reads the bytes
/// through `Shell.bashCurrent.fileSystem`, so only sandbox paths are readable.
struct DriveUpload: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upload",
        abstract: "Upload a sandbox file to Drive.",
        aliases: ["up", "put"])

    @Argument(help: "Path inside the sandbox to upload.") var path: String
    @Option(name: .long, help: "Name for the uploaded file (defaults to the file name).")
    var name: String?
    @Option(name: .long, help: "Parent folder ID.") var parent: String?
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        let resolved = Shell.bashCurrent.resolvePath(path)
        let data: Data
        do {
            data = try await Shell.bashCurrent.fileSystem.readData(resolved)
        } catch {
            Shell.bashCurrent.stderr("gog: cannot read \(path): \(error)\n")
            throw ExitCode(2)
        }
        let filename = name ?? URL(fileURLWithPath: path).lastPathComponent

        struct Meta: Encodable {
            let name: String
            let parents: [String]?
            enum CodingKeys: String, CodingKey { case name, parents }
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(name, forKey: .name)
                try container.encodeIfPresent(parents, forKey: .parents)
            }
        }
        let metadata = try JSONEncoder().encode(
            Meta(name: filename, parents: parent.map { [$0] }))

        let boundary = "gogboundary-\(UInt64.random(in: 0 ... .max))"
        var multipart = Data()
        multipart.append(Data("--\(boundary)\r\n".utf8))
        multipart.append(Data("Content-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        multipart.append(metadata)
        multipart.append(Data("\r\n--\(boundary)\r\n".utf8))
        multipart.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        multipart.append(data)
        multipart.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let url = try googleURL(
            "https://www.googleapis.com/upload/drive/v3/files",
            query: [
                URLQueryItem(name: "uploadType", value: "multipart"),
                URLQueryItem(name: "fields", value: "id,name"),
            ])
        let result = try await GoogleHTTPClient().post(
            url, body: multipart,
            contentType: "multipart/related; boundary=\(boundary)")
        if json {
            Shell.bashCurrent.stdout(String(decoding: result, as: UTF8.self) + "\n")
            return
        }
        let file = try JSONDecoder().decode(DriveFileList.File.self, from: result)
        Shell.bashCurrent.stdout("uploaded: \(file.id ?? "")\t\(file.name ?? "")\n")
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
private func emitDriveFileList(_ body: Data, json: Bool, failEmpty: Bool) throws {
    if json {
        Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
        if failEmpty, jsonListingEmpty(from: body, items: \DriveFileList.files, token: \DriveFileList.nextPageToken) { throw ExitCode(3) }
        return
    }
    let listing = try JSONDecoder().decode(DriveFileList.self, from: body)
    let files = listing.files ?? []
    if files.isEmpty { try emitEmpty("files", failEmpty: failEmpty && listing.nextPageToken == nil) }
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
        let url = try googleURL(
            "https://www.googleapis.com/drive/v3/files/\(pathSegment(id))",
            query: [URLQueryItem(
                name: "fields", value: "id,name,mimeType,modifiedTime,size,parents")])
        let body = try await GoogleHTTPClient().get(url)
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
    @Option(name: .long, help: "Page token from a previous listing.")
    var page: String?
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false
    @OptionGroup var failEmptyFlag: FailEmptyFlag

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
            URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType)"),
        ]
        if let page { comps.queryItems?.append(URLQueryItem(name: "pageToken", value: page)) }
        let body = try await GoogleHTTPClient().get(comps.url!)
        try emitDriveFileList(body, json: json, failEmpty: failEmptyFlag.failEmpty)
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
        let resolved = Shell.bashCurrent.resolvePath(out)
        // Validate the destination (non-destructively) before spending the
        // download, so an out-of-mount path fails closed without a fetch.
        try await ensureWritableDestination(resolved, label: out)
        let url = try googleURL(
            "https://www.googleapis.com/drive/v3/files/\(pathSegment(id))",
            query: [URLQueryItem(name: "alt", value: "media")])
        // Write the destination only after a successful fetch.
        let data = try await GoogleHTTPClient().get(url)
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

/// `gog drive permissions <fileId>` — who has access to a file/folder, and how.
struct DrivePermissions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "permissions",
        abstract: "List a file's permissions (who can access it).",
        aliases: ["perms"])

    @Argument(help: "Drive file or folder ID.") var fileId: String
    @Option(name: .long, help: "Maximum permissions to return (1–100).") var max: Int = 100
    @Option(name: .long, help: "Page token from a previous listing.") var page: String?
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false
    @OptionGroup var failEmptyFlag: FailEmptyFlag

    func run() async throws {
        guard max > 0, max <= 100 else {
            Shell.bashCurrent.stderr("gog: --max must be between 1 and 100\n")
            throw ExitCode(2)
        }
        var items = [
            URLQueryItem(name: "pageSize", value: String(max)),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(
                name: "fields",
                value: "nextPageToken,permissions"
                    + "(id,type,role,emailAddress,domain,displayName)"),
        ]
        if let page { items.append(URLQueryItem(name: "pageToken", value: page)) }
        let url = try googleURL(
            "https://www.googleapis.com/drive/v3/files/\(pathSegment(fileId))/permissions",
            query: items)
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            if failEmptyFlag.failEmpty, jsonListingEmpty(from: body, items: \DrivePermissionList.permissions, token: \DrivePermissionList.nextPageToken) { throw ExitCode(3) }
            return
        }
        let list = try JSONDecoder().decode(DrivePermissionList.self, from: body)
        let permissions = list.permissions ?? []
        if permissions.isEmpty { try emitEmpty("permissions", failEmpty: failEmptyFlag.failEmpty && list.nextPageToken == nil) }
        for perm in permissions {
            let who = perm.emailAddress ?? perm.domain ?? perm.displayName ?? ""
            Shell.bashCurrent.stdout(
                "\(perm.id ?? "")\t\(perm.role ?? "")\t\(perm.type ?? "")"
                    + "\t\(tsvEscaped(who))\n")
        }
        if let next = list.nextPageToken {
            Shell.bashCurrent.stderr("next page token: \(next)\n")
        }
    }
}

/// `gog drive revisions <fileId>` — a file's version history.
struct DriveRevisions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "revisions",
        abstract: "List a file's revisions (version history).",
        aliases: ["revs"])

    @Argument(help: "Drive file ID.") var fileId: String
    @Option(name: .long, help: "Maximum revisions to return (1–1000).") var max: Int = 200
    @Option(name: .long, help: "Page token from a previous listing.") var page: String?
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false
    @OptionGroup var failEmptyFlag: FailEmptyFlag

    func run() async throws {
        guard max > 0, max <= 1000 else {
            Shell.bashCurrent.stderr("gog: --max must be between 1 and 1000\n")
            throw ExitCode(2)
        }
        var items = [
            URLQueryItem(name: "pageSize", value: String(max)),
            // NB: revisions.list does NOT define supportsAllDrives (only files /
            // permissions / changes do), so it is deliberately omitted here to
            // avoid sending an unsupported query parameter.
            URLQueryItem(
                name: "fields",
                value: "nextPageToken,revisions"
                    + "(id,modifiedTime,size,lastModifyingUser/displayName)"),
        ]
        if let page { items.append(URLQueryItem(name: "pageToken", value: page)) }
        let url = try googleURL(
            "https://www.googleapis.com/drive/v3/files/\(pathSegment(fileId))/revisions",
            query: items)
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            if failEmptyFlag.failEmpty, jsonListingEmpty(from: body, items: \DriveRevisionList.revisions, token: \DriveRevisionList.nextPageToken) { throw ExitCode(3) }
            return
        }
        let list = try JSONDecoder().decode(DriveRevisionList.self, from: body)
        let revisions = list.revisions ?? []
        if revisions.isEmpty { try emitEmpty("revisions", failEmpty: failEmptyFlag.failEmpty && list.nextPageToken == nil) }
        for rev in revisions {
            let who = rev.lastModifyingUser?.displayName ?? ""
            Shell.bashCurrent.stdout(
                "\(rev.id ?? "")\t\(rev.modifiedTime ?? "")\t\(rev.size ?? "")"
                    + "\t\(tsvEscaped(who))\n")
        }
        if let next = list.nextPageToken {
            Shell.bashCurrent.stderr("next page token: \(next)\n")
        }
    }
}

/// `gog drive about` — the account's Drive storage quota and identity.
struct DriveAbout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "about",
        abstract: "Show Drive storage quota and account.")

    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        // `about` requires an explicit fields selector.
        let url = try googleURL(
            "https://www.googleapis.com/drive/v3/about",
            query: [URLQueryItem(
                name: "fields",
                value: "user(displayName,emailAddress),"
                    + "storageQuota(limit,usage,usageInDrive)")])
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            return
        }
        let about = try JSONDecoder().decode(DriveAboutInfo.self, from: body)
        let name = about.user?.displayName ?? "(unknown)"
        let email = about.user?.emailAddress ?? ""
        Shell.bashCurrent.stdout("\(name)\(email.isEmpty ? "" : " <\(email)>")\n")
        let usage = about.storageQuota?.usage ?? "?"
        let limit = about.storageQuota?.limit ?? "unlimited"
        Shell.bashCurrent.stdout("quota: usage=\(usage) limit=\(limit)\n")
    }
}

/// Drive write endpoints must opt into shared drives, mirroring the read
/// commands (`permissions`/`revisions` already pass `supportsAllDrives`).
private let driveSharedDrive = URLQueryItem(name: "supportsAllDrives", value: "true")

/// `gog drive trash <id>` — move a file to Trash (reversible via untrash).
struct DriveTrash: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trash",
        abstract: "Move a Drive file to Trash (--dry-run to preview).")

    @Argument(help: "Drive file ID.") var id: String
    @Flag(name: .long, help: "Show what would be trashed without trashing.")
    var dryRun: Bool = false
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        try requireWriteTier(.full)
        if dryRun {
            Shell.bashCurrent.stderr("dry-run: not trashing\n")
            Shell.bashCurrent.stdout("would trash: \(id)\n")
            return
        }
        let payload = try JSONEncoder().encode(["trashed": true])
        let url = try googleURL(
            "https://www.googleapis.com/drive/v3/files/\(pathSegment(id))",
            query: [driveSharedDrive])
        let result = try await GoogleHTTPClient().patch(url, jsonBody: payload)
        if json {
            Shell.bashCurrent.stdout(String(decoding: result, as: UTF8.self) + "\n")
            return
        }
        Shell.bashCurrent.stdout("trashed: \(id)\n")
    }
}

/// `gog drive untrash <id>` — restore a file from Trash.
struct DriveUntrash: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "untrash",
        abstract: "Restore a Drive file from Trash (--dry-run to preview).")

    @Argument(help: "Drive file ID.") var id: String
    @Flag(name: .long, help: "Show what would be restored without restoring.")
    var dryRun: Bool = false
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        try requireWriteTier(.edit)
        if dryRun {
            Shell.bashCurrent.stderr("dry-run: not untrashing\n")
            Shell.bashCurrent.stdout("would untrash: \(id)\n")
            return
        }
        let payload = try JSONEncoder().encode(["trashed": false])
        let url = try googleURL(
            "https://www.googleapis.com/drive/v3/files/\(pathSegment(id))",
            query: [driveSharedDrive])
        let result = try await GoogleHTTPClient().patch(url, jsonBody: payload)
        if json {
            Shell.bashCurrent.stdout(String(decoding: result, as: UTF8.self) + "\n")
            return
        }
        Shell.bashCurrent.stdout("untrashed: \(id)\n")
    }
}

/// `gog drive rename <id> --name <newName>` — rename a Drive file.
struct DriveRename: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename a Drive file (--dry-run to preview).")

    @Argument(help: "Drive file ID.") var id: String
    @Option(name: .long, help: "New file name.") var name: String
    @Flag(name: .long, help: "Build the request but do not rename.")
    var dryRun: Bool = false
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        try requireWriteTier(.edit)
        let payload = try JSONEncoder().encode(["name": name])
        if dryRun {
            Shell.bashCurrent.stderr("dry-run: not renaming\n")
            Shell.bashCurrent.stdout(String(decoding: payload, as: UTF8.self) + "\n")
            return
        }
        let url = try googleURL(
            "https://www.googleapis.com/drive/v3/files/\(pathSegment(id))",
            query: [driveSharedDrive])
        let result = try await GoogleHTTPClient().patch(url, jsonBody: payload)
        if json {
            Shell.bashCurrent.stdout(String(decoding: result, as: UTF8.self) + "\n")
            return
        }
        let file = try JSONDecoder().decode(DriveFileList.File.self, from: result)
        Shell.bashCurrent.stdout("renamed: \(file.id ?? id)\t\(file.name ?? name)\n")
    }
}

/// `gog drive mkdir <name>` — create a folder, optionally inside `--parent`.
struct DriveMkdir: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mkdir",
        abstract: "Create a Drive folder (--dry-run to preview).")

    @Argument(help: "Folder name.") var name: String
    @Option(name: .long, help: "Parent folder ID (default: My Drive root).")
    var parent: String?
    @Flag(name: .long, help: "Build the request but do not create the folder.")
    var dryRun: Bool = false
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        try requireWriteTier(.edit)
        struct NewFolder: Encodable {
            let name: String
            let mimeType: String
            let parents: [String]?
        }
        let payload = try JSONEncoder().encode(NewFolder(
            name: name,
            mimeType: "application/vnd.google-apps.folder",
            parents: parent.map { [$0] }))
        if dryRun {
            Shell.bashCurrent.stderr("dry-run: not creating folder\n")
            Shell.bashCurrent.stdout(String(decoding: payload, as: UTF8.self) + "\n")
            return
        }
        let url = try googleURL(
            "https://www.googleapis.com/drive/v3/files", query: [driveSharedDrive])
        let result = try await GoogleHTTPClient().post(url, jsonBody: payload)
        if json {
            Shell.bashCurrent.stdout(String(decoding: result, as: UTF8.self) + "\n")
            return
        }
        let file = try JSONDecoder().decode(DriveFileList.File.self, from: result)
        Shell.bashCurrent.stdout(
            "created folder: \(file.id ?? "")\t\(file.name ?? name)\n")
    }
}

/// `gog drive cp <id>` — copy a file, optionally renaming and/or into `--parent`.
struct DriveCopy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cp",
        abstract: "Copy a Drive file (--dry-run to preview).",
        aliases: ["copy"])

    @Argument(help: "Drive file ID to copy.") var id: String
    @Option(name: .long, help: "Name for the copy (default: Google's \"Copy of …\").")
    var name: String?
    @Option(name: .long, help: "Destination parent folder ID.") var parent: String?
    @Flag(name: .long, help: "Build the request but do not copy.")
    var dryRun: Bool = false
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        try requireWriteTier(.edit)
        struct CopyBody: Encodable {
            let name: String?
            let parents: [String]?
        }
        let payload = try JSONEncoder().encode(
            CopyBody(name: name, parents: parent.map { [$0] }))
        if dryRun {
            Shell.bashCurrent.stderr("dry-run: not copying\n")
            Shell.bashCurrent.stdout(String(decoding: payload, as: UTF8.self) + "\n")
            return
        }
        let url = try googleURL(
            "https://www.googleapis.com/drive/v3/files/\(pathSegment(id))/copy",
            query: [driveSharedDrive])
        let result = try await GoogleHTTPClient().post(url, jsonBody: payload)
        if json {
            Shell.bashCurrent.stdout(String(decoding: result, as: UTF8.self) + "\n")
            return
        }
        let file = try JSONDecoder().decode(DriveFileList.File.self, from: result)
        Shell.bashCurrent.stdout("copied: \(file.id ?? "")\t\(file.name ?? "")\n")
    }
}

/// `gog drive mv <id> --to <parentId>` — move a file to another folder. A Drive
/// move is a parent edit (addParents/removeParents); when `--from` is omitted we
/// look up the current parent(s) and remove them so the file isn't left in two
/// places.
struct DriveMove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mv",
        abstract: "Move a Drive file to another folder (--dry-run to preview).",
        aliases: ["move"])

    @Argument(help: "Drive file ID to move.") var id: String
    @Option(name: .long, help: "Destination parent folder ID.") var to: String
    @Option(name: .long, help: "Parent ID to remove (default: all current parents).")
    var from: String?
    @Flag(name: .long, help: "Build the request but do not move.")
    var dryRun: Bool = false
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        try requireWriteTier(.full)
        if dryRun {
            Shell.bashCurrent.stderr("dry-run: not moving\n")
            Shell.bashCurrent.stdout("would move: \(id) -> \(to)\n")
            return
        }
        var remove = from
        if remove == nil {
            let metaURL = try googleURL(
                "https://www.googleapis.com/drive/v3/files/\(pathSegment(id))",
                query: [URLQueryItem(name: "fields", value: "parents"),
                        driveSharedDrive])
            let meta = try JSONDecoder().decode(
                DriveParents.self, from: try await GoogleHTTPClient().get(metaURL))
            remove = (meta.parents ?? []).joined(separator: ",")
        }
        var query = [URLQueryItem(name: "addParents", value: to), driveSharedDrive]
        if let remove, !remove.isEmpty {
            query.append(URLQueryItem(name: "removeParents", value: remove))
        }
        let url = try googleURL(
            "https://www.googleapis.com/drive/v3/files/\(pathSegment(id))", query: query)
        let result = try await GoogleHTTPClient().patch(url, jsonBody: Data("{}".utf8))
        if json {
            Shell.bashCurrent.stdout(String(decoding: result, as: UTF8.self) + "\n")
            return
        }
        Shell.bashCurrent.stdout("moved: \(id) -> \(to)\n")
    }
}

/// `gog drive share <id>` — grant access. `--email` shares with a person/group;
/// `--anyone` makes a link anyone can open. Role: reader (default), writer, or
/// commenter.
struct DriveShare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "share",
        abstract: "Grant access to a Drive file (--dry-run to preview).")

    @Argument(help: "Drive file or folder ID.") var id: String
    @Option(name: .long, help: "Grantee email (a user or group).") var email: String?
    @Flag(name: .long, help: "Share with anyone who has the link (no email).")
    var anyone: Bool = false
    @Option(name: .long, help: "Role: reader, writer, or commenter.")
    var role: String = "reader"
    @Option(name: .long, help: "Grantee type for --email: user or group.")
    var type: String = "user"
    @Flag(name: .long, help: "Build the request but do not share.")
    var dryRun: Bool = false
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        try requireWriteTier(.full)
        guard ["reader", "writer", "commenter"].contains(role) else {
            Shell.bashCurrent.stderr(
                "gog: --role must be reader, writer, or commenter\n")
            throw ExitCode(2)
        }
        guard anyone != (email != nil) else {
            Shell.bashCurrent.stderr(
                "gog: drive share needs exactly one of --email <addr> or --anyone\n")
            throw ExitCode(2)
        }
        guard anyone || ["user", "group"].contains(type) else {
            Shell.bashCurrent.stderr("gog: --type must be user or group\n")
            throw ExitCode(2)
        }
        struct PermissionBody: Encodable {
            let type: String
            let role: String
            let emailAddress: String?
        }
        let body = anyone
            ? PermissionBody(type: "anyone", role: role, emailAddress: nil)
            : PermissionBody(type: type, role: role, emailAddress: email)
        let payload = try JSONEncoder().encode(body)
        if dryRun {
            Shell.bashCurrent.stderr("dry-run: not sharing\n")
            Shell.bashCurrent.stdout(String(decoding: payload, as: UTF8.self) + "\n")
            return
        }
        let url = try googleURL(
            "https://www.googleapis.com/drive/v3/files/\(pathSegment(id))/permissions",
            query: [driveSharedDrive])
        let result = try await GoogleHTTPClient().post(url, jsonBody: payload)
        if json {
            Shell.bashCurrent.stdout(String(decoding: result, as: UTF8.self) + "\n")
            return
        }
        let perm = try JSONDecoder().decode(SharePermission.self, from: result)
        Shell.bashCurrent.stdout("shared: \(perm.id ?? "")\t\(role)\n")
    }
}

/// `gog drive unshare <id> --permission <permId>` — revoke a permission (find
/// IDs with `gog drive permissions`).
struct DriveUnshare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unshare",
        abstract: "Revoke a Drive permission by ID (--dry-run to preview).")

    @Argument(help: "Drive file or folder ID.") var id: String
    @Option(name: .long, help: "Permission ID (from `gog drive permissions`).")
    var permission: String
    @Flag(name: .long, help: "Show what would be revoked without revoking.")
    var dryRun: Bool = false

    func run() async throws {
        try requireWriteTier(.full)
        if dryRun {
            Shell.bashCurrent.stderr("dry-run: not revoking\n")
            Shell.bashCurrent.stdout("would revoke: \(permission) on \(id)\n")
            return
        }
        let url = try googleURL(
            "https://www.googleapis.com/drive/v3/files/\(pathSegment(id))"
                + "/permissions/\(pathSegment(permission))",
            query: [driveSharedDrive])
        _ = try await GoogleHTTPClient().delete(url)
        Shell.bashCurrent.stdout("revoked: \(permission)\n")
    }
}

private struct DriveParents: Decodable { let parents: [String]? }
private struct SharePermission: Decodable { let id: String? }

private struct DrivePermissionList: Decodable {
    struct Permission: Decodable {
        let id: String?
        let type: String?
        let role: String?
        let emailAddress: String?
        let domain: String?
        let displayName: String?
    }
    let permissions: [Permission]?
    let nextPageToken: String?
}
private struct DriveRevisionList: Decodable {
    struct Revision: Decodable {
        struct User: Decodable { let displayName: String? }
        let id: String?
        let modifiedTime: String?
        // Drive serialises revision size as a JSON string.
        let size: String?
        let lastModifyingUser: User?
    }
    let revisions: [Revision]?
    let nextPageToken: String?
}
private struct DriveAboutInfo: Decodable {
    struct User: Decodable { let displayName: String?; let emailAddress: String? }
    struct Quota: Decodable {
        // These byte counts are serialised as JSON strings.
        let limit: String?
        let usage: String?
        let usageInDrive: String?
    }
    let user: User?
    let storageQuota: Quota?
}

/// `gog gmail …` — Gmail group (read commands; `send` lands separately).
struct GogGmail: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gmail",
        abstract: "Gmail.",
        subcommands: [
            GmailMessages.self, GmailGet.self, GmailSend.self, GmailLabels.self,
            GmailModify.self, GmailTrash.self, GmailUntrash.self,
            GmailDrafts.self, GmailDraft.self,
            GmailThreads.self, GmailThreadGet.self,
            GmailAttachments.self, GmailAttachment.self,
        ],
        aliases: ["mail", "email"])
}

/// `gog gmail messages` — list message IDs (optionally filtered by a query).
struct GmailMessages: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "messages",
        abstract: "List message IDs.",
        aliases: ["list"])

    @Option(name: [.customShort("q"), .long], help: "Gmail search query.")
    var query: String?
    @Option(name: .long, help: "Maximum messages to return (1–500).")
    var max: Int = 100
    @Option(name: .long, help: "Page token from a previous listing.")
    var page: String?
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false
    @OptionGroup var failEmptyFlag: FailEmptyFlag

    func run() async throws {
        guard max > 0, max <= 500 else {
            Shell.bashCurrent.stderr("gog: --max must be between 1 and 500\n")
            throw ExitCode(2)
        }
        var comps = URLComponents(
            string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        var query = [URLQueryItem(name: "maxResults", value: String(max))]
        if let q = self.query { query.append(URLQueryItem(name: "q", value: q)) }
        if let page { query.append(URLQueryItem(name: "pageToken", value: page)) }
        comps.queryItems = query

        let body = try await GoogleHTTPClient().get(comps.url!)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            if failEmptyFlag.failEmpty, jsonListingEmpty(from: body, items: \GmailMessageList.messages, token: \GmailMessageList.nextPageToken) { throw ExitCode(3) }
            return
        }
        let list = try JSONDecoder().decode(GmailMessageList.self, from: body)
        let messages = list.messages ?? []
        if messages.isEmpty { try emitEmpty("messages", failEmpty: failEmptyFlag.failEmpty && list.nextPageToken == nil) }
        for message in messages {
            Shell.bashCurrent.stdout("\(message.id ?? "")\t\(message.threadId ?? "")\n")
        }
        if let next = list.nextPageToken {
            Shell.bashCurrent.stderr("next page token: \(next)\n")
        }
    }
}

/// `gog gmail get <id>` — a message's key headers and snippet.
struct GmailGet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Show a message's headers and snippet.")

    @Argument(help: "Gmail message ID.") var id: String
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        let url = try googleURL(
            "https://gmail.googleapis.com/gmail/v1/users/me/messages", id: id,
            query: [
                URLQueryItem(name: "format", value: "metadata"),
                URLQueryItem(name: "metadataHeaders", value: "From"),
                URLQueryItem(name: "metadataHeaders", value: "Subject"),
                URLQueryItem(name: "metadataHeaders", value: "Date"),
            ])
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            return
        }
        let message = try JSONDecoder().decode(GmailMessage.self, from: body)
        let headers = message.payload?.headers ?? []
        func header(_ name: String) -> String {
            headers.first { $0.name?.caseInsensitiveCompare(name) == .orderedSame }?
                .value ?? ""
        }
        Shell.bashCurrent.stdout("From: \(header("From"))\n")
        Shell.bashCurrent.stdout("Subject: \(header("Subject"))\n")
        Shell.bashCurrent.stdout("Date: \(header("Date"))\n")
        if let snippet = message.snippet, !snippet.isEmpty {
            Shell.bashCurrent.stdout("\n\(snippet)\n")
        }
    }
}

/// Build a plain-text RFC822 message (To/Subject/body) for Gmail `send` or
/// `draft`. Rejects CR/LF in the header fields to prevent header injection
/// (e.g. a smuggled `Bcc:`), and RFC 2047-encodes a non-ASCII subject. Throws
/// `ExitCode(2)` on bad input. Shared so the injection guard has one home.
private func plainTextMIME(to: String, subject: String, body: String) throws -> Data {
    let newlines = CharacterSet(charactersIn: "\r\n")
    guard to.rangeOfCharacter(from: newlines) == nil,
          subject.rangeOfCharacter(from: newlines) == nil else {
        Shell.bashCurrent.stderr("gog: --to and --subject must not contain newlines\n")
        throw ExitCode(2)
    }
    let encodedSubject = subject.allSatisfy(\.isASCII)
        ? subject
        : "=?UTF-8?B?\(Data(subject.utf8).base64EncodedString())?="
    let mime = "To: \(to)\r\n"
        + "Subject: \(encodedSubject)\r\n"
        + "Content-Type: text/plain; charset=UTF-8\r\n\r\n"
        + body
    return Data(mime.utf8)
}

/// `gog gmail send --to … --subject … --body …` — send a plain-text email.
/// Honours the host send policy (`GogPolicies`) and `--dry-run`.
struct GmailSend: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send a plain-text email.")

    @Option(name: .long, help: "Recipient email address.") var to: String
    @Option(name: .long, help: "Subject line.") var subject: String = ""
    @Option(name: [.customShort("b"), .long], help: "Message body (plain text).")
    var body: String = ""
    @Flag(name: .long, help: "Build the message but do not send it.")
    var dryRun: Bool = false
    @Flag(name: [.customShort("j"), .long], help: "Emit the raw send result JSON.")
    var json: Bool = false

    func run() async throws {
        // Host policy gate (the SwiftBash form of --gmail-no-send).
        if GogPolicies.current.gmailSendDisabled {
            Shell.bashCurrent.stderr("gog: sending is disabled by host policy\n")
            throw ExitCode(3)
        }
        let mimeData = try plainTextMIME(to: to, subject: subject, body: body)
        if dryRun {
            Shell.bashCurrent.stderr("dry-run: not sending\n")
            Shell.bashCurrent.stdout(
                "To: \(to)\nSubject: \(subject)\n(\(mimeData.count) bytes)\n")
            return
        }
        let payload = try JSONEncoder().encode(
            ["raw": mimeData.base64URLEncodedString()])
        let url = URL(
            string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!
        let result = try await GoogleHTTPClient().post(url, jsonBody: payload)
        if json {
            Shell.bashCurrent.stdout(String(decoding: result, as: UTF8.self) + "\n")
            return
        }
        let sent = try JSONDecoder().decode(GmailSendResult.self, from: result)
        Shell.bashCurrent.stdout("sent: \(sent.id ?? "")\n")
    }
}

private struct GmailSendResult: Decodable {
    let id: String?
    let threadId: String?
}

private extension Data {
    /// Gmail's `raw` field wants unpadded base64url.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decode (possibly unpadded) base64url, e.g. a Gmail attachment's `data`.
    init?(base64URLEncoded string: String) {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // base64url is ASCII, so utf8.count avoids an O(N) grapheme walk.
        let remainder = s.utf8.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: s)
    }
}

private struct GmailMessageList: Decodable {
    struct Ref: Decodable { let id: String?; let threadId: String? }
    let messages: [Ref]?
    let nextPageToken: String?
}

private struct GmailMessage: Decodable {
    struct Payload: Decodable {
        struct Header: Decodable { let name: String?; let value: String? }
        let headers: [Header]?
    }
    let id: String?
    let snippet: String?
    let payload: Payload?
}

/// `gog gmail drafts` — list draft IDs (and their message IDs).
struct GmailDrafts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drafts",
        abstract: "List draft IDs.")

    @Option(name: .long, help: "Maximum drafts to return (1–500).") var max: Int = 100
    @Option(name: .long, help: "Page token from a previous listing.") var page: String?
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false
    @OptionGroup var failEmptyFlag: FailEmptyFlag

    func run() async throws {
        guard max > 0, max <= 500 else {
            Shell.bashCurrent.stderr("gog: --max must be between 1 and 500\n")
            throw ExitCode(2)
        }
        var items = [URLQueryItem(name: "maxResults", value: String(max))]
        if let page { items.append(URLQueryItem(name: "pageToken", value: page)) }
        let url = try googleURL(
            "https://gmail.googleapis.com/gmail/v1/users/me/drafts", query: items)
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            if failEmptyFlag.failEmpty, jsonListingEmpty(from: body, items: \GmailDraftList.drafts, token: \GmailDraftList.nextPageToken) { throw ExitCode(3) }
            return
        }
        let list = try JSONDecoder().decode(GmailDraftList.self, from: body)
        let drafts = list.drafts ?? []
        if drafts.isEmpty { try emitEmpty("drafts", failEmpty: failEmptyFlag.failEmpty && list.nextPageToken == nil) }
        for draft in drafts {
            Shell.bashCurrent.stdout("\(draft.id ?? "")\t\(draft.message?.id ?? "")\n")
        }
        if let next = list.nextPageToken {
            Shell.bashCurrent.stderr("next page token: \(next)\n")
        }
    }
}

/// `gog gmail draft --to … --subject … --body …` — compose a draft. A draft is
/// never sent, so this is not gated by the host send policy.
struct GmailDraft: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "draft",
        abstract: "Create a draft (does not send).")

    @Option(name: .long, help: "Recipient email address.") var to: String
    @Option(name: .long, help: "Subject line.") var subject: String = ""
    @Option(name: [.customShort("b"), .long], help: "Message body (plain text).")
    var body: String = ""
    @Flag(name: [.customShort("j"), .long], help: "Emit the raw draft result JSON.")
    var json: Bool = false

    func run() async throws {
        let mimeData = try plainTextMIME(to: to, subject: subject, body: body)
        let payload = try JSONEncoder().encode(
            ["message": ["raw": mimeData.base64URLEncodedString()]])
        let url = try googleURL("https://gmail.googleapis.com/gmail/v1/users/me/drafts")
        let result = try await GoogleHTTPClient().post(url, jsonBody: payload)
        if json {
            Shell.bashCurrent.stdout(String(decoding: result, as: UTF8.self) + "\n")
            return
        }
        let draft = try JSONDecoder().decode(GmailDraftResult.self, from: result)
        Shell.bashCurrent.stdout("draft created: \(draft.id ?? "")\n")
    }
}

/// `gog gmail threads` — list thread IDs with their snippets.
struct GmailThreads: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "threads",
        abstract: "List thread IDs.")

    @Option(name: [.customShort("q"), .long], help: "Gmail search query.")
    var query: String?
    @Option(name: .long, help: "Maximum threads to return (1–500).") var max: Int = 100
    @Option(name: .long, help: "Page token from a previous listing.") var page: String?
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false
    @OptionGroup var failEmptyFlag: FailEmptyFlag

    func run() async throws {
        guard max > 0, max <= 500 else {
            Shell.bashCurrent.stderr("gog: --max must be between 1 and 500\n")
            throw ExitCode(2)
        }
        var items = [URLQueryItem(name: "maxResults", value: String(max))]
        if let query { items.append(URLQueryItem(name: "q", value: query)) }
        if let page { items.append(URLQueryItem(name: "pageToken", value: page)) }
        let url = try googleURL(
            "https://gmail.googleapis.com/gmail/v1/users/me/threads", query: items)
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            if failEmptyFlag.failEmpty, jsonListingEmpty(from: body, items: \GmailThreadList.threads, token: \GmailThreadList.nextPageToken) { throw ExitCode(3) }
            return
        }
        let list = try JSONDecoder().decode(GmailThreadList.self, from: body)
        let threads = list.threads ?? []
        if threads.isEmpty { try emitEmpty("threads", failEmpty: failEmptyFlag.failEmpty && list.nextPageToken == nil) }
        for thread in threads {
            Shell.bashCurrent.stdout(
                "\(thread.id ?? "")\t\(tsvEscaped(thread.snippet ?? ""))\n")
        }
        if let next = list.nextPageToken {
            Shell.bashCurrent.stderr("next page token: \(next)\n")
        }
    }
}

/// `gog gmail thread <id>` — a thread's messages (id, From, Subject per line).
struct GmailThreadGet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "thread",
        abstract: "Show a thread's messages (From/Subject).")

    @Argument(help: "Gmail thread ID.") var id: String
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false
    @OptionGroup var failEmptyFlag: FailEmptyFlag

    func run() async throws {
        let url = try googleURL(
            "https://gmail.googleapis.com/gmail/v1/users/me/threads", id: id,
            query: [
                URLQueryItem(name: "format", value: "metadata"),
                URLQueryItem(name: "metadataHeaders", value: "From"),
                URLQueryItem(name: "metadataHeaders", value: "Subject"),
            ])
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            if failEmptyFlag.failEmpty, jsonListingEmpty(from: body, items: \GmailThread.messages) { throw ExitCode(3) }
            return
        }
        let thread = try JSONDecoder().decode(GmailThread.self, from: body)
        let messages = thread.messages ?? []
        if messages.isEmpty { try emitEmpty("messages in thread", failEmpty: failEmptyFlag.failEmpty) }
        for message in messages {
            let headers = message.payload?.headers ?? []
            func header(_ name: String) -> String {
                headers.first {
                    $0.name?.caseInsensitiveCompare(name) == .orderedSame
                }?.value ?? ""
            }
            Shell.bashCurrent.stdout(
                "\(message.id ?? "")\t\(tsvEscaped(header("From")))"
                    + "\t\(tsvEscaped(header("Subject")))\n")
        }
    }
}

/// `gog gmail attachments <messageId>` — list a message's attachments so their
/// IDs can be fed to `gog gmail attachment`. Walks the full message payload
/// (recursively) for parts that carry a filename; the bytes are then fetched
/// via `body.attachmentId`, or are inline in `body.data` for small attachments.
struct GmailAttachments: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attachments",
        abstract: "List a message's attachments (id, filename, type, size).")

    @Argument(help: "Gmail message ID.") var messageId: String
    @Flag(name: [.customShort("j"), .long], help: "Emit the attachment list as JSON.")
    var json: Bool = false
    @OptionGroup var failEmptyFlag: FailEmptyFlag

    func run() async throws {
        let url = try googleURL(
            "https://gmail.googleapis.com/gmail/v1/users/me/messages", id: messageId,
            query: [URLQueryItem(name: "format", value: "full")])
        let body = try await GoogleHTTPClient().get(url)
        let message = try JSONDecoder().decode(GmailFullMessage.self, from: body)

        // Collect only the attachment parts. We never forward the raw message:
        // a `format=full` response also carries headers and inline body data,
        // which this discovery command does not advertise (and shouldn't leak).
        var attachments: [GmailAttachmentInfo] = []
        func walk(_ part: GmailFullMessage.Part?) {
            guard let part else { return }
            // An attachment is identified by a non-empty filename. Message body
            // parts have none — even when Gmail stores a large body under its
            // own attachmentId — so keying on filename both excludes those and
            // surfaces small attachments whose bytes are inline in body.data
            // (attachmentId then empty).
            if let filename = part.filename, !filename.isEmpty {
                attachments.append(GmailAttachmentInfo(
                    attachmentId: part.body?.attachmentId ?? "",
                    filename: filename,
                    mimeType: part.mimeType ?? "",
                    size: part.body?.size))
            }
            for child in part.parts ?? [] { walk(child) }
        }
        walk(message.payload)

        if json {
            let encoded = try JSONEncoder().encode(["attachments": attachments])
            Shell.bashCurrent.stdout(String(decoding: encoded, as: UTF8.self) + "\n")
            if failEmptyFlag.failEmpty, attachments.isEmpty { throw ExitCode(3) }
            return
        }
        if attachments.isEmpty { try emitEmpty("attachments", failEmpty: failEmptyFlag.failEmpty) }
        for att in attachments {
            let size = att.size.map(String.init) ?? ""
            Shell.bashCurrent.stdout(
                "\(att.attachmentId)\t\(tsvEscaped(att.filename))"
                    + "\t\(tsvEscaped(att.mimeType))\t\(size)\n")
        }
    }
}

/// `gog gmail attachment <messageId> <attachmentId> --out <path>` — download a
/// message attachment into the sandbox.
struct GmailAttachment: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attachment",
        abstract: "Download a message attachment into the sandbox.",
        aliases: ["attach"])

    @Argument(help: "Gmail message ID.") var messageId: String
    @Argument(help: "Attachment ID (see `gmail attachments <messageId>`).")
    var attachmentId: String
    @Option(name: [.customShort("o"), .long],
            help: "Destination path inside the sandbox.")
    var out: String

    func run() async throws {
        let resolved = Shell.bashCurrent.resolvePath(out)
        // Validate the destination (non-destructively) before the fetch.
        try await ensureWritableDestination(resolved, label: out)
        let url = try googleURL(
            "https://gmail.googleapis.com/gmail/v1/users/me/messages/"
                + "\(pathSegment(messageId))/attachments/\(pathSegment(attachmentId))")
        let body = try await GoogleHTTPClient().get(url)
        let attach = try JSONDecoder().decode(GmailAttachmentBody.self, from: body)
        guard let encoded = attach.data,
              let data = Data(base64URLEncoded: encoded) else {
            Shell.bashCurrent.stderr("gog: attachment had no decodable data\n")
            throw ExitCode(1)
        }
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

/// `gog gmail modify <id>` — add/remove labels on a message (e.g. mark read by
/// removing UNREAD, star by adding STARRED). Takes label *IDs*, not names —
/// look them up with `gog gmail labels`.
struct GmailModify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "modify",
        abstract: "Add/remove a message's labels by ID (--dry-run to preview).")

    @Argument(help: "Gmail message ID.") var id: String
    @Option(name: .long, help: "Label ID to add (repeatable, e.g. STARRED).")
    var addLabel: [String] = []
    @Option(name: .long, help: "Label ID to remove (repeatable, e.g. UNREAD).")
    var removeLabel: [String] = []
    @Flag(name: .long, help: "Build the request but do not modify the message.")
    var dryRun: Bool = false
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        try requireWriteTier(.edit)
        guard !addLabel.isEmpty || !removeLabel.isEmpty else {
            Shell.bashCurrent.stderr(
                "gog: gmail modify needs at least one --add-label or "
                    + "--remove-label (label IDs from `gog gmail labels`)\n")
            throw ExitCode(2)
        }
        struct ModifyBody: Encodable {
            let addLabelIds: [String]
            let removeLabelIds: [String]
        }
        let payload = try JSONEncoder().encode(
            ModifyBody(addLabelIds: addLabel, removeLabelIds: removeLabel))
        if dryRun {
            Shell.bashCurrent.stderr("dry-run: not modifying\n")
            Shell.bashCurrent.stdout(String(decoding: payload, as: UTF8.self) + "\n")
            return
        }
        let url = try googleURL(
            "https://gmail.googleapis.com/gmail/v1/users/me/messages",
            id: "\(id)/modify")
        let result = try await GoogleHTTPClient().post(url, jsonBody: payload)
        if json {
            Shell.bashCurrent.stdout(String(decoding: result, as: UTF8.self) + "\n")
            return
        }
        Shell.bashCurrent.stdout("modified: \(id)\n")
    }
}

/// `gog gmail trash <id>` — move a message to Trash (reversible via untrash).
struct GmailTrash: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trash",
        abstract: "Move a message to Trash (--dry-run to preview).")

    @Argument(help: "Gmail message ID.") var id: String
    @Flag(name: .long, help: "Show what would be trashed without trashing.")
    var dryRun: Bool = false

    func run() async throws {
        try requireWriteTier(.full)
        if dryRun {
            Shell.bashCurrent.stderr("dry-run: not trashing\n")
            Shell.bashCurrent.stdout("would trash: \(id)\n")
            return
        }
        let url = try googleURL(
            "https://gmail.googleapis.com/gmail/v1/users/me/messages",
            id: "\(id)/trash")
        _ = try await GoogleHTTPClient().post(url, jsonBody: Data("{}".utf8))
        Shell.bashCurrent.stdout("trashed: \(id)\n")
    }
}

/// `gog gmail untrash <id>` — restore a message from Trash.
struct GmailUntrash: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "untrash",
        abstract: "Restore a message from Trash (--dry-run to preview).")

    @Argument(help: "Gmail message ID.") var id: String
    @Flag(name: .long, help: "Show what would be restored without restoring.")
    var dryRun: Bool = false

    func run() async throws {
        try requireWriteTier(.edit)
        if dryRun {
            Shell.bashCurrent.stderr("dry-run: not untrashing\n")
            Shell.bashCurrent.stdout("would untrash: \(id)\n")
            return
        }
        let url = try googleURL(
            "https://gmail.googleapis.com/gmail/v1/users/me/messages",
            id: "\(id)/untrash")
        _ = try await GoogleHTTPClient().post(url, jsonBody: Data("{}".utf8))
        Shell.bashCurrent.stdout("untrashed: \(id)\n")
    }
}

private struct GmailDraftList: Decodable {
    struct Draft: Decodable {
        struct Msg: Decodable { let id: String?; let threadId: String? }
        let id: String?
        let message: Msg?
    }
    let drafts: [Draft]?
    let nextPageToken: String?
}
private struct GmailDraftResult: Decodable {
    struct Msg: Decodable { let id: String? }
    let id: String?
    let message: Msg?
}
private struct GmailThreadList: Decodable {
    struct Thread: Decodable { let id: String?; let snippet: String? }
    let threads: [Thread]?
    let nextPageToken: String?
}
private struct GmailThread: Decodable {
    let id: String?
    let messages: [GmailMessage]?
}
private struct GmailAttachmentBody: Decodable { let size: Int?; let data: String? }
/// The slice of an attachment surfaced by `gmail attachments` (also the `--json`
/// shape) — deliberately excludes headers and inline body content.
private struct GmailAttachmentInfo: Encodable {
    let attachmentId: String
    let filename: String
    let mimeType: String
    let size: Int?
}
private struct GmailFullMessage: Decodable {
    struct Part: Decodable {
        struct Body: Decodable { let attachmentId: String?; let size: Int? }
        let filename: String?
        let mimeType: String?
        let body: Body?
        let parts: [Part]?
    }
    let payload: Part?
}

/// `gog calendar …` — Google Calendar group (primary calendar).
struct GogCalendar: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calendar",
        abstract: "Google Calendar.",
        subcommands: [
            CalendarEvents.self, CalendarGet.self, CalendarCreate.self,
            CalendarUpdate.self, CalendarDelete.self,
            CalendarCalendars.self, CalendarFreeBusy.self,
        ],
        aliases: ["cal"])
}

/// `gog calendar events` — list upcoming events on the primary calendar.
struct CalendarEvents: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "events",
        abstract: "List events on the primary calendar.",
        aliases: ["list"])

    @Option(name: .long, help: "Maximum events to return (1–2500).")
    var max: Int = 100
    @Option(name: .long, help: "Earliest start time (RFC3339).")
    var from: String?
    @Option(name: .long, help: "Page token from a previous listing.")
    var page: String?
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false
    @OptionGroup var failEmptyFlag: FailEmptyFlag

    func run() async throws {
        guard max > 0, max <= 2500 else {
            Shell.bashCurrent.stderr("gog: --max must be between 1 and 2500\n")
            throw ExitCode(2)
        }
        // Calendar paging must replay the original request: the time window is
        // baked into the page token. `timeMin` defaults to "now" when --from is
        // omitted, which a later --page call can't reproduce — so require an
        // explicit --from when paging rather than silently shifting the window.
        if page != nil, from == nil {
            Shell.bashCurrent.stderr(
                "gog: calendar events --page requires --from "
                    + "(the token is tied to the original time window).\n"
                    + "The previous listing printed a ready-to-run command after "
                    + "\"next page:\" — use that.\n"
                    + "Repeat the original options if you no longer have it "
                    + "(same --from, plus --max if you set one), e.g.:\n"
                    + "  gog calendar events --from 2026-06-03T15:00:00Z --max 10 --page XYZ\n")
            throw ExitCode(2)
        }
        var comps = URLComponents(string:
            "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        // Default to upcoming events: orderBy=startTime needs a timeMin to mean
        // "from now" rather than from the start of the calendar.
        let timeMin = from ?? ISO8601DateFormatter().string(from: Date())
        var query = [
            URLQueryItem(name: "maxResults", value: String(max)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "timeMin", value: timeMin),
        ]
        if let page { query.append(URLQueryItem(name: "pageToken", value: page)) }
        comps.queryItems = query

        let body = try await GoogleHTTPClient().get(comps.url!)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            // The raw JSON omits the generated timeMin, so a token in it is just
            // as un-spendable as in human mode — echo the replay command too.
            emitNextPageHint(
                (try? JSONDecoder().decode(CalEventList.self, from: body))?.nextPageToken,
                timeMin: timeMin)
            if failEmptyFlag.failEmpty, jsonListingEmpty(from: body, items: \CalEventList.items, token: \CalEventList.nextPageToken) { throw ExitCode(3) }
            return
        }
        let list = try JSONDecoder().decode(CalEventList.self, from: body)
        let items = list.items ?? []
        if items.isEmpty { try emitEmpty("events", failEmpty: failEmptyFlag.failEmpty && list.nextPageToken == nil) }
        for event in items {
            Shell.bashCurrent.stdout(
                "\(event.id ?? "")\t\(event.when)\t\(event.summary ?? "")\n")
        }
        emitNextPageHint(list.nextPageToken, timeMin: timeMin)
    }

    /// Echo a ready-to-run next-page command so a surfaced token is spendable in
    /// either mode. `--page` requires `--from`, and a default run's generated
    /// `timeMin` is in neither the JSON response nor the human output — so print
    /// the effective --from/--max next to the token. stderr keeps --json stdout
    /// pure.
    private func emitNextPageHint(_ token: String?, timeMin: String) {
        guard let token else { return }
        Shell.bashCurrent.stderr(
            "next page token: \(token)\n"
                + "next page: gog calendar events"
                + " --from \(timeMin) --max \(max) --page \(token)\n")
    }
}

/// `gog calendar get <id>` — one event.
struct CalendarGet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Show a calendar event.")

    @Argument(help: "Event ID.") var id: String
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        let url = try googleURL(
            "https://www.googleapis.com/calendar/v3/calendars/primary/events", id: id)
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            return
        }
        let event = try JSONDecoder().decode(CalEvent.self, from: body)
        Shell.bashCurrent.stdout(
            "\(event.id ?? "")\t\(event.when)\t\(event.summary ?? "")\n")
    }
}

/// `gog calendar create --summary … --start … --end …` — create a timed event.
struct CalendarCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a timed event on the primary calendar.")

    @Option(name: .long, help: "Event title.") var summary: String
    @Option(name: .long, help: "Start time (RFC3339, e.g. 2026-06-02T10:00:00Z).")
    var start: String
    @Option(name: .long, help: "End time (RFC3339).") var end: String
    @Flag(name: .long, help: "Build the request but do not create the event.")
    var dryRun: Bool = false
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        struct NewEvent: Encodable {
            struct When: Encodable { let dateTime: String }
            let summary: String
            let start: When
            let end: When
        }
        let payload = try JSONEncoder().encode(NewEvent(
            summary: summary, start: .init(dateTime: start), end: .init(dateTime: end)))
        if dryRun {
            Shell.bashCurrent.stderr("dry-run: not creating\n")
            Shell.bashCurrent.stdout(String(decoding: payload, as: UTF8.self) + "\n")
            return
        }
        let url = URL(string:
            "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        let result = try await GoogleHTTPClient().post(url, jsonBody: payload)
        if json {
            Shell.bashCurrent.stdout(String(decoding: result, as: UTF8.self) + "\n")
            return
        }
        let event = try JSONDecoder().decode(CalEvent.self, from: result)
        Shell.bashCurrent.stdout("created: \(event.id ?? "")\n")
    }
}

/// `gog calendar update <eventId>` — patch summary/start/end on an event.
struct CalendarUpdate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update fields on a calendar event (--dry-run to preview).")

    @Argument(help: "Event ID.") var id: String
    @Option(name: .long, help: "New event title.") var summary: String?
    @Option(name: .long, help: "New start time (RFC3339).") var start: String?
    @Option(name: .long, help: "New end time (RFC3339).") var end: String?
    @Flag(name: .long, help: "Build the request but do not update the event.")
    var dryRun: Bool = false
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        try requireWriteTier(.edit)
        struct EventPatch: Encodable {
            struct When: Encodable { let dateTime: String }
            let summary: String?
            let start: When?
            let end: When?
        }
        // PATCH is a merge — only the provided fields are sent. Require at least
        // one so an empty update can't silently no-op.
        guard summary != nil || start != nil || end != nil else {
            Shell.bashCurrent.stderr(
                "gog: calendar update needs at least one of "
                    + "--summary, --start, --end\n")
            throw ExitCode(2)
        }
        let payload = try JSONEncoder().encode(EventPatch(
            summary: summary,
            start: start.map { EventPatch.When(dateTime: $0) },
            end: end.map { EventPatch.When(dateTime: $0) }))
        if dryRun {
            Shell.bashCurrent.stderr("dry-run: not updating\n")
            Shell.bashCurrent.stdout(String(decoding: payload, as: UTF8.self) + "\n")
            return
        }
        let url = try googleURL(
            "https://www.googleapis.com/calendar/v3/calendars/primary/events", id: id)
        let result = try await GoogleHTTPClient().patch(url, jsonBody: payload)
        if json {
            Shell.bashCurrent.stdout(String(decoding: result, as: UTF8.self) + "\n")
            return
        }
        let event = try JSONDecoder().decode(CalEvent.self, from: result)
        Shell.bashCurrent.stdout("updated: \(event.id ?? id)\n")
    }
}

/// `gog calendar delete <eventId>` — remove an event from the primary calendar.
struct CalendarDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a calendar event (--dry-run to preview).",
        aliases: ["rm"])

    @Argument(help: "Event ID.") var id: String
    @Flag(name: .long, help: "Show what would be deleted without deleting.")
    var dryRun: Bool = false

    func run() async throws {
        try requireWriteTier(.full)
        if dryRun {
            Shell.bashCurrent.stderr("dry-run: not deleting\n")
            Shell.bashCurrent.stdout("would delete: \(id)\n")
            return
        }
        let url = try googleURL(
            "https://www.googleapis.com/calendar/v3/calendars/primary/events", id: id)
        _ = try await GoogleHTTPClient().delete(url)
        Shell.bashCurrent.stdout("deleted: \(id)\n")
    }
}

private struct CalEventList: Decodable {
    let items: [CalEvent]?
    let nextPageToken: String?
}

private struct CalEvent: Decodable {
    struct When: Decodable { let dateTime: String?; let date: String? }
    let id: String?
    let summary: String?
    let start: When?
    let end: When?

    /// Best-effort start label: dateTime, else all-day date, else empty.
    var when: String { start?.dateTime ?? start?.date ?? "" }
}

/// `gog calendar calendars` — the calendars on your calendar list.
struct CalendarCalendars: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calendars",
        abstract: "List the calendars on your calendar list.")

    @Option(name: .long, help: "Maximum calendars to return (1–250).") var max: Int = 100
    @Option(name: .long, help: "Page token from a previous listing.") var page: String?
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false
    @OptionGroup var failEmptyFlag: FailEmptyFlag

    func run() async throws {
        guard max > 0, max <= 250 else {
            Shell.bashCurrent.stderr("gog: --max must be between 1 and 250\n")
            throw ExitCode(2)
        }
        var items = [URLQueryItem(name: "maxResults", value: String(max))]
        if let page { items.append(URLQueryItem(name: "pageToken", value: page)) }
        let url = try googleURL(
            "https://www.googleapis.com/calendar/v3/users/me/calendarList", query: items)
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            if failEmptyFlag.failEmpty, jsonListingEmpty(from: body, items: \CalListResponse.items, token: \CalListResponse.nextPageToken) { throw ExitCode(3) }
            return
        }
        let list = try JSONDecoder().decode(CalListResponse.self, from: body)
        let calendars = list.items ?? []
        if calendars.isEmpty { try emitEmpty("calendars", failEmpty: failEmptyFlag.failEmpty && list.nextPageToken == nil) }
        for cal in calendars {
            let primary = (cal.primary == true) ? "\tprimary" : ""
            Shell.bashCurrent.stdout(
                "\(cal.id ?? "")\t\(tsvEscaped(cal.summary ?? ""))"
                    + "\t\(cal.accessRole ?? "")\(primary)\n")
        }
        if let next = list.nextPageToken {
            Shell.bashCurrent.stderr("next page token: \(next)\n")
        }
    }
}

/// `gog calendar freebusy` — busy intervals across one or more calendars over a
/// time window (defaults to the next 24h on the primary calendar).
struct CalendarFreeBusy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "freebusy",
        abstract: "Show busy intervals across calendars.",
        aliases: ["fb"])

    @Option(name: .long, help: "Window start (RFC3339). Defaults to now.")
    var from: String?
    @Option(name: .long, help: "Window end (RFC3339). Defaults to 24h after start.")
    var to: String?
    @Option(name: .long, help: "Calendar ID to query (repeatable; default 'primary').")
    var calendar: [String] = []
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false
    @OptionGroup var failEmptyFlag: FailEmptyFlag

    func run() async throws {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let timeMin = from ?? formatter.string(from: now)
        // Default the window end to 24h after the *start* (not now), so a future
        // --from with no --to still yields a valid timeMin < timeMax window.
        // --from / --to are passed through verbatim when given; we only need to
        // parse the start to compute the default end (and validate it then).
        let timeMax: String
        if let to {
            timeMax = to
        } else {
            let startDate: Date
            if let from {
                guard let parsed = formatter.date(from: from) else {
                    Shell.bashCurrent.stderr(
                        "gog: --from must be RFC3339, e.g. 2026-06-02T10:00:00Z\n")
                    throw ExitCode(2)
                }
                startDate = parsed
            } else {
                startDate = now
            }
            timeMax = formatter.string(from: startDate.addingTimeInterval(86_400))
        }
        let ids = calendar.isEmpty ? ["primary"] : calendar

        struct Request: Encodable {
            struct Item: Encodable { let id: String }
            let timeMin: String
            let timeMax: String
            let items: [Item]
        }
        let payload = try JSONEncoder().encode(Request(
            timeMin: timeMin, timeMax: timeMax, items: ids.map { .init(id: $0) }))
        let url = try googleURL("https://www.googleapis.com/calendar/v3/freeBusy")
        let result = try await GoogleHTTPClient().post(url, jsonBody: payload)
        if json {
            Shell.bashCurrent.stdout(String(decoding: result, as: UTF8.self) + "\n")
            let decoded = try JSONDecoder().decode(FreeBusyResponse.self, from: result)
            let cals = decoded.calendars ?? [:]
            // A calendar or group that returned errors[] failed to compute — it
            // is not "free". Surface that as a non-zero exit so --fail-empty's
            // exit 3 ("no conflicts") can't mask an unreadable/not-found target.
            let anyErrors = cals.values.contains { !($0.errors ?? []).isEmpty }
                || (decoded.groups ?? [:]).values.contains { !($0.errors ?? []).isEmpty }
            if anyErrors { throw ExitCode(1) }
            if failEmptyFlag.failEmpty,
                !cals.values.contains(where: { !($0.busy ?? []).isEmpty }) {
                throw ExitCode(3)
            }
            return
        }
        let response = try JSONDecoder().decode(FreeBusyResponse.self, from: result)
        let calendars = response.calendars ?? [:]
        var anyBusy = false
        var anyErrors = false
        // Group-expansion failures (groups.<id>.errors[]) are lookup failures too,
        // and a failed group contributes no `calendars` entry — check it first.
        for id in (response.groups ?? [:]).keys.sorted() {
            guard let errors = response.groups?[id]?.errors, !errors.isEmpty else { continue }
            anyErrors = true
            let reasons = errors.compactMap(\.reason).joined(separator: ",")
            Shell.bashCurrent.stderr("gog: \(id): \(reasons)\n")
        }
        // Iterate the returned keys in a stable (sorted) order.
        for id in calendars.keys.sorted() {
            guard let cal = calendars[id] else { continue }
            if let errors = cal.errors, !errors.isEmpty {
                anyErrors = true
                let reasons = errors.compactMap(\.reason).joined(separator: ",")
                Shell.bashCurrent.stderr("gog: \(id): \(reasons)\n")
            }
            for slot in cal.busy ?? [] {
                anyBusy = true
                Shell.bashCurrent.stdout(
                    "\(id)\t\(slot.start ?? "")\t\(slot.end ?? "")\n")
            }
        }
        // A calendar or group that returned errors[] failed to compute — it is
        // not "free". Exit non-zero (reasons already on stderr) rather than
        // letting an empty or --fail-empty result read as "no conflicts".
        if anyErrors { throw ExitCode(1) }
        if !anyBusy { try emitEmpty("busy intervals", failEmpty: failEmptyFlag.failEmpty) }
    }
}

private struct CalListResponse: Decodable {
    struct Entry: Decodable {
        let id: String?
        let summary: String?
        let accessRole: String?
        let primary: Bool?
    }
    let items: [Entry]?
    let nextPageToken: String?
}
private struct FreeBusyResponse: Decodable {
    struct Err: Decodable { let reason: String? }
    struct Cal: Decodable {
        struct Slot: Decodable { let start: String?; let end: String? }
        let busy: [Slot]?
        let errors: [Err]?
    }
    // A queried Google Group is reported under `groups`; errors[] there means
    // expansion failed (and the group contributes no `calendars` entry).
    struct Group: Decodable { let errors: [Err]? }
    let calendars: [String: Cal]?
    let groups: [String: Group]?
}

// MARK: - Contacts (People API connections)

/// `gog contacts …` — Google Contacts via the People API.
struct GogContacts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "contacts",
        abstract: "Google Contacts.",
        subcommands: [
            ContactsList.self, ContactsGet.self,
            ContactsSearch.self, ContactsOther.self,
            ContactsCreate.self, ContactsUpdate.self, ContactsDelete.self,
        ],
        aliases: ["contact"])
}

/// `gog contacts list` — your connections.
struct ContactsList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List your contacts.")

    @Option(name: .long, help: "Maximum contacts to return (1–1000).")
    var max: Int = 100
    @Option(name: .long, help: "Page token from a previous listing.")
    var page: String?
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false
    @OptionGroup var failEmptyFlag: FailEmptyFlag

    func run() async throws {
        guard max > 0, max <= 1000 else {
            Shell.bashCurrent.stderr("gog: --max must be between 1 and 1000\n")
            throw ExitCode(2)
        }
        var query = [
            URLQueryItem(name: "personFields", value: "names,emailAddresses"),
            URLQueryItem(name: "pageSize", value: String(max)),
        ]
        if let page { query.append(URLQueryItem(name: "pageToken", value: page)) }
        let url = try googleURL(
            "https://people.googleapis.com/v1/people/me/connections",
            query: query)
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            if failEmptyFlag.failEmpty, jsonListingEmpty(from: body, items: \ContactList.connections, token: \ContactList.nextPageToken) { throw ExitCode(3) }
            return
        }
        let list = try JSONDecoder().decode(ContactList.self, from: body)
        let people = list.connections ?? []
        if people.isEmpty { try emitEmpty("contacts", failEmpty: failEmptyFlag.failEmpty && list.nextPageToken == nil) }
        for person in people {
            let name = person.names?.first?.displayName ?? ""
            let email = person.emailAddresses?.first?.value ?? ""
            Shell.bashCurrent.stdout("\(person.resourceName ?? "")\t\(name)\t\(email)\n")
        }
        if let next = list.nextPageToken {
            Shell.bashCurrent.stderr("next page token: \(next)\n")
        }
    }
}

/// `gog contacts get <resourceName>` — one contact (e.g. `people/c123`).
struct ContactsGet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Show a contact by resource name (e.g. people/c123).")

    @Argument(help: "Contact resource name, e.g. people/c123.")
    var resourceName: String
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        // `.urlPathAllowed` keeps the `/` in `people/c123` while still escaping
        // anything unsafe.
        let url = try googleURL(
            "https://people.googleapis.com/v1", id: resourceName,
            query: [URLQueryItem(name: "personFields", value: "names,emailAddresses")])
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            return
        }
        let person = try JSONDecoder().decode(Contact.self, from: body)
        let name = person.names?.first?.displayName ?? "(unknown)"
        let email = person.emailAddresses?.first?.value ?? ""
        Shell.bashCurrent.stdout("\(name)\(email.isEmpty ? "" : " <\(email)>")\n")
    }
}

private struct ContactList: Decodable {
    let connections: [Contact]?
    let nextPageToken: String?
}

private struct Contact: Decodable {
    struct Name: Decodable { let displayName: String? }
    struct Email: Decodable { let value: String? }
    let resourceName: String?
    let names: [Name]?
    let emailAddresses: [Email]?
}

/// The writable subset of a People `Person`. `updateContact` rejects a write
/// that doesn't echo back the contact's current `etag` *and* `metadata.sources`
/// (mirrors gogcli, which reads the person then sends it straight back), so both
/// ride along; all optionals are omitted when nil, so the same type serves
/// create (neither) and update (both + only the changed fields).
private struct ContactWrite: Encodable {
    struct Name: Encodable { let givenName: String?; let familyName: String? }
    struct Value: Encodable { let value: String }
    let etag: String?
    let metadata: ContactMetadata?
    let names: [Name]?
    let emailAddresses: [Value]?
    let phoneNumbers: [Value]?
}

/// A contact's source metadata: read from `people.get` and echoed back on
/// `updateContact` (the API 400s without it). `Codable` so it round-trips.
private struct ContactMetadata: Codable {
    struct Source: Codable { let type: String?; let id: String?; let etag: String? }
    let sources: [Source]?
}
private struct ContactReadback: Decodable {
    struct Name: Decodable { let givenName: String?; let familyName: String? }
    let etag: String?
    let metadata: ContactMetadata?
    let names: [Name]?
}

/// `gog contacts create --given … [--family …] [--email …] [--phone …]` — create
/// a contact. Names are structured (given/family), matching gogcli.
struct ContactsCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a contact (--dry-run to preview).")

    @Option(name: .long, help: "Given (first) name. Required.") var given: String?
    @Option(name: .long, help: "Family (last) name.") var family: String?
    @Option(name: .long, help: "Email address (repeatable).") var email: [String] = []
    @Option(name: .long, help: "Phone number (repeatable).") var phone: [String] = []
    @Flag(name: .long, help: "Build the request but do not create.")
    var dryRun: Bool = false
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        try requireWriteTier(.edit)
        let givenName = (given ?? "").trimmingCharacters(in: .whitespaces)
        guard !givenName.isEmpty else {
            Shell.bashCurrent.stderr("gog: contacts create requires --given\n")
            throw ExitCode(2)
        }
        let payload = try JSONEncoder().encode(ContactWrite(
            etag: nil,
            metadata: nil,
            names: [ContactWrite.Name(
                givenName: givenName,
                familyName: family?.trimmingCharacters(in: .whitespaces))],
            emailAddresses: email.isEmpty
                ? nil : email.map { ContactWrite.Value(value: $0) },
            phoneNumbers: phone.isEmpty
                ? nil : phone.map { ContactWrite.Value(value: $0) }))
        if dryRun {
            Shell.bashCurrent.stderr("dry-run: not creating\n")
            Shell.bashCurrent.stdout(String(decoding: payload, as: UTF8.self) + "\n")
            return
        }
        // createContact takes no personFields (gogcli omits it; it isn't required).
        let url = URL(string:
            "https://people.googleapis.com/v1/people:createContact")!
        let result = try await GoogleHTTPClient().post(url, jsonBody: payload)
        if json {
            Shell.bashCurrent.stdout(String(decoding: result, as: UTF8.self) + "\n")
            return
        }
        let person = try JSONDecoder().decode(Contact.self, from: result)
        Shell.bashCurrent.stdout("created: \(person.resourceName ?? "")\n")
    }
}

/// `gog contacts update <resourceName> …` — replace a contact's name/emails/
/// phones. People's `updateContact` requires the current etag *and*
/// metadata.sources, so we read the person first, then PATCH it back with only
/// the fields named on the command line.
struct ContactsUpdate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update a contact's fields (--dry-run to preview).")

    @Argument(help: "Contact resource name, e.g. people/c123.")
    var resourceName: String
    @Option(name: .long, help: "New given (first) name.") var given: String?
    @Option(name: .long, help: "New family (last) name.") var family: String?
    @Option(name: .long, help: "Replace emails (repeatable).") var email: [String] = []
    @Option(name: .long, help: "Replace phone numbers (repeatable).")
    var phone: [String] = []
    @Flag(name: .long, help: "Build the request but do not update.")
    var dryRun: Bool = false
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        try requireWriteTier(.edit)
        let updatingName = given != nil || family != nil
        var fields: [String] = []
        if updatingName { fields.append("names") }
        if !email.isEmpty { fields.append("emailAddresses") }
        if !phone.isEmpty { fields.append("phoneNumbers") }
        guard !fields.isEmpty else {
            Shell.bashCurrent.stderr(
                "gog: contacts update needs at least one of "
                    + "--given, --family, --email, --phone\n")
            throw ExitCode(2)
        }
        if dryRun {
            Shell.bashCurrent.stderr("dry-run: not updating\n")
            Shell.bashCurrent.stdout(
                "would update \(resourceName): \(fields.joined(separator: ","))\n")
            return
        }
        // updateContact rejects a write that doesn't carry the contact's current
        // etag AND metadata.sources, so read both (like gogcli's read-modify-
        // write) and send them back with only the changed fields.
        let getURL = try googleURL(
            "https://people.googleapis.com/v1", id: resourceName,
            query: [URLQueryItem(
                name: "personFields",
                value: fields.joined(separator: ",") + ",metadata")])
        let current = try JSONDecoder().decode(
            ContactReadback.self, from: try await GoogleHTTPClient().get(getURL))
        // Override only the provided name part, preserving the other (gogcli).
        let names: [ContactWrite.Name]?
        if updatingName {
            let cur = current.names?.first
            names = [ContactWrite.Name(
                givenName: given?.trimmingCharacters(in: .whitespaces) ?? cur?.givenName,
                familyName: family?.trimmingCharacters(in: .whitespaces) ?? cur?.familyName)]
        } else {
            names = nil
        }
        let payload = try JSONEncoder().encode(ContactWrite(
            etag: current.etag,
            metadata: current.metadata,
            names: names,
            emailAddresses: email.isEmpty
                ? nil : email.map { ContactWrite.Value(value: $0) },
            phoneNumbers: phone.isEmpty
                ? nil : phone.map { ContactWrite.Value(value: $0) }))
        let url = try googleURL(
            "https://people.googleapis.com/v1",
            id: "\(resourceName):updateContact",
            query: [URLQueryItem(name: "updatePersonFields",
                                 value: fields.joined(separator: ","))])
        let result = try await GoogleHTTPClient().patch(url, jsonBody: payload)
        if json {
            Shell.bashCurrent.stdout(String(decoding: result, as: UTF8.self) + "\n")
            return
        }
        let person = try JSONDecoder().decode(Contact.self, from: result)
        Shell.bashCurrent.stdout("updated: \(person.resourceName ?? resourceName)\n")
    }
}

/// `gog contacts delete <resourceName>` — delete a contact.
struct ContactsDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a contact (--dry-run to preview).",
        aliases: ["rm"])

    @Argument(help: "Contact resource name, e.g. people/c123.")
    var resourceName: String
    @Flag(name: .long, help: "Show what would be deleted without deleting.")
    var dryRun: Bool = false

    func run() async throws {
        try requireWriteTier(.full)
        if dryRun {
            Shell.bashCurrent.stderr("dry-run: not deleting\n")
            Shell.bashCurrent.stdout("would delete: \(resourceName)\n")
            return
        }
        let url = try googleURL(
            "https://people.googleapis.com/v1",
            id: "\(resourceName):deleteContact")
        _ = try await GoogleHTTPClient().delete(url)
        Shell.bashCurrent.stdout("deleted: \(resourceName)\n")
    }
}

/// `gog contacts search <query>` — search your contacts (People searchContacts).
struct ContactsSearch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search your contacts by name, email, etc.",
        aliases: ["find"])

    @Argument(help: "Search text (matches names, emails, phone numbers, …).")
    var query: String
    @Option(name: .long, help: "Maximum results to return (1–30).") var max: Int = 10
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false
    @OptionGroup var failEmptyFlag: FailEmptyFlag

    func run() async throws {
        // searchContacts caps pageSize at 30 and does not use page tokens.
        guard max > 0, max <= 30 else {
            Shell.bashCurrent.stderr("gog: --max must be between 1 and 30\n")
            throw ExitCode(2)
        }
        let client = GoogleHTTPClient()
        // Google's searchContacts wants a warmup request with an empty query to
        // refresh its server-side cache before the real search; without it,
        // recently added/changed contacts can be missing. Issue it, discard.
        let warmup = try googleURL(
            "https://people.googleapis.com/v1/people:searchContacts",
            query: [
                URLQueryItem(name: "query", value: ""),
                URLQueryItem(name: "readMask", value: "names,emailAddresses"),
            ])
        _ = try await client.get(warmup)
        let url = try googleURL(
            "https://people.googleapis.com/v1/people:searchContacts",
            query: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "readMask", value: "names,emailAddresses"),
                URLQueryItem(name: "pageSize", value: String(max)),
            ])
        let body = try await client.get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            if failEmptyFlag.failEmpty, jsonListingEmpty(from: body, items: \ContactSearchResults.results) { throw ExitCode(3) }
            return
        }
        let response = try JSONDecoder().decode(ContactSearchResults.self, from: body)
        let results = response.results ?? []
        if results.isEmpty { try emitEmpty("matches", failEmpty: failEmptyFlag.failEmpty) }
        for person in results.compactMap(\.person) {
            let name = person.names?.first?.displayName ?? ""
            let email = person.emailAddresses?.first?.value ?? ""
            Shell.bashCurrent.stdout(
                "\(person.resourceName ?? "")\t\(tsvEscaped(name))\t\(email)\n")
        }
    }
}

/// `gog contacts other` — auto-saved "other contacts" (people you've corresponded
/// with who aren't in My Contacts).
struct ContactsOther: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "other",
        abstract: "List auto-saved 'other contacts'.")

    @Option(name: .long, help: "Maximum contacts to return (1–1000).") var max: Int = 100
    @Option(name: .long, help: "Page token from a previous listing.") var page: String?
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false
    @OptionGroup var failEmptyFlag: FailEmptyFlag

    func run() async throws {
        guard max > 0, max <= 1000 else {
            Shell.bashCurrent.stderr("gog: --max must be between 1 and 1000\n")
            throw ExitCode(2)
        }
        var items = [
            URLQueryItem(name: "readMask", value: "names,emailAddresses"),
            URLQueryItem(name: "pageSize", value: String(max)),
        ]
        if let page { items.append(URLQueryItem(name: "pageToken", value: page)) }
        let url = try googleURL(
            "https://people.googleapis.com/v1/otherContacts", query: items)
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            if failEmptyFlag.failEmpty, jsonListingEmpty(from: body, items: \OtherContactList.otherContacts, token: \OtherContactList.nextPageToken) { throw ExitCode(3) }
            return
        }
        let list = try JSONDecoder().decode(OtherContactList.self, from: body)
        let people = list.otherContacts ?? []
        if people.isEmpty { try emitEmpty("other contacts", failEmpty: failEmptyFlag.failEmpty && list.nextPageToken == nil) }
        for person in people {
            let name = person.names?.first?.displayName ?? ""
            let email = person.emailAddresses?.first?.value ?? ""
            Shell.bashCurrent.stdout(
                "\(person.resourceName ?? "")\t\(tsvEscaped(name))\t\(email)\n")
        }
        if let next = list.nextPageToken {
            Shell.bashCurrent.stderr("next page token: \(next)\n")
        }
    }
}

private struct ContactSearchResults: Decodable {
    struct Result: Decodable { let person: Contact? }
    let results: [Result]?
}
private struct OtherContactList: Decodable {
    let otherContacts: [Contact]?
    let nextPageToken: String?
}

// MARK: - Tasks

/// `gog tasks …` — Google Tasks.
struct GogTasks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tasks",
        abstract: "Google Tasks.",
        subcommands: [
            TasksLists.self, TasksList.self, TasksAdd.self,
            TasksComplete.self, TasksDelete.self,
        ],
        aliases: ["task"])
}

/// `gog tasks lists` — your task lists.
struct TasksLists: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lists",
        abstract: "List your task lists.")

    @Option(name: .long, help: "Maximum task lists to return (1–1000).")
    var max: Int = 100
    @Option(name: .long, help: "Page token from a previous listing.")
    var page: String?
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false
    @OptionGroup var failEmptyFlag: FailEmptyFlag

    func run() async throws {
        guard max > 0, max <= 1000 else {
            Shell.bashCurrent.stderr("gog: --max must be between 1 and 1000\n")
            throw ExitCode(2)
        }
        var query = [URLQueryItem(name: "maxResults", value: String(max))]
        if let page { query.append(URLQueryItem(name: "pageToken", value: page)) }
        let url = try googleURL(
            "https://tasks.googleapis.com/tasks/v1/users/@me/lists", query: query)
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            if failEmptyFlag.failEmpty, jsonListingEmpty(from: body, items: \TaskListCollection.items, token: \TaskListCollection.nextPageToken) { throw ExitCode(3) }
            return
        }
        let result = try JSONDecoder().decode(TaskListCollection.self, from: body)
        let lists = result.items ?? []
        if lists.isEmpty { try emitEmpty("task lists", failEmpty: failEmptyFlag.failEmpty && result.nextPageToken == nil) }
        for list in lists {
            Shell.bashCurrent.stdout("\(list.id ?? "")\t\(list.title ?? "")\n")
        }
        if let next = result.nextPageToken {
            Shell.bashCurrent.stderr("next page token: \(next)\n")
        }
    }
}

/// `gog tasks list` — tasks within a list (default `@default`).
struct TasksList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List tasks in a task list.")

    @Option(name: .long, help: "Task list ID (default: @default).")
    var list: String = "@default"
    @Option(name: .long, help: "Maximum tasks to return (1–100).")
    var max: Int = 100
    @Option(name: .long, help: "Page token from a previous listing.")
    var page: String?
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false
    @OptionGroup var failEmptyFlag: FailEmptyFlag

    func run() async throws {
        guard max > 0, max <= 100 else {
            Shell.bashCurrent.stderr("gog: --max must be between 1 and 100\n")
            throw ExitCode(2)
        }
        var query = [URLQueryItem(name: "maxResults", value: String(max))]
        if let page { query.append(URLQueryItem(name: "pageToken", value: page)) }
        let url = try googleURL(
            "https://tasks.googleapis.com/tasks/v1/lists", id: "\(list)/tasks",
            query: query)
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            if failEmptyFlag.failEmpty, jsonListingEmpty(from: body, items: \TaskCollection.items, token: \TaskCollection.nextPageToken) { throw ExitCode(3) }
            return
        }
        let result = try JSONDecoder().decode(TaskCollection.self, from: body)
        let tasks = result.items ?? []
        if tasks.isEmpty { try emitEmpty("tasks", failEmpty: failEmptyFlag.failEmpty && result.nextPageToken == nil) }
        for task in tasks {
            Shell.bashCurrent.stdout("\(task.id ?? "")\t\(task.status ?? "")\t\(task.title ?? "")\n")
        }
        if let next = result.nextPageToken {
            Shell.bashCurrent.stderr("next page token: \(next)\n")
        }
    }
}

/// `gog tasks add <title>` — add a task to a list (default `@default`).
struct TasksAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a task to a task list.")

    @Argument(help: "Task title.") var title: String
    @Option(name: .long, help: "Task list ID (default: @default).")
    var list: String = "@default"
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        let payload = try JSONEncoder().encode(["title": title])
        let url = try googleURL(
            "https://tasks.googleapis.com/tasks/v1/lists", id: "\(list)/tasks")
        let result = try await GoogleHTTPClient().post(url, jsonBody: payload)
        if json {
            Shell.bashCurrent.stdout(String(decoding: result, as: UTF8.self) + "\n")
            return
        }
        let task = try JSONDecoder().decode(TaskItem.self, from: result)
        Shell.bashCurrent.stdout("added: \(task.id ?? "")\n")
    }
}

/// `gog tasks complete <taskId>` — mark a task completed.
struct TasksComplete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "complete",
        abstract: "Mark a task completed (--dry-run to preview).",
        aliases: ["done"])

    @Argument(help: "Task ID.") var task: String
    @Option(name: .long, help: "Task list ID (default: @default).")
    var list: String = "@default"
    @Flag(name: .long, help: "Show what would change without writing.")
    var dryRun: Bool = false
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        try requireWriteTier(.edit)
        // Setting status=completed; Google fills in the `completed` timestamp.
        let payload = try JSONEncoder().encode(["status": "completed"])
        if dryRun {
            Shell.bashCurrent.stderr("dry-run: not completing\n")
            Shell.bashCurrent.stdout("would complete: \(task)\n")
            return
        }
        let url = try googleURL(
            "https://tasks.googleapis.com/tasks/v1/lists",
            id: "\(list)/tasks/\(task)")
        let result = try await GoogleHTTPClient().patch(url, jsonBody: payload)
        if json {
            Shell.bashCurrent.stdout(String(decoding: result, as: UTF8.self) + "\n")
            return
        }
        let item = try JSONDecoder().decode(TaskItem.self, from: result)
        Shell.bashCurrent.stdout("completed: \(item.id ?? task)\n")
    }
}

/// `gog tasks delete <taskId>` — remove a task from a list.
struct TasksDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a task (--dry-run to preview).",
        aliases: ["rm"])

    @Argument(help: "Task ID.") var task: String
    @Option(name: .long, help: "Task list ID (default: @default).")
    var list: String = "@default"
    @Flag(name: .long, help: "Show what would be deleted without deleting.")
    var dryRun: Bool = false

    func run() async throws {
        try requireWriteTier(.full)
        if dryRun {
            Shell.bashCurrent.stderr("dry-run: not deleting\n")
            Shell.bashCurrent.stdout("would delete: \(task)\n")
            return
        }
        let url = try googleURL(
            "https://tasks.googleapis.com/tasks/v1/lists",
            id: "\(list)/tasks/\(task)")
        _ = try await GoogleHTTPClient().delete(url)
        Shell.bashCurrent.stdout("deleted: \(task)\n")
    }
}

private struct TaskListCollection: Decodable {
    struct Item: Decodable { let id: String?; let title: String? }
    let items: [Item]?
    let nextPageToken: String?
}

private struct TaskCollection: Decodable {
    let items: [TaskItem]?
    let nextPageToken: String?
}

private struct TaskItem: Decodable {
    let id: String?
    let title: String?
    let status: String?
}

// MARK: - Docs (export via Drive)

/// `gog docs …` — Google Docs, read by exporting through Drive.
struct GogDocs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "docs",
        abstract: "Google Docs (export via Drive).",
        subcommands: [DocsCat.self],
        aliases: ["doc"])
}

/// `gog docs cat <documentId>` — export a Doc's contents as text or markdown.
struct DocsCat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cat",
        abstract: "Export a Doc's contents (via Drive export).")

    @Argument(help: "Document ID.") var documentId: String
    @Option(name: .long, help: "Export format: text or markdown.")
    var format: String = "text"
    @Option(name: [.customShort("o"), .long],
            help: "Write to a sandbox path instead of stdout.")
    var out: String?

    func run() async throws {
        let mimeType: String
        switch format {
        case "text": mimeType = "text/plain"
        case "markdown", "md": mimeType = "text/markdown"
        default:
            Shell.bashCurrent.stderr("gog: --format must be text or markdown\n")
            throw ExitCode(2)
        }
        let url = try googleURL(
            "https://www.googleapis.com/drive/v3/files",
            id: "\(documentId)/export",
            query: [URLQueryItem(name: "mimeType", value: mimeType)])
        guard let out else {
            let data = try await GoogleHTTPClient().get(url)
            Shell.bashCurrent.stdout(String(decoding: data, as: UTF8.self))
            return
        }
        // Validate the destination (non-destructively) before exporting,
        // mirroring drive download.
        let path = Shell.bashCurrent.resolvePath(out)
        try await ensureWritableDestination(path, label: out)
        let data = try await GoogleHTTPClient().get(url)
        do {
            try await Shell.bashCurrent.fileSystem.writeData(data, to: path, append: false)
        } catch {
            Shell.bashCurrent.stderr("gog: cannot write \(out): \(error)\n")
            throw ExitCode(23)
        }
        Shell.bashCurrent.stderr("wrote \(data.count) bytes to \(out)\n")
    }
}

// MARK: - Sheets

/// `gog sheets …` — Google Sheets cell values.
struct GogSheets: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sheets",
        abstract: "Google Sheets.",
        subcommands: [
            SheetsGet.self, SheetsUpdate.self, SheetsAppend.self, SheetsClear.self,
        ],
        aliases: ["sheet"])
}

/// Build the Sheets `…/{id}/values/{range}` URL, percent-encoding the
/// spreadsheet id and range as single path segments — so a `/` in a sheet name
/// becomes %2F rather than a path separator that would break the request.
private func sheetsValuesURL(spreadsheetId: String, range: String,
                             query: [URLQueryItem] = []) throws -> URL {
    return try googleURL(
        "https://sheets.googleapis.com/v4/spreadsheets/\(pathSegment(spreadsheetId))"
            + "/values/\(pathSegment(range))",
        query: query)
}

/// Column count for an A1 range like "Sheet1!A1:C10" → 3, or nil for a single
/// cell or an unbounded range (where padding can't be inferred).
private func sheetsRangeDimensions(_ range: String?) -> (rows: Int?, cols: Int?)? {
    guard let range else { return nil }
    let a1 = range.split(separator: "!").last.map(String.init) ?? range
    let bounds = a1.split(separator: ":", maxSplits: 1).map(String.init)
    guard bounds.count == 2 else { return nil }
    func columnIndex(_ cell: String) -> Int? {
        let letters = cell.prefix { $0.isLetter }.uppercased()
        guard !letters.isEmpty else { return nil }
        var index = 0
        for ch in letters {
            guard let v = ch.asciiValue, (65...90).contains(v) else { return nil }
            index = index * 26 + Int(v - 64)
        }
        return index
    }
    func rowNumber(_ cell: String) -> Int? { Int(cell.drop { $0.isLetter }) }
    let cols: Int? = {
        guard let s = columnIndex(bounds[0]), let e = columnIndex(bounds[1]) else { return nil }
        return max(1, e - s + 1)
    }()
    let rows: Int? = {
        guard let s = rowNumber(bounds[0]), let e = rowNumber(bounds[1]) else { return nil }
        return max(1, e - s + 1)
    }()
    return (rows: rows, cols: cols)
}

/// Non-destructive writability check for a destination: confirms the parent
/// directory is reachable inside a mount (so out-of-mount paths fail closed
/// before any network fetch) without creating or deleting any files — avoids
/// clobbering an unrelated sibling that a fixed probe name might collide with.
private func ensureWritableDestination(_ resolvedPath: String, label: String) async throws {
    let parent = (resolvedPath as NSString).deletingLastPathComponent
    let directory = parent.isEmpty ? "/" : parent
    let metadata = (try? await Shell.bashCurrent.fileSystem.metadata(directory)).flatMap { $0 }
    if metadata == nil {
        Shell.bashCurrent.stderr(
            "gog: cannot write \(label): no such directory in the sandbox\n")
        throw ExitCode(23)
    }
}

/// `gog sheets get <spreadsheetId> <range>` — read a range of values.
struct SheetsGet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Read cell values from an A1 range.")

    @Argument(help: "Spreadsheet ID.") var spreadsheetId: String
    @Argument(help: "A1 range, e.g. Sheet1!A1:D20.") var range: String
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false
    @OptionGroup var failEmptyFlag: FailEmptyFlag

    func run() async throws {
        let url = try sheetsValuesURL(spreadsheetId: spreadsheetId, range: range)
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            if failEmptyFlag.failEmpty, jsonListingEmpty(from: body, items: \ValueRange.values) { throw ExitCode(3) }
            return
        }
        let result = try JSONDecoder().decode(ValueRange.self, from: body)
        let rows = result.values ?? []
        if rows.isEmpty {
            try emitEmpty("values", failEmpty: failEmptyFlag.failEmpty)
            return
        }
        // Sheets omits trailing empty rows/columns; pad to the requested range
        // dimensions (or the widest returned row) so the TSV keeps a consistent
        // shape. (`--json` stays lossless.)
        let dimensions = sheetsRangeDimensions(result.range)
        let width = dimensions?.cols ?? (rows.map(\.count).max() ?? 0)
        let height = max(dimensions?.rows ?? rows.count, rows.count)
        for index in 0..<height {
            // Escape delimiters so a cell containing a tab/newline can't break
            // the one-row-per-record TSV shape.
            var cells = (index < rows.count ? rows[index] : []).map { tsvEscaped($0.text) }
            while cells.count < width { cells.append("") }
            Shell.bashCurrent.stdout(cells.joined(separator: "\t") + "\n")
        }
    }
}

/// `gog sheets update <spreadsheetId> <range> --values-json …` — write values.
struct SheetsUpdate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Write values to an A1 range.")

    @Argument(help: "Spreadsheet ID.") var spreadsheetId: String
    @Argument(help: "A1 range, e.g. Sheet1!A1.") var range: String
    @Option(name: .long, help: #"Values as JSON rows, e.g. '[["a","b"],["c"]]'."#)
    var valuesJson: String
    @Flag(name: .long, help: "Build the request but do not write.")
    var dryRun: Bool = false
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        guard let valuesData = valuesJson.data(using: .utf8),
              let values = try? JSONDecoder().decode([[CellValue]].self, from: valuesData)
        else {
            Shell.bashCurrent.stderr(
                #"gog: --values-json must be a JSON array of rows, e.g. '[["a","b"]]'"# + "\n")
            throw ExitCode(2)
        }
        struct UpdateBody: Encodable { let values: [[CellValue]] }
        let payload = try JSONEncoder().encode(UpdateBody(values: values))
        if dryRun {
            Shell.bashCurrent.stderr("dry-run: not writing\n")
            Shell.bashCurrent.stdout(String(decoding: payload, as: UTF8.self) + "\n")
            return
        }
        let url = try sheetsValuesURL(
            spreadsheetId: spreadsheetId, range: range,
            query: [URLQueryItem(name: "valueInputOption", value: "USER_ENTERED")])
        let result = try await GoogleHTTPClient().put(url, jsonBody: payload)
        if json {
            Shell.bashCurrent.stdout(String(decoding: result, as: UTF8.self) + "\n")
            return
        }
        let updated = try JSONDecoder().decode(UpdateResult.self, from: result)
        Shell.bashCurrent.stdout("updated \(updated.updatedCells ?? 0) cells\n")
    }
}

/// `gog sheets append <id> <range> --values-json …` — append rows after the
/// table that overlaps the range (Sheets `values.append`).
struct SheetsAppend: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "append",
        abstract: "Append rows after a range's table (--dry-run to preview).")

    @Argument(help: "Spreadsheet ID.") var spreadsheetId: String
    @Argument(help: "A1 range locating the table, e.g. Sheet1!A1.") var range: String
    @Option(name: .long, help: #"Values as JSON rows, e.g. '[["a","b"],["c"]]'."#)
    var valuesJson: String
    @Flag(name: .long, help: "Build the request but do not append.")
    var dryRun: Bool = false
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        try requireWriteTier(.edit)
        guard let valuesData = valuesJson.data(using: .utf8),
              let values = try? JSONDecoder().decode([[CellValue]].self, from: valuesData)
        else {
            Shell.bashCurrent.stderr(
                #"gog: --values-json must be a JSON array of rows, e.g. '[["a","b"]]'"#
                    + "\n")
            throw ExitCode(2)
        }
        struct AppendBody: Encodable { let values: [[CellValue]] }
        let payload = try JSONEncoder().encode(AppendBody(values: values))
        if dryRun {
            Shell.bashCurrent.stderr("dry-run: not appending\n")
            Shell.bashCurrent.stdout(String(decoding: payload, as: UTF8.self) + "\n")
            return
        }
        // values.append is a custom method: the ":append" suffix sits after the
        // (percent-encoded) range in the path. USER_ENTERED matches `update`.
        let url = try googleURL(
            "https://sheets.googleapis.com/v4/spreadsheets/\(pathSegment(spreadsheetId))"
                + "/values/\(pathSegment(range)):append",
            query: [
                URLQueryItem(name: "valueInputOption", value: "USER_ENTERED"),
                URLQueryItem(name: "insertDataOption", value: "INSERT_ROWS"),
            ])
        let result = try await GoogleHTTPClient().post(url, jsonBody: payload)
        if json {
            Shell.bashCurrent.stdout(String(decoding: result, as: UTF8.self) + "\n")
            return
        }
        let res = try JSONDecoder().decode(AppendResult.self, from: result)
        Shell.bashCurrent.stdout("appended: \(res.updates?.updatedRange ?? range)\n")
    }
}

/// `gog sheets clear <id> <range>` — clear a range's values (keeps formatting).
struct SheetsClear: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Clear values from an A1 range (--dry-run to preview).")

    @Argument(help: "Spreadsheet ID.") var spreadsheetId: String
    @Argument(help: "A1 range, e.g. Sheet1!A1:D20.") var range: String
    @Flag(name: .long, help: "Show what would be cleared without clearing.")
    var dryRun: Bool = false
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        try requireWriteTier(.full)
        if dryRun {
            Shell.bashCurrent.stderr("dry-run: not clearing\n")
            Shell.bashCurrent.stdout("would clear: \(range)\n")
            return
        }
        let url = try googleURL(
            "https://sheets.googleapis.com/v4/spreadsheets/\(pathSegment(spreadsheetId))"
                + "/values/\(pathSegment(range)):clear")
        let result = try await GoogleHTTPClient().post(url, jsonBody: Data("{}".utf8))
        if json {
            Shell.bashCurrent.stdout(String(decoding: result, as: UTF8.self) + "\n")
            return
        }
        let res = try JSONDecoder().decode(ClearResult.self, from: result)
        Shell.bashCurrent.stdout("cleared: \(res.clearedRange ?? range)\n")
    }
}

private struct AppendResult: Decodable {
    struct Updates: Decodable { let updatedRange: String?; let updatedCells: Int? }
    let updates: Updates?
}
private struct ClearResult: Decodable { let clearedRange: String? }

/// A spreadsheet cell value — string, number, bool, or empty — so mixed-type
/// ranges decode and round-trip through `--values-json` cleanly.
private enum CellValue: Codable {
    case string(String), int(Int), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)            // exact: avoids Double rounding of large ints
        } else if let n = try? container.decode(Double.self) {
            // Reject integers beyond exact Double range — they'd round silently;
            // such values must be quoted as strings.
            if n.rounded() == n, abs(n) >= 0x1p53 {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Number too large for exact representation; quote it as a string")
            }
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else {
            // Reject objects/arrays rather than silently storing "" (which on
            // update would clear the cell).
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported cell value (expected string, number, bool, or null)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .null:
            // Sheets' values.update skips JSON null (leaving the old cell
            // value), so encode an empty cell as "" to actually clear it.
            try container.encode("")
        }
    }

    var text: String {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .number(let n): return String(n)
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .null: return ""
        }
    }
}

private struct ValueRange: Decodable {
    let range: String?
    let values: [[CellValue]]?
}

private struct UpdateResult: Decodable {
    let updatedCells: Int?
    let updatedRange: String?
}

/// Escape TSV delimiters (`\`, tab, CR, LF) so a value can't break the
/// one-record-per-line shape.
private func tsvEscaped(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\t", with: "\\t")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
}

// MARK: - Slides (export via Drive)

/// `gog slides …` — Google Slides, exported through Drive.
struct GogSlides: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "slides",
        abstract: "Google Slides (export via Drive).",
        subcommands: [SlidesExport.self],
        aliases: ["slide"])
}

/// `gog slides export <id> --out <path>` — export a presentation (PDF by
/// default) into the sandbox.
struct SlidesExport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export a presentation to a sandbox path.")

    @Argument(help: "Presentation ID.") var presentationId: String
    @Option(name: .long, help: "Export MIME type (default application/pdf).")
    var mime: String = "application/pdf"
    @Option(name: [.customShort("o"), .long],
            help: "Destination path inside the sandbox.")
    var out: String

    func run() async throws {
        let url = try googleURL(
            "https://www.googleapis.com/drive/v3/files",
            id: "\(presentationId)/export",
            query: [URLQueryItem(name: "mimeType", value: mime)])
        let resolved = Shell.bashCurrent.resolvePath(out)
        try await ensureWritableDestination(resolved, label: out)
        let data = try await GoogleHTTPClient().get(url)
        do {
            try await Shell.bashCurrent.fileSystem.writeData(data, to: resolved, append: false)
        } catch {
            Shell.bashCurrent.stderr("gog: cannot write \(out): \(error)\n")
            throw ExitCode(23)
        }
        Shell.bashCurrent.stderr("wrote \(data.count) bytes to \(out)\n")
    }
}

// MARK: - Chat

/// `gog chat …` — Google Chat.
struct GogChat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chat",
        abstract: "Google Chat.",
        subcommands: [ChatSpaces.self, ChatMessages.self, ChatSend.self])
}

/// `gog chat spaces` — list the spaces you're in.
struct ChatSpaces: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spaces",
        abstract: "List Chat spaces.")

    @Option(name: .long, help: "Maximum spaces to return (1–1000).")
    var max: Int = 100
    @Option(name: .long, help: "Page token from a previous listing.")
    var page: String?
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false
    @OptionGroup var failEmptyFlag: FailEmptyFlag

    func run() async throws {
        guard max > 0, max <= 1000 else {
            Shell.bashCurrent.stderr("gog: --max must be between 1 and 1000\n")
            throw ExitCode(2)
        }
        var query = [URLQueryItem(name: "pageSize", value: String(max))]
        if let page { query.append(URLQueryItem(name: "pageToken", value: page)) }
        let url = try googleURL("https://chat.googleapis.com/v1/spaces", query: query)
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            if failEmptyFlag.failEmpty, jsonListingEmpty(from: body, items: \ChatSpaceList.spaces, token: \ChatSpaceList.nextPageToken) { throw ExitCode(3) }
            return
        }
        let list = try JSONDecoder().decode(ChatSpaceList.self, from: body)
        let spaces = list.spaces ?? []
        if spaces.isEmpty { try emitEmpty("spaces", failEmpty: failEmptyFlag.failEmpty && list.nextPageToken == nil) }
        for space in spaces {
            Shell.bashCurrent.stdout(
                "\(space.name ?? "")\t\(tsvEscaped(space.displayName ?? ""))\n")
        }
        if let next = list.nextPageToken {
            Shell.bashCurrent.stderr("next page token: \(next)\n")
        }
    }
}

/// `gog chat messages <space>` — list messages in a space.
struct ChatMessages: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "messages",
        abstract: "List messages in a space (e.g. spaces/AAAA).")

    @Argument(help: "Space resource name, e.g. spaces/AAAA.") var space: String
    @Option(name: .long, help: "Maximum messages to return (1–1000).")
    var max: Int = 100
    @Option(name: .long, help: "Page token from a previous listing.")
    var page: String?
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false
    @OptionGroup var failEmptyFlag: FailEmptyFlag

    func run() async throws {
        guard max > 0, max <= 1000 else {
            Shell.bashCurrent.stderr("gog: --max must be between 1 and 1000\n")
            throw ExitCode(2)
        }
        var query = [URLQueryItem(name: "pageSize", value: String(max))]
        if let page { query.append(URLQueryItem(name: "pageToken", value: page)) }
        let url = try googleURL(
            "https://chat.googleapis.com/v1", id: "\(space)/messages", query: query)
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            if failEmptyFlag.failEmpty, jsonListingEmpty(from: body, items: \ChatMessageList.messages, token: \ChatMessageList.nextPageToken) { throw ExitCode(3) }
            return
        }
        let list = try JSONDecoder().decode(ChatMessageList.self, from: body)
        let messages = list.messages ?? []
        if messages.isEmpty { try emitEmpty("messages", failEmpty: failEmptyFlag.failEmpty && list.nextPageToken == nil) }
        for message in messages {
            Shell.bashCurrent.stdout(
                "\(message.name ?? "")\t\(tsvEscaped(message.text ?? ""))\n")
        }
        if let next = list.nextPageToken {
            Shell.bashCurrent.stderr("next page token: \(next)\n")
        }
    }
}

/// `gog chat send <space> --text …` — post a message to a space.
struct ChatSend: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send a message to a space.")

    @Argument(help: "Space resource name, e.g. spaces/AAAA.") var space: String
    @Option(name: [.customShort("t"), .long], help: "Message text.") var text: String
    @Flag(name: .long, help: "Build the request but do not send it.")
    var dryRun: Bool = false
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        if GogPolicies.current.chatSendDisabled {
            Shell.bashCurrent.stderr("gog: sending is disabled by host policy\n")
            throw ExitCode(3)
        }
        let payload = try JSONEncoder().encode(["text": text])
        if dryRun {
            Shell.bashCurrent.stderr("dry-run: not sending\n")
            Shell.bashCurrent.stdout(String(decoding: payload, as: UTF8.self) + "\n")
            return
        }
        let url = try googleURL(
            "https://chat.googleapis.com/v1", id: "\(space)/messages")
        let result = try await GoogleHTTPClient().post(url, jsonBody: payload)
        if json {
            Shell.bashCurrent.stdout(String(decoding: result, as: UTF8.self) + "\n")
            return
        }
        let sent = try JSONDecoder().decode(ChatMessage.self, from: result)
        Shell.bashCurrent.stdout("sent: \(sent.name ?? "")\n")
    }
}

private struct ChatSpaceList: Decodable {
    let spaces: [ChatSpace]?
    let nextPageToken: String?
}
private struct ChatSpace: Decodable {
    let name: String?
    let displayName: String?
}
private struct ChatMessageList: Decodable {
    let messages: [ChatMessage]?
    let nextPageToken: String?
}
private struct ChatMessage: Decodable {
    let name: String?
    let text: String?
}

// MARK: - Forms

/// `gog forms …` — Google Forms.
struct GogForms: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "forms",
        abstract: "Google Forms.",
        subcommands: [FormsGet.self, FormsResponses.self],
        aliases: ["form"])
}

/// `gog forms get <formId>` — a form's title and item count.
struct FormsGet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Show a form's title and item count.")

    @Argument(help: "Form ID.") var formId: String
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        let url = try googleURL("https://forms.googleapis.com/v1/forms", id: formId)
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            return
        }
        let form = try JSONDecoder().decode(Form.self, from: body)
        let title = form.info?.title ?? form.info?.documentTitle ?? "(untitled)"
        Shell.bashCurrent.stdout("\(tsvEscaped(title))\t\(form.items?.count ?? 0) items\n")
    }
}

/// `gog forms responses <formId>` — submitted responses (paginated).
struct FormsResponses: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "responses",
        abstract: "List a form's responses.")

    @Argument(help: "Form ID.") var formId: String
    @Option(name: .long, help: "Maximum responses to return (1–5000).")
    var max: Int = 100
    @Option(name: .long, help: "Page token from a previous listing.")
    var page: String?
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false
    @OptionGroup var failEmptyFlag: FailEmptyFlag

    func run() async throws {
        guard max > 0, max <= 5000 else {
            Shell.bashCurrent.stderr("gog: --max must be between 1 and 5000\n")
            throw ExitCode(2)
        }
        var query = [URLQueryItem(name: "pageSize", value: String(max))]
        if let page { query.append(URLQueryItem(name: "pageToken", value: page)) }
        let url = try googleURL(
            "https://forms.googleapis.com/v1/forms", id: "\(formId)/responses",
            query: query)
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            if failEmptyFlag.failEmpty, jsonListingEmpty(from: body, items: \FormResponseList.responses, token: \FormResponseList.nextPageToken) { throw ExitCode(3) }
            return
        }
        let list = try JSONDecoder().decode(FormResponseList.self, from: body)
        let responses = list.responses ?? []
        if responses.isEmpty { try emitEmpty("responses", failEmpty: failEmptyFlag.failEmpty && list.nextPageToken == nil) }
        for response in responses {
            Shell.bashCurrent.stdout(
                "\(response.responseId ?? "")\t\(response.createTime ?? "")\n")
        }
        if let next = list.nextPageToken {
            Shell.bashCurrent.stderr("next page token: \(next)\n")
        }
    }
}

private struct Form: Decodable {
    struct Info: Decodable { let title: String?; let documentTitle: String? }
    struct Item: Decodable {}
    let info: Info?
    let items: [Item]?
}
private struct FormResponseList: Decodable {
    let responses: [FormResponse]?
    let nextPageToken: String?
}
private struct FormResponse: Decodable {
    let responseId: String?
    let createTime: String?
}

/// `gog gmail labels` — list the account's labels (extends the Gmail group).
struct GmailLabels: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "labels",
        abstract: "List Gmail labels.")

    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false
    @OptionGroup var failEmptyFlag: FailEmptyFlag

    func run() async throws {
        let url = try googleURL("https://gmail.googleapis.com/gmail/v1/users/me/labels")
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            if failEmptyFlag.failEmpty, jsonListingEmpty(from: body, items: \LabelList.labels) { throw ExitCode(3) }
            return
        }
        let list = try JSONDecoder().decode(LabelList.self, from: body)
        let labels = list.labels ?? []
        if labels.isEmpty { try emitEmpty("labels", failEmpty: failEmptyFlag.failEmpty) }
        for label in labels {
            Shell.bashCurrent.stdout("\(label.id ?? "")\t\(tsvEscaped(label.name ?? ""))\n")
        }
    }
}

private struct LabelList: Decodable { let labels: [Label]? }
private struct Label: Decodable { let id: String?; let name: String? }

// MARK: - YouTube

/// `gog youtube …` — YouTube Data API.
struct GogYouTube: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "youtube",
        abstract: "YouTube Data API.",
        subcommands: [YouTubeMyChannel.self, YouTubeSearch.self, YouTubePlaylists.self],
        aliases: ["yt"])
}

/// `gog youtube my-channel` — your channel's title and stats.
struct YouTubeMyChannel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "my-channel",
        abstract: "Show your channel's title and stats.",
        aliases: ["channel"])

    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        let url = try googleURL(
            "https://youtube.googleapis.com/youtube/v3/channels",
            query: [
                URLQueryItem(name: "part", value: "snippet,statistics"),
                URLQueryItem(name: "mine", value: "true"),
            ])
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            return
        }
        let list = try JSONDecoder().decode(YTChannelList.self, from: body)
        guard let channel = list.items?.first else {
            Shell.bashCurrent.stderr("gog: no channel found for this account\n")
            throw ExitCode(1)
        }
        let title = channel.snippet?.title ?? ""
        let subscribers = channel.statistics?.subscriberCount ?? "0"
        let videos = channel.statistics?.videoCount ?? "0"
        Shell.bashCurrent.stdout(
            "\(tsvEscaped(title))\tsubscribers=\(subscribers)\tvideos=\(videos)\n")
    }
}

/// `gog youtube search <query>` — search for videos.
struct YouTubeSearch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search for videos.")

    @Argument(help: "Search query.") var query: String
    @Option(name: .long, help: "Maximum results to return (1–50).") var max: Int = 25
    @Option(name: .long, help: "Page token from a previous search.") var page: String?
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false
    @OptionGroup var failEmptyFlag: FailEmptyFlag

    func run() async throws {
        guard max > 0, max <= 50 else {
            Shell.bashCurrent.stderr("gog: --max must be between 1 and 50\n")
            throw ExitCode(2)
        }
        var items = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(max)),
        ]
        if let page { items.append(URLQueryItem(name: "pageToken", value: page)) }
        let url = try googleURL(
            "https://youtube.googleapis.com/youtube/v3/search", query: items)
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            if failEmptyFlag.failEmpty, jsonListingEmpty(from: body, items: \YTSearchList.items, token: \YTSearchList.nextPageToken) { throw ExitCode(3) }
            return
        }
        let list = try JSONDecoder().decode(YTSearchList.self, from: body)
        let results = list.items ?? []
        if results.isEmpty { try emitEmpty("results", failEmpty: failEmptyFlag.failEmpty && list.nextPageToken == nil) }
        for item in results {
            Shell.bashCurrent.stdout(
                "\(item.id?.videoId ?? "")\t\(tsvEscaped(item.snippet?.title ?? ""))\n")
        }
        if let next = list.nextPageToken {
            Shell.bashCurrent.stderr("next page token: \(next)\n")
        }
    }
}

/// `gog youtube playlists` — your playlists.
struct YouTubePlaylists: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "playlists",
        abstract: "List your playlists.")

    @Option(name: .long, help: "Maximum playlists to return (1–50).") var max: Int = 25
    @Option(name: .long, help: "Page token from a previous listing.") var page: String?
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false
    @OptionGroup var failEmptyFlag: FailEmptyFlag

    func run() async throws {
        guard max > 0, max <= 50 else {
            Shell.bashCurrent.stderr("gog: --max must be between 1 and 50\n")
            throw ExitCode(2)
        }
        var items = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "mine", value: "true"),
            URLQueryItem(name: "maxResults", value: String(max)),
        ]
        if let page { items.append(URLQueryItem(name: "pageToken", value: page)) }
        let url = try googleURL(
            "https://youtube.googleapis.com/youtube/v3/playlists", query: items)
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            if failEmptyFlag.failEmpty, jsonListingEmpty(from: body, items: \YTPlaylistList.items, token: \YTPlaylistList.nextPageToken) { throw ExitCode(3) }
            return
        }
        let list = try JSONDecoder().decode(YTPlaylistList.self, from: body)
        let playlists = list.items ?? []
        if playlists.isEmpty { try emitEmpty("playlists", failEmpty: failEmptyFlag.failEmpty && list.nextPageToken == nil) }
        for playlist in playlists {
            Shell.bashCurrent.stdout(
                "\(playlist.id ?? "")\t\(tsvEscaped(playlist.snippet?.title ?? ""))\n")
        }
        if let next = list.nextPageToken {
            Shell.bashCurrent.stderr("next page token: \(next)\n")
        }
    }
}

private struct YTSnippet: Decodable { let title: String?; let channelTitle: String? }
private struct YTChannelList: Decodable { let items: [YTChannel]? }
private struct YTChannel: Decodable {
    struct Stats: Decodable { let subscriberCount: String?; let videoCount: String? }
    let id: String?
    let snippet: YTSnippet?
    let statistics: Stats?
}
private struct YTSearchList: Decodable { let items: [YTSearchItem]?; let nextPageToken: String? }
private struct YTSearchItem: Decodable {
    struct ResourceId: Decodable { let videoId: String? }
    let id: ResourceId?
    let snippet: YTSnippet?
}
private struct YTPlaylistList: Decodable { let items: [YTPlaylist]?; let nextPageToken: String? }
private struct YTPlaylist: Decodable { let id: String?; let snippet: YTSnippet? }

// MARK: - Admin (Directory + Reports)

/// `gog admin …` — Google Workspace **Admin SDK** (Directory + Reports),
/// read-only.
///
/// These commands read the directory and audit log of the *authenticated
/// admin's* Workspace account. The host-injected token must carry the matching
/// admin scopes (e.g. `admin.directory.user.readonly` for the directory,
/// `admin.reports.audit.readonly` for `activities`) and belong to a user with
/// admin privileges; otherwise Google replies 403 and `gog` surfaces that
/// message. `gog` performs no domain-wide delegation itself — scope and any
/// impersonation are the host's responsibility (see PLAN.md). Directory
/// listings default to `customer=my_customer`, i.e. the admin's own Workspace
/// customer.
struct GogAdmin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "admin",
        abstract: "Admin SDK Directory + Reports (reads; gated writes).",
        subcommands: [
            AdminUsers.self, AdminUser.self,
            AdminGroups.self, AdminGroup.self, AdminMembers.self,
            AdminActivities.self,
            AdminSuspend.self, AdminUnsuspend.self,
            AdminMemberAdd.self, AdminMemberRemove.self,
        ],
        aliases: ["directory"])
}

/// Host write-policy gate for the `gog admin` mutations. These directory
/// changes are high-blast-radius, so they are disabled unless the host opts in
/// (`GogPolicy.adminWriteDisabled == false`); otherwise they exit 3 — the same
/// fail-closed shape as `gmail send` / `chat send`.
private func requireAdminWrite() throws {
    if GogPolicies.current.adminWriteDisabled {
        Shell.bashCurrent.stderr(
            "gog: admin write commands are disabled by host policy\n")
        throw ExitCode(3)
    }
}

/// `gog admin suspend <userKey>` — suspend a user (gated mutation).
struct AdminSuspend: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "suspend",
        abstract: "Suspend a user (gated; --dry-run to preview).")

    @Argument(help: "User key: primary email or unique id.") var userKey: String
    @Flag(name: .long, help: "Build the request but do not apply it.")
    var dryRun: Bool = false
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        try await adminSetSuspended(userKey, suspended: true, dryRun: dryRun, json: json)
    }
}

/// `gog admin unsuspend <userKey>` — restore a suspended user (gated mutation).
struct AdminUnsuspend: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unsuspend",
        abstract: "Un-suspend a user (gated; --dry-run to preview).")

    @Argument(help: "User key: primary email or unique id.") var userKey: String
    @Flag(name: .long, help: "Build the request but do not apply it.")
    var dryRun: Bool = false
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        try await adminSetSuspended(userKey, suspended: false, dryRun: dryRun, json: json)
    }
}

/// Shared `users.patch` for (un)suspending a user behind the write gate.
private func adminSetSuspended(_ userKey: String, suspended: Bool,
                               dryRun: Bool, json: Bool) async throws {
    try requireAdminWrite()
    let payload = try JSONEncoder().encode(["suspended": suspended])
    let verb = suspended ? "suspend" : "unsuspend"
    if dryRun {
        Shell.bashCurrent.stderr("dry-run: not modifying\n")
        Shell.bashCurrent.stdout(
            "\(verb) \(userKey): PATCH \(String(decoding: payload, as: UTF8.self))\n")
        return
    }
    let url = try googleURL(
        "https://admin.googleapis.com/admin/directory/v1/users/\(pathSegment(userKey))")
    let result = try await GoogleHTTPClient().patch(url, jsonBody: payload)
    if json {
        Shell.bashCurrent.stdout(String(decoding: result, as: UTF8.self) + "\n")
        return
    }
    Shell.bashCurrent.stdout("\(suspended ? "suspended" : "unsuspended"): \(userKey)\n")
}

/// `gog admin member-add <groupKey> <member>` — add a member to a group (gated).
struct AdminMemberAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "member-add",
        abstract: "Add a member to a group (gated; --dry-run to preview).")

    @Argument(help: "Group key: email or unique id.") var groupKey: String
    @Argument(help: "Member email address to add (members.insert needs an email, not an id).")
    var member: String
    @Option(name: .long, help: "Role: MEMBER, MANAGER, or OWNER.") var role: String = "MEMBER"
    @Flag(name: .long, help: "Build the request but do not apply it.")
    var dryRun: Bool = false
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        try requireAdminWrite()
        // members.insert requires the member's email (a bare id is read-only and
        // only valid as the URI key for get/remove/update) — fail fast with a hint.
        guard member.contains("@") else {
            Shell.bashCurrent.stderr(
                "gog: member-add needs an email address, not an id "
                    + "(an id only works for member-remove)\n")
            throw ExitCode(2)
        }
        let normalizedRole = role.uppercased()
        guard ["MEMBER", "MANAGER", "OWNER"].contains(normalizedRole) else {
            Shell.bashCurrent.stderr("gog: --role must be MEMBER, MANAGER, or OWNER\n")
            throw ExitCode(2)
        }
        let payload = try JSONEncoder().encode(["email": member, "role": normalizedRole])
        if dryRun {
            Shell.bashCurrent.stderr("dry-run: not modifying\n")
            Shell.bashCurrent.stdout(
                "add to \(groupKey): POST \(String(decoding: payload, as: UTF8.self))\n")
            return
        }
        let url = try googleURL(
            "https://admin.googleapis.com/admin/directory/v1/groups/"
                + "\(pathSegment(groupKey))/members")
        let result = try await GoogleHTTPClient().post(url, jsonBody: payload)
        if json {
            Shell.bashCurrent.stdout(String(decoding: result, as: UTF8.self) + "\n")
            return
        }
        Shell.bashCurrent.stdout("added \(member) to \(groupKey) as \(normalizedRole)\n")
    }
}

/// `gog admin member-remove <groupKey> <member>` — remove a member (gated).
struct AdminMemberRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "member-remove",
        abstract: "Remove a member from a group (gated; --dry-run to preview).")

    @Argument(help: "Group key: email or unique id.") var groupKey: String
    @Argument(help: "Member key: email or id to remove.") var member: String
    @Flag(name: .long, help: "Build the request but do not apply it.")
    var dryRun: Bool = false

    func run() async throws {
        try requireAdminWrite()
        if dryRun {
            Shell.bashCurrent.stderr("dry-run: not modifying\n")
            Shell.bashCurrent.stdout("remove from \(groupKey): DELETE member \(member)\n")
            return
        }
        let url = try googleURL(
            "https://admin.googleapis.com/admin/directory/v1/groups/"
                + "\(pathSegment(groupKey))/members/\(pathSegment(member))")
        _ = try await GoogleHTTPClient().delete(url)
        Shell.bashCurrent.stdout("removed \(member) from \(groupKey)\n")
    }
}

/// `gog admin users` — list directory users (defaults to the admin's customer).
struct AdminUsers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "users",
        abstract: "List directory users.")

    @Option(name: .long, help: "Maximum users to return (1–500).") var max: Int = 100
    @Option(name: .long, help: "Page token from a previous listing.") var page: String?
    @Option(name: .long, help: "Restrict to one domain instead of the whole customer.")
    var domain: String?
    @Option(name: .long, help: "Directory search query, e.g. 'orgUnitPath=/Sales'.")
    var query: String?
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false
    @OptionGroup var failEmptyFlag: FailEmptyFlag

    func run() async throws {
        guard max > 0, max <= 500 else {
            Shell.bashCurrent.stderr("gog: --max must be between 1 and 500\n")
            throw ExitCode(2)
        }
        var items = [
            URLQueryItem(name: "maxResults", value: String(max)),
            URLQueryItem(name: "orderBy", value: "email"),
        ]
        if let domain {
            items.append(URLQueryItem(name: "domain", value: domain))
        } else {
            items.append(URLQueryItem(name: "customer", value: "my_customer"))
        }
        if let query { items.append(URLQueryItem(name: "query", value: query)) }
        if let page { items.append(URLQueryItem(name: "pageToken", value: page)) }
        let url = try googleURL(
            "https://admin.googleapis.com/admin/directory/v1/users", query: items)
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            if failEmptyFlag.failEmpty, jsonListingEmpty(from: body, items: \DirUserList.users, token: \DirUserList.nextPageToken) { throw ExitCode(3) }
            return
        }
        let list = try JSONDecoder().decode(DirUserList.self, from: body)
        let users = list.users ?? []
        if users.isEmpty { try emitEmpty("users", failEmpty: failEmptyFlag.failEmpty && list.nextPageToken == nil) }
        for user in users {
            let status = (user.suspended ?? false) ? "suspended" : "active"
            Shell.bashCurrent.stdout(
                "\(user.primaryEmail ?? "")\t\(tsvEscaped(user.name?.fullName ?? ""))\t\(status)\n")
        }
        if let next = list.nextPageToken {
            Shell.bashCurrent.stderr("next page token: \(next)\n")
        }
    }
}

/// `gog admin user <userKey>` — one user by primary email or unique id.
struct AdminUser: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "user",
        abstract: "Show a user by email or id.")

    @Argument(help: "User key: primary email or unique id.") var userKey: String
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        let url = try googleURL(
            "https://admin.googleapis.com/admin/directory/v1/users/\(pathSegment(userKey))")
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            return
        }
        let user = try JSONDecoder().decode(DirUser.self, from: body)
        let name = tsvEscaped(user.name?.fullName ?? "(unknown)")
        let email = user.primaryEmail ?? ""
        var line = "\(name)\(email.isEmpty ? "" : " <\(email)>")"
        if let ou = user.orgUnitPath, !ou.isEmpty {
            line += "\torgUnit=\(tsvEscaped(ou))"
        }
        if user.isAdmin == true { line += "\tadmin" }
        if user.suspended == true { line += "\tsuspended" }
        Shell.bashCurrent.stdout(line + "\n")
    }
}

/// `gog admin groups` — list groups (whole customer, a domain, or for a user).
struct AdminGroups: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "groups",
        abstract: "List directory groups.")

    @Option(name: .long, help: "Maximum groups to return (1–200).") var max: Int = 100
    @Option(name: .long, help: "Page token from a previous listing.") var page: String?
    @Option(name: .long, help: "Restrict to one domain instead of the whole customer.")
    var domain: String?
    @Option(name: .long, help: "List only groups this user (email/id) belongs to.")
    var user: String?
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false
    @OptionGroup var failEmptyFlag: FailEmptyFlag

    func run() async throws {
        guard max > 0, max <= 200 else {
            Shell.bashCurrent.stderr("gog: --max must be between 1 and 200\n")
            throw ExitCode(2)
        }
        var items = [URLQueryItem(name: "maxResults", value: String(max))]
        // `userKey` is mutually exclusive with customer/domain in the API.
        if let user {
            items.append(URLQueryItem(name: "userKey", value: user))
        } else if let domain {
            items.append(URLQueryItem(name: "domain", value: domain))
        } else {
            items.append(URLQueryItem(name: "customer", value: "my_customer"))
        }
        if let page { items.append(URLQueryItem(name: "pageToken", value: page)) }
        let url = try googleURL(
            "https://admin.googleapis.com/admin/directory/v1/groups", query: items)
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            if failEmptyFlag.failEmpty, jsonListingEmpty(from: body, items: \DirGroupList.groups, token: \DirGroupList.nextPageToken) { throw ExitCode(3) }
            return
        }
        let list = try JSONDecoder().decode(DirGroupList.self, from: body)
        let groups = list.groups ?? []
        if groups.isEmpty { try emitEmpty("groups", failEmpty: failEmptyFlag.failEmpty && list.nextPageToken == nil) }
        for group in groups {
            Shell.bashCurrent.stdout(
                "\(group.email ?? "")\t\(tsvEscaped(group.name ?? ""))\tmembers=\(group.directMembersCount ?? "0")\n")
        }
        if let next = list.nextPageToken {
            Shell.bashCurrent.stderr("next page token: \(next)\n")
        }
    }
}

/// `gog admin group <groupKey>` — one group by email or unique id.
struct AdminGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "group",
        abstract: "Show a group by email or id.")

    @Argument(help: "Group key: email or unique id.") var groupKey: String
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        let url = try googleURL(
            "https://admin.googleapis.com/admin/directory/v1/groups/\(pathSegment(groupKey))")
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            return
        }
        let group = try JSONDecoder().decode(DirGroup.self, from: body)
        let name = tsvEscaped(group.name ?? "(unknown)")
        let email = group.email ?? ""
        var line = "\(name)\(email.isEmpty ? "" : " <\(email)>")"
        line += "\tmembers=\(group.directMembersCount ?? "0")"
        if let desc = group.description, !desc.isEmpty {
            line += "\t\(tsvEscaped(desc))"
        }
        Shell.bashCurrent.stdout(line + "\n")
    }
}

/// `gog admin members <groupKey>` — list a group's members.
struct AdminMembers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "members",
        abstract: "List a group's members.")

    @Argument(help: "Group key: email or unique id.") var groupKey: String
    @Option(name: .long, help: "Maximum members to return (1–200).") var max: Int = 100
    @Option(name: .long, help: "Page token from a previous listing.") var page: String?
    @Option(name: .long, help: "Filter by roles, e.g. 'OWNER,MANAGER'.") var roles: String?
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false
    @OptionGroup var failEmptyFlag: FailEmptyFlag

    func run() async throws {
        guard max > 0, max <= 200 else {
            Shell.bashCurrent.stderr("gog: --max must be between 1 and 200\n")
            throw ExitCode(2)
        }
        var items = [URLQueryItem(name: "maxResults", value: String(max))]
        if let roles { items.append(URLQueryItem(name: "roles", value: roles)) }
        if let page { items.append(URLQueryItem(name: "pageToken", value: page)) }
        let url = try googleURL(
            "https://admin.googleapis.com/admin/directory/v1/groups/"
                + "\(pathSegment(groupKey))/members",
            query: items)
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            if failEmptyFlag.failEmpty, jsonListingEmpty(from: body, items: \DirMemberList.members, token: \DirMemberList.nextPageToken) { throw ExitCode(3) }
            return
        }
        let list = try JSONDecoder().decode(DirMemberList.self, from: body)
        let members = list.members ?? []
        if members.isEmpty { try emitEmpty("members", failEmpty: failEmptyFlag.failEmpty && list.nextPageToken == nil) }
        for member in members {
            Shell.bashCurrent.stdout(
                "\(member.email ?? member.id ?? "")\t\(member.role ?? "")\t\(member.type ?? "")\n")
        }
        if let next = list.nextPageToken {
            Shell.bashCurrent.stderr("next page token: \(next)\n")
        }
    }
}

private struct DirUserList: Decodable { let users: [DirUser]?; let nextPageToken: String? }
private struct DirUser: Decodable {
    struct Name: Decodable { let fullName: String? }
    let id: String?
    let primaryEmail: String?
    let name: Name?
    let suspended: Bool?
    let isAdmin: Bool?
    let orgUnitPath: String?
}
private struct DirGroupList: Decodable { let groups: [DirGroup]?; let nextPageToken: String? }
private struct DirGroup: Decodable {
    let id: String?
    let email: String?
    let name: String?
    let description: String?
    // The Directory API serialises this count as a JSON string (e.g. "5").
    let directMembersCount: String?
}
private struct DirMemberList: Decodable { let members: [DirMember]?; let nextPageToken: String? }
private struct DirMember: Decodable {
    let id: String?
    let email: String?
    let role: String?
    let type: String?
    let status: String?
}

/// `gog admin activities <application>` — Admin SDK **Reports** audit log for
/// one application (e.g. `login`, `admin`, `drive`, `token`, `groups`).
/// Defaults to all users; pass `--user` for a single account.
struct AdminActivities: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "activities",
        abstract: "Audit-log activities for an application (login, admin, drive, …).",
        aliases: ["activity"])

    @Argument(help: "Application: login, admin, drive, token, groups, calendar, ….")
    var application: String
    @Option(name: .long, help: "User key (email/id), or 'all'.") var user: String = "all"
    @Option(name: .long, help: "Filter to a single event name, e.g. 'login_success'.")
    var event: String?
    @Option(name: .long, help: "Maximum activities to return (1–1000).") var max: Int = 100
    @Option(name: .long, help: "Page token from a previous listing.") var page: String?
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false
    @OptionGroup var failEmptyFlag: FailEmptyFlag

    func run() async throws {
        guard max > 0, max <= 1000 else {
            Shell.bashCurrent.stderr("gog: --max must be between 1 and 1000\n")
            throw ExitCode(2)
        }
        var items = [URLQueryItem(name: "maxResults", value: String(max))]
        if let event { items.append(URLQueryItem(name: "eventName", value: event)) }
        if let page { items.append(URLQueryItem(name: "pageToken", value: page)) }
        // userKey and applicationName are both single path segments.
        let url = try googleURL(
            "https://admin.googleapis.com/admin/reports/v1/activity/users/"
                + "\(pathSegment(user))/applications/\(pathSegment(application))",
            query: items)
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            if failEmptyFlag.failEmpty, jsonListingEmpty(from: body, items: \ReportActivityList.items, token: \ReportActivityList.nextPageToken) { throw ExitCode(3) }
            return
        }
        let list = try JSONDecoder().decode(ReportActivityList.self, from: body)
        let activities = list.items ?? []
        if activities.isEmpty { try emitEmpty("activities", failEmpty: failEmptyFlag.failEmpty && list.nextPageToken == nil) }
        for activity in activities {
            let time = activity.id?.time ?? ""
            let actor = activity.actor?.email ?? activity.actor?.profileId ?? ""
            let events = (activity.events ?? [])
                .compactMap(\.name).joined(separator: ",")
            Shell.bashCurrent.stdout(
                "\(time)\t\(tsvEscaped(actor))\t\(tsvEscaped(events))\n")
        }
        if let next = list.nextPageToken {
            Shell.bashCurrent.stderr("next page token: \(next)\n")
        }
    }
}

private struct ReportActivityList: Decodable {
    let items: [ReportActivity]?
    let nextPageToken: String?
}
private struct ReportActivity: Decodable {
    struct ID: Decodable { let time: String?; let applicationName: String? }
    struct Actor: Decodable { let email: String?; let profileId: String? }
    struct Event: Decodable { let type: String?; let name: String? }
    let id: ID?
    let actor: Actor?
    let events: [Event]?
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
        // Actually reach Google so an expired token or an allow-list that
        // excludes the API hosts is caught here, not reported as "ready".
        let url = try googleURL(
            "https://people.googleapis.com/v1/people/me",
            query: [URLQueryItem(name: "personFields", value: "names,emailAddresses")])
        let body = try await GoogleHTTPClient().get(url)
        let account = (try? JSONDecoder().decode(PeopleMe.self, from: body))?
            .emailAddresses?.first?.value
            ?? GogCredentials.current?.accountHint
            ?? "unknown"
        if json {
            struct Status: Encodable { let status: String; let account: String }
            let data = try JSONEncoder().encode(
                Status(status: "ready", account: account))
            Shell.bashCurrent.stdout(String(decoding: data, as: UTF8.self) + "\n")
        } else {
            Shell.bashCurrent.stdout("ready: authenticated as \(account)\n")
        }
    }
}
