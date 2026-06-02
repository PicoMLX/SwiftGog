import ArgumentParser
import Foundation
import BashInterpreter
import GogCore

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
            GogContacts.self, GogTasks.self, GogAuth.self,
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
        subcommands: [DriveLs.self, DriveGet.self, DriveSearch.self, DriveDownload.self, DriveUpload.self],
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
        try emitDriveFileList(body, json: json)
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
        let url = try googleURL(
            "https://www.googleapis.com/drive/v3/files", id: id,
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
        let resolved = Shell.bashCurrent.resolvePath(out)
        // Validate writability via a sibling probe — without truncating an
        // existing destination — so a later download failure can't destroy it.
        let probe = resolved + ".gog-precheck"
        do {
            try await Shell.bashCurrent.fileSystem.writeData(
                Data(), to: probe, append: false)
            try? await Shell.bashCurrent.fileSystem.remove(probe, recursive: false)
        } catch {
            Shell.bashCurrent.stderr("gog: cannot write \(out): \(error)\n")
            throw ExitCode(23)
        }
        let url = try googleURL(
            "https://www.googleapis.com/drive/v3/files", id: id,
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

/// `gog gmail …` — Gmail group (read commands; `send` lands separately).
struct GogGmail: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gmail",
        abstract: "Gmail.",
        subcommands: [GmailMessages.self, GmailGet.self, GmailSend.self],
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
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        guard max > 0, max <= 500 else {
            Shell.bashCurrent.stderr("gog: --max must be between 1 and 500\n")
            throw ExitCode(2)
        }
        var comps = URLComponents(
            string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        var query = [URLQueryItem(name: "maxResults", value: String(max))]
        if let q = self.query { query.append(URLQueryItem(name: "q", value: q)) }
        comps.queryItems = query

        let body = try await GoogleHTTPClient().get(comps.url!)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            return
        }
        let list = try JSONDecoder().decode(GmailMessageList.self, from: body)
        let messages = list.messages ?? []
        if messages.isEmpty { Shell.bashCurrent.stderr("No messages\n") }
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
        // Reject CR/LF in header fields to prevent header injection (e.g. Bcc:).
        let newlines = CharacterSet(charactersIn: "\r\n")
        guard to.rangeOfCharacter(from: newlines) == nil,
              subject.rangeOfCharacter(from: newlines) == nil else {
            Shell.bashCurrent.stderr(
                "gog: --to and --subject must not contain newlines\n")
            throw ExitCode(2)
        }
        // RFC 2047-encode the subject when it isn't plain ASCII.
        let encodedSubject = subject.allSatisfy(\.isASCII)
            ? subject
            : "=?UTF-8?B?\(Data(subject.utf8).base64EncodedString())?="
        let mime = "To: \(to)\r\n"
            + "Subject: \(encodedSubject)\r\n"
            + "Content-Type: text/plain; charset=UTF-8\r\n\r\n"
            + body
        let mimeData = Data(mime.utf8)
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

/// `gog calendar …` — Google Calendar group (primary calendar).
struct GogCalendar: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calendar",
        abstract: "Google Calendar.",
        subcommands: [CalendarEvents.self, CalendarGet.self, CalendarCreate.self],
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
    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        guard max > 0, max <= 2500 else {
            Shell.bashCurrent.stderr("gog: --max must be between 1 and 2500\n")
            throw ExitCode(2)
        }
        var comps = URLComponents(string:
            "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        // Default to upcoming events: orderBy=startTime needs a timeMin to mean
        // "from now" rather than from the start of the calendar.
        let timeMin = from ?? ISO8601DateFormatter().string(from: Date())
        let query = [
            URLQueryItem(name: "maxResults", value: String(max)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "timeMin", value: timeMin),
        ]
        comps.queryItems = query

        let body = try await GoogleHTTPClient().get(comps.url!)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            return
        }
        let list = try JSONDecoder().decode(CalEventList.self, from: body)
        let items = list.items ?? []
        if items.isEmpty { Shell.bashCurrent.stderr("No events\n") }
        for event in items {
            Shell.bashCurrent.stdout(
                "\(event.id ?? "")\t\(event.when)\t\(event.summary ?? "")\n")
        }
        if let next = list.nextPageToken {
            Shell.bashCurrent.stderr("next page token: \(next)\n")
        }
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

// MARK: - Contacts (People API connections)

/// `gog contacts …` — Google Contacts via the People API.
struct GogContacts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "contacts",
        abstract: "Google Contacts.",
        subcommands: [ContactsList.self, ContactsGet.self],
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
            return
        }
        let list = try JSONDecoder().decode(ContactList.self, from: body)
        let people = list.connections ?? []
        if people.isEmpty { Shell.bashCurrent.stderr("No contacts\n") }
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

// MARK: - Tasks

/// `gog tasks …` — Google Tasks.
struct GogTasks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tasks",
        abstract: "Google Tasks.",
        subcommands: [TasksLists.self, TasksList.self, TasksAdd.self],
        aliases: ["task"])
}

/// `gog tasks lists` — your task lists.
struct TasksLists: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lists",
        abstract: "List your task lists.")

    @Flag(name: [.customShort("j"), .long], help: "Emit raw JSON.")
    var json: Bool = false

    func run() async throws {
        let url = try googleURL("https://tasks.googleapis.com/tasks/v1/users/@me/lists")
        let body = try await GoogleHTTPClient().get(url)
        if json {
            Shell.bashCurrent.stdout(String(decoding: body, as: UTF8.self) + "\n")
            return
        }
        let result = try JSONDecoder().decode(TaskListCollection.self, from: body)
        let lists = result.items ?? []
        if lists.isEmpty { Shell.bashCurrent.stderr("No task lists\n") }
        for list in lists {
            Shell.bashCurrent.stdout("\(list.id ?? "")\t\(list.title ?? "")\n")
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
            return
        }
        let result = try JSONDecoder().decode(TaskCollection.self, from: body)
        let tasks = result.items ?? []
        if tasks.isEmpty { Shell.bashCurrent.stderr("No tasks\n") }
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

private struct TaskListCollection: Decodable {
    struct Item: Decodable { let id: String?; let title: String? }
    let items: [Item]?
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
