import Testing
import Foundation
import BashInterpreter
import GogCore
import GogCommands
import GogShell

/// A canned credential provider for tests — no network, no real OAuth.
private struct StubProvider: GogCredentialProvider {
    let token: String
    let accountHint: String?
    func accessToken() async throws -> String { token }
}

/// A fake transport returning a canned response — exercises command happy
/// paths without real network.
private struct MockTransport: GogTransport {
    let response: HTTPResponse
    func send(method: String, url: URL,
              headers: [String: String], body: Data?) async throws -> HTTPResponse {
        response
    }
}

/// Like MockTransport but records the last request URL, for asserting on URL
/// construction (e.g. percent-encoding).
private final class RecordingTransport: GogTransport, @unchecked Sendable {
    let response: HTTPResponse
    var lastURL: URL?
    var lastBody: Data?
    var urls: [URL] = []
    init(response: HTTPResponse) { self.response = response }
    func send(method: String, url: URL,
              headers: [String: String], body: Data?) async throws -> HTTPResponse {
        lastURL = url
        lastBody = body
        urls.append(url)
        return response
    }
}

/// Wiring + behaviour tests: `gog` registered into a sandboxed `Shell` and run
/// through `runCapturing`. Covers the fail-closed sandbox contracts (deny
/// paths) and command happy paths via an injected fake `GogTransport`.
@Suite struct GogWiringTests {

    @Test func versionRunsThroughTheShell() async throws {
        let shell = Shell()
        shell.registerGogCommands()

        let run = try await shell.runCapturing("gog version")
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("gog \(GogVersionInfo.version)"))
    }

    @Test func networkDeniedFailsClosed() async throws {
        let shell = Shell()                 // networkConfig defaults to nil
        shell.registerGogCommands()

        let run = try await shell.runCapturing("gog auth status")
        #expect(run.exitStatus == ExitStatus(7))
        #expect(run.stderr.contains("network access denied"))
    }

    @Test func credentialsMissingFailsClosed() async throws {
        let shell = Shell()
        shell.networkConfig = NetworkConfig(
            allowedURLPrefixes: [AllowedURLEntry("https://www.googleapis.com/")],
            allowedMethods: [.GET])
        shell.registerGogCommands()

        // No provider bound for this run.
        let run = try await shell.runCapturing("gog auth status")
        #expect(run.exitStatus == ExitStatus(7))
        #expect(run.stderr.contains("no credentials"))
    }

    @Test func authStatusReadyWithInjectedProvider() async throws {
        let shell = Shell()
        shell.networkConfig = NetworkConfig(
            allowedURLPrefixes: [AllowedURLEntry("https://www.googleapis.com/")],
            allowedMethods: [.GET])
        shell.registerGogCommands()

        // auth status now probes People; the fake transport stands in for Google.
        let profile = #"{"emailAddresses":[{"value":"alice@example.com"}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(profile.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "secret-token-xyz",
                             accountHint: "alice@example.com")
            ) {
                try await shell.runCapturing("gog auth status --json")
            }
        }

        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("alice@example.com"))
        // Contract #3: the token must never surface in output.
        #expect(!run.stdout.contains("secret-token-xyz"))
        #expect(!run.stderr.contains("secret-token-xyz"))
    }

    @Test func meFailsClosedWithoutCredentials() async throws {
        let shell = Shell()
        shell.networkConfig = NetworkConfig(
            allowedURLPrefixes: [AllowedURLEntry("https://people.googleapis.com/")],
            allowedMethods: [.GET])
        shell.registerGogCommands()

        // Network is configured but no provider is bound: the GoogleHTTPClient
        // guard fails closed before any request is made.
        let run = try await shell.runCapturing("gog me")
        #expect(run.exitStatus == ExitStatus(7))
        #expect(run.stderr.contains("no credentials"))
    }

    @Test func meDecodesProfile() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"names":[{"displayName":"Ada Lovelace"}],"#
            + #""emailAddresses":[{"value":"ada@example.com"}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog me")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("Ada Lovelace"))
        #expect(run.stdout.contains("ada@example.com"))
    }

    @Test func meJSONPassesThroughRawBody() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"names":[{"displayName":"Ada"}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog me --json")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains(#""displayName":"Ada""#))
    }

    @Test func driveLsRendersTSV() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"files":[{"id":"abc","name":"Report.pdf","#
            + #""mimeType":"application/pdf"}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive ls")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("abc\tReport.pdf\tapplication/pdf"))
    }

    @Test func reauthRequiredWhenTokenRejected() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = MockTransport(
            response: HTTPResponse(status: 401, body: Data()))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog me")
            }
        }
        #expect(run.exitStatus == ExitStatus(7))
        #expect(run.stderr.contains("re-auth required"))
    }

    @Test func driveLsRejectsBadMax() async throws {
        // Validation happens before any network/credential use, so this needs
        // neither — exit 2 with a usage diagnostic.
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing("gog drive ls --max 0")
        #expect(run.exitStatus == ExitStatus(2))
        #expect(run.stderr.contains("--max"))
    }

    @Test func driveLsFailsClosedWithoutCredentials() async throws {
        let shell = Shell()
        shell.networkConfig = NetworkConfig(
            allowedURLPrefixes: [AllowedURLEntry("https://www.googleapis.com/")],
            allowedMethods: [.GET])
        shell.registerGogCommands()
        let run = try await shell.runCapturing("gog drive ls --max 10")
        #expect(run.exitStatus == ExitStatus(7))
        #expect(run.stderr.contains("no credentials"))
    }

    @Test func driveGetRendersFile() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"id":"abc","name":"Report.pdf","mimeType":"application/pdf"}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive get abc")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("abc\tReport.pdf\tapplication/pdf"))
    }

    @Test func driveSearchRendersResults() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"files":[{"id":"f1","name":"notes.txt","mimeType":"text/plain"}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive search notes")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("f1\tnotes.txt\ttext/plain"))
    }

    @Test func driveDownloadWritesIntoMount() async throws {
        let mounted = MountedFileSystem(
            mounts: [.init(virtual: "/gog", host: "/gog")],
            backing: InMemoryFileSystem())
        let shell = Shell(fileSystem: mounted)
        try await shell.fileSystem.createDirectory("/gog", intermediates: true)
        shell.registerGogCommands()
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data("PDFBYTES".utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive download FILEID --out /gog/out.bin")
            }
        }
        #expect(run.exitStatus == .success)
        let saved = try await shell.fileSystem.readData("/gog/out.bin")
        #expect(String(decoding: saved, as: UTF8.self) == "PDFBYTES")
    }

    @Test func driveDownloadRejectsOutsideMount() async throws {
        let mounted = MountedFileSystem(
            mounts: [.init(virtual: "/gog", host: "/gog")],
            backing: InMemoryFileSystem())
        let shell = Shell(fileSystem: mounted)
        try await shell.fileSystem.createDirectory("/gog", intermediates: true)
        shell.registerGogCommands()
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data("X".utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive download FILEID --out /etc/out.bin")
            }
        }
        #expect(run.exitStatus != .success)
    }

    @Test func drivePermissionsRenders() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"permissions":[{"id":"p1","type":"user","role":"writer","#
            + #""emailAddress":"alice@x.com"}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive permissions FILEID")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("p1\twriter\tuser\talice@x.com"))
    }

    @Test func drivePermissionsEncodesFileIdInPath() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"permissions":[]}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive permissions 'a/b'")
            }
        }
        #expect(run.exitStatus == .success)
        let url = transport.lastURL?.absoluteString ?? ""
        // The file ID is a single path segment: "/" must be encoded.
        #expect(url.contains("a%2Fb/permissions"))
    }

    @Test func driveRevisionsRenders() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"revisions":[{"id":"r1","modifiedTime":"2026-06-01T00:00:00Z","size":"1024","lastModifyingUser":{"displayName":"Alice"}}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive revisions FILEID")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("r1\t2026-06-01T00:00:00Z\t1024\tAlice"))
    }

    @Test func driveRevisionsRejectsBadMax() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing("gog drive revisions FILEID --max 0")
        #expect(run.exitStatus == ExitStatus(2))
    }

    @Test func driveAboutRendersQuota() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"user":{"displayName":"Alice","emailAddress":"alice@x.com"},"#
            + #""storageQuota":{"limit":"100","usage":"42"}}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive about")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("Alice <alice@x.com>"))
        #expect(run.stdout.contains("quota: usage=42 limit=100"))
    }

    @Test func gmailMessagesRendersIds() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"messages":[{"id":"m1","threadId":"t1"}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog gmail messages")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("m1\tt1"))
    }

    @Test func gmailGetRendersHeaders() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"id":"m1","snippet":"hi there","payload":{"headers":["#
            + #"{"name":"From","value":"a@b.com"},"#
            + #"{"name":"Subject","value":"Hello"}]}}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog gmail get m1")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("Subject: Hello"))
        #expect(run.stdout.contains("From: a@b.com"))
    }

    @Test func gmailSendDryRunDoesNotSend() async throws {
        // --dry-run short-circuits before any network/credential use.
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing(
            "gog gmail send --to a@b.com --subject Hi --body Yo --dry-run")
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("a@b.com"))
        #expect(run.stdout.contains("Hi"))
    }

    @Test func gmailSendBlockedByHostPolicy() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await GogPolicies.$current.withValue(
            GogPolicy(gmailSendDisabled: true)
        ) {
            try await shell.runCapturing(
                "gog gmail send --to a@b.com --subject Hi --body Yo")
        }
        #expect(run.exitStatus == ExitStatus(3))
        #expect(run.stderr.contains("disabled by host policy"))
    }

    @Test func gmailSendPostsAndReportsId() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"id":"sent123"}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing(
                    "gog gmail send --to a@b.com --subject Hi --body Yo")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("sent: sent123"))
    }

    @Test func gmailDraftsRendersIds() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"drafts":[{"id":"d1","message":{"id":"m1"}}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog gmail drafts")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("d1\tm1"))
    }

    @Test func gmailDraftCreatePostsAndReportsId() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = MockTransport(
            response: HTTPResponse(
                status: 200, body: Data(#"{"id":"draft9","message":{"id":"m9"}}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing(
                    "gog gmail draft --to a@b.com --subject Hi --body Yo")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("draft created: draft9"))
    }

    @Test func gmailDraftRejectsHeaderInjection() async throws {
        // A newline in --to (single-quoted) must be rejected before any network,
        // so a smuggled Bcc: can't reach the MIME headers.
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing(
            "gog gmail draft --to 'a@b.com\nBcc: evil@x.com' --subject Hi --body Yo")
        #expect(run.exitStatus == ExitStatus(2))
    }

    @Test func gmailThreadsRenders() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"threads":[{"id":"t1","snippet":"hello world"}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog gmail threads")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("t1\thello world"))
    }

    @Test func gmailThreadGetRendersMessages() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"id":"t1","messages":[{"id":"m1","payload":{"headers":["#
            + #"{"name":"From","value":"a@b.com"},"#
            + #"{"name":"Subject","value":"Hi"}]}}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog gmail thread t1")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("m1\ta@b.com\tHi"))
    }

    @Test func gmailAttachmentDownloadsIntoSandbox() async throws {
        let mounted = MountedFileSystem(
            mounts: [.init(virtual: "/gog", host: "/gog")],
            backing: InMemoryFileSystem())
        let shell = Shell(fileSystem: mounted)
        try await shell.fileSystem.createDirectory("/gog", intermediates: true)
        shell.registerGogCommands()
        // base64url of "hello" is "aGVsbG8" (unpadded).
        let transport = MockTransport(
            response: HTTPResponse(
                status: 200, body: Data(#"{"size":5,"data":"aGVsbG8"}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing(
                    "gog gmail attachment m1 a1 --out /gog/att.bin")
            }
        }
        #expect(run.exitStatus == .success)
        let saved = try await shell.fileSystem.readData("/gog/att.bin")
        #expect(String(decoding: saved, as: UTF8.self) == "hello")
    }

    @Test func gmailAttachmentsListsNestedParts() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        // A nested multipart: the inline text part has no attachmentId and is
        // skipped; the attachment in the nested part must be found via recursion.
        let json = #"{"payload":{"parts":[{"mimeType":"text/plain","body":{"size":10}},"#
            + #"{"parts":[{"filename":"report.pdf","mimeType":"application/pdf","#
            + #""body":{"attachmentId":"att123","size":2048}}]}]}}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog gmail attachments m1")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("att123\treport.pdf\tapplication/pdf\t2048"))
    }

    @Test func gmailAttachmentsJSONOmitsMessageBody() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        // The inline text part carries body.data ("c2VjcmV0" = "secret"); --json
        // must emit only the attachment list, never the raw message body.
        let json = #"{"payload":{"parts":[{"mimeType":"text/plain","body":{"data":"c2VjcmV0"}},"#
            + #"{"filename":"a.pdf","mimeType":"application/pdf","#
            + #""body":{"attachmentId":"att1","size":10}}]}}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog gmail attachments m1 --json")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("att1"))
        #expect(!run.stdout.contains("c2VjcmV0"))   // inline body data not leaked
    }

    @Test func gmailAttachmentsUsesFilenameNotAttachmentId() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        // Part A: a message body Gmail stored under its own attachmentId, with
        //   NO filename -> must be excluded (not a user attachment).
        // Part B: a real attachment with a filename but inline bytes (no
        //   attachmentId) -> must be surfaced.
        let json = #"{"payload":{"parts":[{"mimeType":"text/html","body":{"attachmentId":"bodyABC","size":500}},"#
            + #"{"filename":"note.txt","mimeType":"text/plain","body":{"data":"aGk","size":2}}]}}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog gmail attachments m1")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("note.txt"))    // inline attachment surfaced
        #expect(!run.stdout.contains("bodyABC"))     // message body not listed
    }

    @Test func calendarEventsRendersRows() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"items":[{"id":"e1","summary":"Standup","#
            + #""start":{"dateTime":"2026-06-02T10:00:00Z"}}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog calendar events")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("e1\t2026-06-02T10:00:00Z\tStandup"))
    }

    @Test func calendarCreateDryRunDoesNotCreate() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing(
            "gog calendar create --summary Standup"
            + " --start 2026-06-02T10:00:00Z --end 2026-06-02T10:30:00Z --dry-run")
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("Standup"))
    }

    @Test func calendarCreatePostsId() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"id":"evt1"}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing(
                    "gog calendar create --summary Standup"
                    + " --start 2026-06-02T10:00:00Z --end 2026-06-02T10:30:00Z")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("created: evt1"))
    }

    @Test func calendarCalendarsRenders() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"items":[{"id":"primary","summary":"Me","accessRole":"owner","primary":true}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog calendar calendars")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("primary\tMe\towner\tprimary"))
    }

    @Test func calendarCalendarsRejectsBadMax() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing("gog calendar calendars --max 0")
        #expect(run.exitStatus == ExitStatus(2))
    }

    @Test func calendarFreeBusyRenders() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"calendars":{"primary":{"busy":[{"start":"2026-06-02T10:00:00Z","#
            + #""end":"2026-06-02T11:00:00Z"}]}}}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog calendar freebusy")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("primary\t2026-06-02T10:00:00Z\t2026-06-02T11:00:00Z"))
    }

    @Test func calendarFreeBusyOrdersCalendarsStably() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        // Returned out of order; output must be sorted by calendar id.
        let json = #"{"calendars":{"b@x.com":{"busy":[{"start":"S2","end":"E2"}]},"#
            + #""a@x.com":{"busy":[{"start":"S1","end":"E1"}]}}}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing(
                    "gog calendar freebusy --calendar a@x.com --calendar b@x.com")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("a@x.com\tS1\tE1"))
        #expect(run.stdout.contains("b@x.com\tS2\tE2"))
        let a = run.stdout.range(of: "a@x.com")
        let b = run.stdout.range(of: "b@x.com")
        #expect(a != nil && b != nil && a!.lowerBound < b!.lowerBound)
    }

    @Test func calendarFreeBusyDefaultsEndToStartPlus24h() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"calendars":{}}"#.utf8)))
        // Future --from, no --to: timeMax must be 24h after the start, not now,
        // so the window stays valid (timeMin < timeMax).
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing(
                    "gog calendar freebusy --from 2030-01-01T00:00:00Z")
            }
        }
        #expect(run.exitStatus == .success)
        let sent = String(decoding: transport.lastBody ?? Data(), as: UTF8.self)
        #expect(sent.contains(#""timeMin":"2030-01-01T00:00:00Z""#))
        #expect(sent.contains(#""timeMax":"2030-01-02T00:00:00Z""#))
    }

    @Test func httpErrorSurfacesGoogleMessage() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let errorBody = #"{"error":{"code":404,"message":"File not found."}}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 404, body: Data(errorBody.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive get abc")
            }
        }
        #expect(run.exitStatus != .success)
        #expect(run.stderr.contains("File not found."))
    }

    @Test func httpErrorHintsApiNotEnabled() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let body = #"{"error":{"code":403,"status":"PERMISSION_DENIED","message":"Drive API has not been used in project 123 before or it is disabled. See https://console.developers.google.com/apis/api/drive.googleapis.com/overview","errors":[{"reason":"accessNotConfigured"}]}}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 403, body: Data(body.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive ls")
            }
        }
        #expect(run.exitStatus != .success)
        #expect(run.stderr.contains("Drive API is not enabled"))
        #expect(run.stderr.contains(
            "console.developers.google.com/apis/api/drive.googleapis.com"))
    }

    @Test func httpErrorHintsInsufficientScope() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let body = #"{"error":{"code":403,"status":"PERMISSION_DENIED","message":"Request had insufficient authentication scopes.","errors":[{"reason":"ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 403, body: Data(body.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive ls")
            }
        }
        #expect(run.exitStatus != .success)
        #expect(run.stderr.contains("lacks the scope"))
        #expect(run.stderr.contains("host must grant"))
    }

    @Test func httpErrorHintsRateLimit() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let body = #"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message":"Quota exceeded.","errors":[{"reason":"rateLimitExceeded"}]}}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 429, body: Data(body.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive ls")
            }
        }
        #expect(run.exitStatus != .success)
        #expect(run.stderr.contains("Rate limited"))
        #expect(run.stderr.contains("backoff"))
    }

    @Test func httpErrorHintsApiHostWithTrailingPunctuation() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        // The API host sits at a sentence end ("…gmail.googleapis.com.") — the
        // trailing dot must not defeat host matching.
        let body = #"{"error":{"code":403,"status":"PERMISSION_DENIED","message":"Gmail API has not been used in project 9 before or it is disabled. Enable gmail.googleapis.com.","errors":[{"reason":"accessNotConfigured"}]}}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 403, body: Data(body.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog gmail messages")
            }
        }
        #expect(run.exitStatus != .success)
        #expect(run.stderr.contains("Gmail API is not enabled"))
    }

    @Test func driveGetEscapesUnsafeId() async throws {
        // A space/slash in the id would crash a force-unwrapped URL; the
        // percent-encoding path must keep it a normal request.
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"id":"x","name":"f","mimeType":"text/plain"}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive get 'a b/c'")
            }
        }
        #expect(run.exitStatus == .success)
    }

    @Test func driveUploadReadsMountAndPosts() async throws {
        let mounted = MountedFileSystem(
            mounts: [.init(virtual: "/gog", host: "/gog")],
            backing: InMemoryFileSystem())
        let shell = Shell(fileSystem: mounted)
        try await shell.fileSystem.createDirectory("/gog", intermediates: true)
        try await shell.fileSystem.writeData(Data("hello".utf8), to: "/gog/f.txt", append: false)
        shell.registerGogCommands()
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"id":"up1","name":"f.txt"}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive upload /gog/f.txt --name f.txt")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("uploaded: up1\tf.txt"))
    }

    @Test func driveUploadRejectsMissingFile() async throws {
        let mounted = MountedFileSystem(
            mounts: [.init(virtual: "/gog", host: "/gog")],
            backing: InMemoryFileSystem())
        let shell = Shell(fileSystem: mounted)
        try await shell.fileSystem.createDirectory("/gog", intermediates: true)
        shell.registerGogCommands()
        // Missing file is caught before any network/credential use.
        let run = try await shell.runCapturing("gog drive upload /gog/missing.txt")
        #expect(run.exitStatus == ExitStatus(2))
    }

    @Test func driveDownloadKeepsExistingFileWhenFetchFails() async throws {
        let mounted = MountedFileSystem(
            mounts: [.init(virtual: "/gog", host: "/gog")],
            backing: InMemoryFileSystem())
        let shell = Shell(fileSystem: mounted)
        try await shell.fileSystem.createDirectory("/gog", intermediates: true)
        try await shell.fileSystem.writeData(
            Data("ORIGINAL".utf8), to: "/gog/keep.bin", append: false)
        shell.registerGogCommands()
        // A failed (404) download must not have truncated the existing file.
        let transport = MockTransport(response: HTTPResponse(
            status: 404, body: Data(#"{"error":{"message":"nope"}}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive download FILEID --out /gog/keep.bin")
            }
        }
        #expect(run.exitStatus != .success)
        let kept = try await shell.fileSystem.readData("/gog/keep.bin")
        #expect(String(decoding: kept, as: UTF8.self) == "ORIGINAL")
    }

    @Test func gogLsAliasListsDrive() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"files":[{"id":"a","name":"n","mimeType":"text/plain"}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog ls")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("a\tn\ttext/plain"))
    }

    @Test func gogSendAliasDryRun() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing(
            "gog send --to a@b.com --subject Hi --body Yo --dry-run")
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("a@b.com"))
    }

    @Test func contactsListRenders() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"connections":[{"resourceName":"people/c1","#
            + #""names":[{"displayName":"Ada"}],"#
            + #""emailAddresses":[{"value":"ada@x.com"}]}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog contacts list")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("people/c1\tAda\tada@x.com"))
    }

    @Test func contactsGetRenders() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"resourceName":"people/c1","names":[{"displayName":"Ada"}],"#
            + #""emailAddresses":[{"value":"ada@x.com"}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog contacts get people/c1")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("Ada <ada@x.com>"))
    }

    @Test func contactsSearchRenders() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"results":[{"person":{"resourceName":"people/c1","names":[{"displayName":"Ada"}],"emailAddresses":[{"value":"ada@x.com"}]}}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog contacts search ada")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("people/c1\tAda\tada@x.com"))
    }

    @Test func contactsSearchHitsSearchEndpoint() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"results":[]}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog contacts search ada")
            }
        }
        #expect(run.exitStatus == .success)
        let url = transport.lastURL?.absoluteString ?? ""
        #expect(url.contains("searchContacts"))
        #expect(url.contains("query=ada"))
    }

    @Test func contactsSearchSendsWarmupFirst() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"results":[]}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog contacts search ada")
            }
        }
        #expect(run.exitStatus == .success)
        // searchContacts requires an empty-query warmup before the real search.
        #expect(transport.urls.count == 2)
        #expect(transport.urls.first?.absoluteString.contains("query=ada") == false)
        #expect(transport.urls.last?.absoluteString.contains("query=ada") == true)
    }

    @Test func contactsSearchRejectsBadMax() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing("gog contacts search ada --max 31")
        #expect(run.exitStatus == ExitStatus(2))
    }

    @Test func contactsOtherRenders() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"otherContacts":[{"resourceName":"otherContacts/o1","names":[{"displayName":"Bob"}],"emailAddresses":[{"value":"bob@x.com"}]}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog contacts other")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("otherContacts/o1\tBob\tbob@x.com"))
    }

    @Test func tasksListsRenders() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"items":[{"id":"L1","title":"My List"}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog tasks lists")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("L1\tMy List"))
    }

    @Test func tasksListRenders() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"items":[{"id":"T1","title":"Buy milk","status":"needsAction"}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog tasks list")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("T1\tneedsAction\tBuy milk"))
    }

    @Test func tasksAddPosts() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"id":"T9"}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog tasks add 'Buy milk'")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("added: T9"))
    }

    @Test func tasksListSurfacesNextPageToken() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"items":[{"id":"T1","title":"x","status":"needsAction"}],"#
            + #""nextPageToken":"NPT"}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog tasks list --page PREV")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stderr.contains("next page token: NPT"))
    }

    @Test func tasksListsSurfacesNextPageToken() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"items":[{"id":"L1","title":"x"}],"nextPageToken":"NPT2"}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog tasks lists --page PREV")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stderr.contains("next page token: NPT2"))
    }

    @Test func tasksListsAcceptsLargeMax() async throws {
        // tasklists.list allows maxResults up to 1000 (tasks.list is capped at 100).
        let shell = Shell()
        shell.registerGogCommands()
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"items":[]}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog tasks lists --max 500")
            }
        }
        #expect(run.exitStatus == .success)
    }

    @Test func docsCatExportsText() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data("Hello doc".utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog docs cat DOCID")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("Hello doc"))
    }

    @Test func sheetsGetRendersMixedTypeTSV() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"range":"Sheet1!A1:C1","values":[["x",5,true]]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog sheets get SID 'Sheet1!A1:C1'")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("x\t5\tTRUE"))
    }

    @Test func sheetsUpdatePutsAndReportsCells() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"updatedCells":2}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing(
                    "gog sheets update SID 'Sheet1!A1' --values-json '[[\"a\",\"b\"]]'")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("updated 2 cells"))
    }

    @Test func sheetsUpdateDryRunDoesNotWrite() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing(
            "gog sheets update SID 'Sheet1!A1' --values-json '[[\"a\"]]' --dry-run")
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("\"a\""))
    }

    @Test func sheetsUpdateRejectsBadJSON() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing(
            "gog sheets update SID 'Sheet1!A1' --values-json nope")
        #expect(run.exitStatus == ExitStatus(2))
    }

    @Test func sheetsGetEncodesSlashInRange() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"values":[]}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog sheets get SID 'Q1/Q2!A1'")
            }
        }
        #expect(run.exitStatus == .success)
        // The "/" inside the sheet name must be encoded, not a path separator.
        #expect(transport.lastURL?.absoluteString.contains("Q1%2FQ2") == true)
    }

    @Test func sheetsUpdateClearsCellForNull() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        // --dry-run prints the encoded body; null must become "" so the cell is
        // cleared (Sheets skips JSON null on update).
        let run = try await shell.runCapturing(
            "gog sheets update SID 'A1' --values-json '[[\"x\",null]]' --dry-run")
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains(#"["x",""]"#))
        #expect(!run.stdout.contains("null"))
    }

    @Test func sheetsUpdatePreservesLargeIntegers() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        // 9007199254740993 > 2^53 would round if decoded through Double.
        let run = try await shell.runCapturing(
            "gog sheets update SID 'A1' --values-json '[[9007199254740993]]' --dry-run")
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("9007199254740993"))
    }

    @Test func sheetsUpdateRejectsObjectCell() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing(
            "gog sheets update SID 'A1' --values-json '[[{}]]'")
        #expect(run.exitStatus == ExitStatus(2))
    }

    @Test func sheetsGetEscapesDelimitersInCells() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        // Cell value "a\nb" (real newline) must render on one row, escaped.
        let json = #"{"values":[["a\nb","c"]]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog sheets get SID 'Sheet1!A1:B1'")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains(#"a\nb"# + "\tc"))
    }

    @Test func sheetsGetPadsTrailingEmptyCells() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        // A1:C1 with only A1 populated must still render three columns.
        let json = #"{"range":"Sheet1!A1:C1","values":[["x"]]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog sheets get SID 'Sheet1!A1:C1'")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("x\t\t"))
    }

    @Test func sheetsUpdateRejectsOversizedInteger() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing(
            "gog sheets update SID 'A1' --values-json '[[9223372036854775808]]'")
        #expect(run.exitStatus == ExitStatus(2))
    }

    @Test func docsCatValidatesOutBeforeExport() async throws {
        let mounted = MountedFileSystem(
            mounts: [.init(virtual: "/gog", host: "/gog")],
            backing: InMemoryFileSystem())
        let shell = Shell(fileSystem: mounted)
        try await shell.fileSystem.createDirectory("/gog", intermediates: true)
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data("doc".utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog docs cat DOCID --out /etc/x.txt")
            }
        }
        #expect(run.exitStatus == ExitStatus(23))
        #expect(transport.lastURL == nil)   // export not performed for a bad dest
    }

    @Test func sheetsGetPadsTrailingEmptyRows() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        // A1:A3 with only A1 populated must still render three rows.
        let json = #"{"range":"Sheet1!A1:A3","values":[["x"]]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog sheets get SID 'Sheet1!A1:A3'")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout == "x\n\n\n")
    }

    @Test func docsCatDoesNotTouchSiblingPrecheckFile() async throws {
        let mounted = MountedFileSystem(
            mounts: [.init(virtual: "/gog", host: "/gog")],
            backing: InMemoryFileSystem())
        let shell = Shell(fileSystem: mounted)
        try await shell.fileSystem.createDirectory("/gog", intermediates: true)
        // A real file a fixed-name probe would have clobbered.
        try await shell.fileSystem.writeData(
            Data("keep".utf8), to: "/gog/doc.md.gog-precheck", append: false)
        shell.registerGogCommands()
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data("exported".utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog docs cat DOCID --out /gog/doc.md")
            }
        }
        #expect(run.exitStatus == .success)
        let sibling = try await shell.fileSystem.readData("/gog/doc.md.gog-precheck")
        #expect(String(decoding: sibling, as: UTF8.self) == "keep")
    }

    @Test func chatSpacesRenders() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"spaces":[{"name":"spaces/AAA","displayName":"Team"}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog chat spaces")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("spaces/AAA\tTeam"))
    }

    @Test func chatMessagesEscapesText() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"messages":[{"name":"spaces/AAA/messages/1","text":"line1\nline2"}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog chat messages spaces/AAA")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains(#"line1\nline2"#))   // newline escaped, one row
    }

    @Test func chatSendDryRun() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing(
            "gog chat send spaces/AAA --text Hello --dry-run")
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("Hello"))
    }

    @Test func chatSendBlockedByPolicy() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await GogPolicies.$current.withValue(
            GogPolicy(chatSendDisabled: true)
        ) {
            try await shell.runCapturing("gog chat send spaces/AAA --text Hello")
        }
        #expect(run.exitStatus == ExitStatus(3))
    }

    @Test func chatSendPosts() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = MockTransport(response: HTTPResponse(
            status: 200, body: Data(#"{"name":"spaces/AAA/messages/9"}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog chat send spaces/AAA --text Hello")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("sent: spaces/AAA/messages/9"))
    }

    @Test func slidesExportWritesToMount() async throws {
        let mounted = MountedFileSystem(
            mounts: [.init(virtual: "/gog", host: "/gog")],
            backing: InMemoryFileSystem())
        let shell = Shell(fileSystem: mounted)
        try await shell.fileSystem.createDirectory("/gog", intermediates: true)
        shell.registerGogCommands()
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data("PDFDATA".utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog slides export PID --out /gog/deck.pdf")
            }
        }
        #expect(run.exitStatus == .success)
        let saved = try await shell.fileSystem.readData("/gog/deck.pdf")
        #expect(String(decoding: saved, as: UTF8.self) == "PDFDATA")
    }

    @Test func formsGetRenders() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"info":{"title":"Survey"},"items":[{},{}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog forms get FID")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("Survey\t2 items"))
    }

    @Test func formsResponsesRenders() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"responses":[{"responseId":"r1","createTime":"2026-06-02T00:00:00Z"}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog forms responses FID")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("r1\t2026-06-02T00:00:00Z"))
    }

    @Test func formsResponsesRejectsBadMax() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing("gog forms responses FID --max 0")
        #expect(run.exitStatus == ExitStatus(2))
    }

    @Test func gmailLabelsRenders() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"labels":[{"id":"INBOX","name":"INBOX"}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog gmail labels")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("INBOX\tINBOX"))
    }

    @Test func youtubeMyChannelRenders() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"items":[{"snippet":{"title":"My Channel"},"#
            + #""statistics":{"subscriberCount":"100","videoCount":"5"}}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog youtube my-channel")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("My Channel\tsubscribers=100\tvideos=5"))
    }

    @Test func youtubeSearchRenders() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"items":[{"id":{"videoId":"abc"},"snippet":{"title":"Video"}}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog youtube search swift")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("abc\tVideo"))
    }

    @Test func youtubePlaylistsRenders() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"items":[{"id":"PL1","snippet":{"title":"Faves"}}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog youtube playlists")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("PL1\tFaves"))
    }

    @Test func youtubeMyChannelExitsNonZeroWhenNoChannel() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"items":[]}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog youtube my-channel")
            }
        }
        #expect(run.exitStatus != .success)
    }

    @Test func youtubeSearchRejectsBadMax() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing("gog youtube search swift --max 0")
        #expect(run.exitStatus == ExitStatus(2))
    }

    @Test func adminUsersRenders() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"users":[{"primaryEmail":"alice@x.com","#
            + #""name":{"fullName":"Alice A"},"suspended":false}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog admin users")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("alice@x.com\tAlice A\tactive"))
    }

    @Test func adminUsersDefaultsToMyCustomer() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"users":[]}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog admin users")
            }
        }
        #expect(run.exitStatus == .success)
        let url = transport.lastURL?.absoluteString ?? ""
        #expect(url.contains("/admin/directory/v1/users"))
        #expect(url.contains("customer=my_customer"))
    }

    @Test func adminUsersRejectsBadMax() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing("gog admin users --max 0")
        #expect(run.exitStatus == ExitStatus(2))
    }

    @Test func adminUserGetRendersAdminFlag() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"primaryEmail":"alice@x.com","name":{"fullName":"Alice A"},"#
            + #""isAdmin":true,"orgUnitPath":"/Sales"}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog admin user alice@x.com")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("Alice A <alice@x.com>"))
        #expect(run.stdout.contains("orgUnit=/Sales"))
        #expect(run.stdout.contains("admin"))
    }

    @Test func adminGroupsRenders() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"groups":[{"email":"eng@x.com","name":"Engineering","#
            + #""directMembersCount":"3"}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog admin groups")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("eng@x.com\tEngineering\tmembers=3"))
    }

    @Test func adminGroupsForUserUsesUserKey() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"groups":[]}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog admin groups --user alice@x.com")
            }
        }
        #expect(run.exitStatus == .success)
        let url = transport.lastURL?.absoluteString ?? ""
        // --user means "groups this user belongs to": userKey, not customer.
        #expect(url.contains("userKey=alice"))
        #expect(!url.contains("customer="))
    }

    @Test func adminMembersRenders() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"members":[{"email":"bob@x.com","role":"OWNER","type":"USER"}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog admin members eng@x.com")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("bob@x.com\tOWNER\tUSER"))
    }

    @Test func adminMembersEncodesSlashInGroupKey() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"members":[]}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog admin members 'a/b@x.com'")
            }
        }
        #expect(run.exitStatus == .success)
        let url = transport.lastURL?.absoluteString ?? ""
        // A "/" inside the key must be encoded so it can't add a path segment.
        #expect(url.contains("a%2Fb"))
        #expect(url.contains("/members"))
    }

    @Test func adminUserGetEscapesTabInName() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        // The JSON "\t" decodes to a real tab; the single-line output is
        // tab-delimited, so the name must be re-escaped to "\t" rather than
        // opening a phantom column.
        let json = #"{"name":{"fullName":"A\tB"},"primaryEmail":"a@x.com"}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog admin user a@x.com")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains(#"A\tB"#))
        #expect(!run.stdout.contains("A\tB"))
    }

    @Test func adminActivitiesRenders() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"items":[{"id":{"time":"2026-06-01T00:00:00Z"},"#
            + #""actor":{"email":"alice@x.com"},"#
            + #""events":[{"name":"login_success"}]}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog admin activities login")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("2026-06-01T00:00:00Z\talice@x.com\tlogin_success"))
    }

    @Test func adminActivitiesDefaultsToAllUsersAndPassesEvent() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"items":[]}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing(
                    "gog admin activities login --event login_success")
            }
        }
        #expect(run.exitStatus == .success)
        let url = transport.lastURL?.absoluteString ?? ""
        #expect(url.contains("/activity/users/all/applications/login"))
        #expect(url.contains("eventName=login_success"))
    }

    @Test func adminActivitiesRejectsBadMax() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing("gog admin activities login --max 0")
        #expect(run.exitStatus == ExitStatus(2))
    }

    @Test func writesOutsideTheMountAreRejected() async throws {
        let mounted = MountedFileSystem(
            mounts: [.init(virtual: "/gog", host: "/gog")],
            backing: InMemoryFileSystem())
        let shell = Shell(fileSystem: mounted)
        try await shell.fileSystem.createDirectory("/gog", intermediates: true)
        shell.registerGogCommands()

        // Inside the mount: succeeds and the bytes land in the sandbox.
        let ok = try await shell.runCapturing("gog version --out /gog/v.txt")
        #expect(ok.exitStatus == .success)
        let saved = try await shell.fileSystem.readData("/gog/v.txt")
        #expect(String(decoding: saved, as: UTF8.self)
            .contains("gog \(GogVersionInfo.version)"))

        // Outside every mount: rejected by MountedFileSystem → non-zero exit.
        let denied = try await shell.runCapturing("gog version --out /etc/v.txt")
        #expect(denied.exitStatus != .success)
    }
}
