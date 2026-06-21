import Testing
import Foundation
import BashInterpreter
import BashCommandKit   // registerStandardCommands() — imported explicitly, not via GogShell
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
    var lastMethod: String?
    var urls: [URL] = []
    init(response: HTTPResponse) { self.response = response }
    func send(method: String, url: URL,
              headers: [String: String], body: Data?) async throws -> HTTPResponse {
        lastURL = url
        lastBody = body
        lastMethod = method
        urls.append(url)
        return response
    }
}

/// Binds a host `GogWriteTier` around each test in the suite, so the gated write
/// commands execute under test without per-test policy plumbing. Tests that
/// verify the gate itself re-bind a lower tier inline (the inner bind wins).
struct WriteTierTrait: SuiteTrait, TestTrait {
    let tier: GogWriteTier
    func scopeProvider(for test: Test, testCase: Test.Case?) -> Scope? {
        Scope(tier: tier)
    }
    struct Scope: TestScoping {
        let tier: GogWriteTier
        func provideScope(
            for test: Test, testCase: Test.Case?,
            performing function: @Sendable () async throws -> Void
        ) async throws {
            try await GogPolicies.$current.withValue(GogPolicy(writeTier: tier)) {
                try await function()
            }
        }
    }
}

extension Trait where Self == WriteTierTrait {
    /// Bind a host write tier for the annotated suite/test.
    static func writeTier(_ tier: GogWriteTier) -> Self { WriteTierTrait(tier: tier) }
}

/// Wiring + behaviour tests: `gog` registered into a sandboxed `Shell` and run
/// through `runCapturing`. Covers the fail-closed sandbox contracts (deny
/// paths) and command happy paths via an injected fake `GogTransport`.
/// Runs at the `.full` write tier so the gated write commands execute; the
/// dedicated gate tests re-bind a lower tier inline to prove the gate blocks.
@Suite(.writeTier(.full)) struct GogWiringTests {

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

    @Test func failEmptyExitsThreeOnEmptyListing() async throws {
        // --fail-empty: an empty listing exits 3 (gogcli's empty-results code).
        let shell = Shell()
        shell.registerGogCommands()
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"files":[]}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive ls --fail-empty")
            }
        }
        #expect(run.exitStatus == ExitStatus(3))
    }

    @Test func emptyListingSucceedsWithoutFailEmpty() async throws {
        // Default: an empty listing is success (exit 0) with a "No X" hint.
        let shell = Shell()
        shell.registerGogCommands()
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"files":[]}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive ls")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stderr.contains("No files"))
    }

    @Test func failEmptyAliasNonEmptyOnInlineCommand() async throws {
        // The --non-empty alias works, and on a non-shared-helper command.
        let shell = Shell()
        shell.registerGogCommands()
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"users":[]}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog admin users --non-empty")
            }
        }
        #expect(run.exitStatus == ExitStatus(3))
    }

    @Test func failEmptyHonoredInJsonMode() async throws {
        // --json --fail-empty must still exit 3 on an empty listing.
        let shell = Shell()
        shell.registerGogCommands()
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"files":[]}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive ls --json --fail-empty")
            }
        }
        #expect(run.exitStatus == ExitStatus(3))
    }

    @Test func failEmptyDoesNotFireWhenMorePages() async throws {
        // An empty page with a nextPageToken means more may follow — don't fail.
        let shell = Shell()
        shell.registerGogCommands()
        let transport = MockTransport(
            response: HTTPResponse(
                status: 200, body: Data(#"{"files":[],"nextPageToken":"more"}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive ls --fail-empty")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stderr.contains("next page token: more"))
    }

    @Test func failEmptyTreatsOmittedArrayAsEmptyInJsonMode() async throws {
        // Sheets omits `values` entirely for an empty range; --json --fail-empty
        // must still exit 3, matching the non-JSON `values ?? []` path.
        let shell = Shell()
        shell.registerGogCommands()
        let transport = MockTransport(
            response: HTTPResponse(
                status: 200,
                body: Data(#"{"range":"Sheet1!A1:B2","majorDimension":"ROWS"}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog sheets get sheet1 A1:B2 --json --fail-empty")
            }
        }
        #expect(run.exitStatus == ExitStatus(3))
    }

    @Test func failEmptyChecksResultArrayNotSiblingInJsonMode() async throws {
        // Calendar event listings carry a sibling `defaultReminders` array; an
        // empty sibling next to a non-empty `items` must NOT count as empty.
        let shell = Shell()
        shell.registerGogCommands()
        let transport = MockTransport(
            response: HTTPResponse(
                status: 200,
                body: Data(#"{"defaultReminders":[],"items":[{"id":"e1"}]}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog calendar events --json --fail-empty")
            }
        }
        #expect(run.exitStatus == .success)
    }

    @Test func driveSearchRequestsNextPageToken() async throws {
        // DriveSearch's field mask must include nextPageToken so the
        // pagination-aware --fail-empty guard can see when more pages exist.
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"files":[]}"#.utf8)))
        _ = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive search report --json")
            }
        }
        #expect(transport.lastURL?.absoluteString.contains("nextPageToken") == true)
    }

    @Test func driveSearchAcceptsPageToken() async throws {
        // A nextPageToken surfaced by search must be feedable back via --page,
        // so a paging script isn't stuck with a token it can't use.
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"files":[]}"#.utf8)))
        _ = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive search report --page TOK123")
            }
        }
        #expect(transport.lastURL?.absoluteString.contains("pageToken=TOK123") == true)
    }

    @Test func calendarEventsPageRequiresFrom() async throws {
        // Paging calendar events needs an explicit --from so the next request
        // replays the original time window (validation precedes any network use).
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing("gog calendar events --page TOK")
        #expect(run.exitStatus == ExitStatus(2))
        #expect(run.stderr.contains("--page requires --from"))
        // The hint names the concrete fix: replay the original request's options.
        #expect(run.stderr.contains("Repeat the original options"))
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

    @Test func calendarEventsTokenEchoesReplayCommand() async throws {
        // A surfaced page token must be spendable: the hint echoes a ready-to-run
        // next-page command carrying the exact --from (the window the token is
        // tied to), --max, and token, so the follow-up replays the same request.
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"items":[{"id":"e1","summary":"Standup","#
            + #""start":{"dateTime":"2026-06-02T10:00:00Z"}}],"nextPageToken":"NPT"}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing(
                    "gog calendar events --from 2026-06-02T00:00:00Z --max 5")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stderr.contains("next page token: NPT"))
        #expect(run.stderr.contains(
            "next page: gog calendar events --from 2026-06-02T00:00:00Z --max 5 --page NPT"))
    }

    @Test func calendarEventsTokenEchoesGeneratedFromWhenDefaulted() async throws {
        // Without --from the request uses a generated timeMin the caller never
        // typed; the token is unusable unless the hint echoes that value. The
        // echoed command must therefore carry a concrete --from and the token.
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"items":[{"id":"e1","summary":"x","#
            + #""start":{"dateTime":"2026-06-02T10:00:00Z"}}],"nextPageToken":"NPT"}"#
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
        #expect(run.stderr.contains("next page: gog calendar events --from "))
        #expect(run.stderr.contains("--page NPT"))
    }

    @Test func calendarEventsJsonModeEchoesNextPage() async throws {
        // --json returns early; the token in the raw response is still un-spendable
        // (Google omits the generated timeMin), so the replay hint must fire here
        // too — on stderr, leaving stdout pure JSON.
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"items":[{"id":"e1"}],"nextPageToken":"NPT"}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog calendar events --json")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("nextPageToken"))
        #expect(run.stderr.contains("next page: gog calendar events --from "))
        #expect(run.stderr.contains("--page NPT"))
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

    @Test func calendarFreeBusyErrorsExitNonZeroNotEmpty() async throws {
        // A calendar that reports errors[] failed to compute — it must not read
        // as "free". With no busy slots it would otherwise hit the empty path;
        // instead it exits non-zero (reason on stderr), even without --fail-empty.
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"calendars":{"bad@x.com":{"errors":[{"reason":"notFound"}]}}}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog calendar freebusy --calendar bad@x.com")
            }
        }
        #expect(run.exitStatus == ExitStatus(1))
        #expect(run.stderr.contains("bad@x.com: notFound"))
    }

    @Test func calendarFreeBusyJsonErrorsExitNonZeroNotEmpty() async throws {
        // Same contract in --json --fail-empty mode: errors[] must surface as a
        // non-zero exit, not the empty/exit-3 "no conflicts" signal.
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"calendars":{"bad@x.com":{"errors":[{"reason":"notFound"}]}}}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing(
                    "gog calendar freebusy --calendar bad@x.com --json --fail-empty")
            }
        }
        #expect(run.exitStatus == ExitStatus(1))
        #expect(run.stdout.contains("notFound"))
    }

    @Test func calendarFreeBusyGroupErrorsExitNonZeroNotEmpty() async throws {
        // A queried Google Group whose expansion fails appears only under
        // groups.<id>.errors[] (no calendars entry). That's a failed lookup, so
        // --json --fail-empty must exit non-zero, not exit 3 ("no conflicts").
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"groups":{"team@x.com":{"errors":[{"reason":"notFound"}]}},"calendars":{}}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing(
                    "gog calendar freebusy --calendar team@x.com --json --fail-empty")
            }
        }
        #expect(run.exitStatus == ExitStatus(1))
    }

    @Test func calendarFreeBusyGroupErrorsHumanModeExitNonZero() async throws {
        // Same in human mode: the group's failure reason is surfaced on stderr
        // and the command exits non-zero instead of the empty path.
        let shell = Shell()
        shell.registerGogCommands()
        let json = #"{"groups":{"team@x.com":{"errors":[{"reason":"notFound"}]}},"calendars":{}}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog calendar freebusy --calendar team@x.com")
            }
        }
        #expect(run.exitStatus == ExitStatus(1))
        #expect(run.stderr.contains("team@x.com: notFound"))
    }

    // MARK: - Writes: Calendar update / delete

    @Test func calendarUpdateRequiresAField() async throws {
        // PATCH with nothing to change is a no-op mistake — reject pre-network.
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await GogPolicies.$current.withValue(GogPolicy(writeTier: .edit)) {
            try await shell.runCapturing("gog calendar update E1")
        }
        #expect(run.exitStatus == ExitStatus(2))
        #expect(run.stderr.contains("at least one of"))
    }

    @Test func calendarUpdateDryRunDoesNotWrite() async throws {
        // Validation + payload build precede any network, so no transport needed.
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await GogPolicies.$current.withValue(GogPolicy(writeTier: .edit)) {
            try await shell.runCapturing(
                "gog calendar update E1 --summary Renamed --dry-run")
        }
        #expect(run.exitStatus == .success)
        #expect(run.stderr.contains("dry-run: not updating"))
        #expect(run.stdout.contains("Renamed"))
    }

    @Test func calendarUpdatePatchesAndEmitsId() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200,
                body: Data(#"{"id":"E1","summary":"Renamed"}"#.utf8)))
        let run = try await GogPolicies.$current.withValue(GogPolicy(writeTier: .edit)) {
            try await GogTransportProvider.$current.withValue(transport) {
                try await GogCredentials.$current.withValue(
                    StubProvider(token: "t", accountHint: nil)
                ) {
                    try await shell.runCapturing("gog calendar update E1 --summary Renamed")
                }
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("updated: E1"))
        #expect(transport.lastMethod == "PATCH")
        #expect(transport.lastURL?.absoluteString.hasSuffix("/events/E1") == true)
    }

    @Test func calendarDeleteDryRunDoesNotDelete() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await GogPolicies.$current.withValue(GogPolicy(writeTier: .full)) {
            try await shell.runCapturing("gog calendar delete E1 --dry-run")
        }
        #expect(run.exitStatus == .success)
        #expect(run.stderr.contains("dry-run: not deleting"))
        #expect(run.stdout.contains("would delete: E1"))
    }

    @Test func calendarDeleteSendsDeleteAndConfirms() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 204, body: Data()))
        let run = try await GogPolicies.$current.withValue(GogPolicy(writeTier: .full)) {
            try await GogTransportProvider.$current.withValue(transport) {
                try await GogCredentials.$current.withValue(
                    StubProvider(token: "t", accountHint: nil)
                ) {
                    try await shell.runCapturing("gog calendar delete E1")
                }
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("deleted: E1"))
        #expect(transport.lastMethod == "DELETE")
        #expect(transport.lastURL?.absoluteString.hasSuffix("/events/E1") == true)
    }

    // MARK: - Writes: Tasks complete / delete

    @Test func tasksCompleteDryRunDoesNotWrite() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await GogPolicies.$current.withValue(GogPolicy(writeTier: .edit)) {
            try await shell.runCapturing("gog tasks complete T1 --dry-run")
        }
        #expect(run.exitStatus == .success)
        #expect(run.stderr.contains("dry-run: not completing"))
        #expect(run.stdout.contains("would complete: T1"))
    }

    @Test func tasksCompletePatchesStatusAndEmitsId() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200,
                body: Data(#"{"id":"T1","status":"completed"}"#.utf8)))
        let run = try await GogPolicies.$current.withValue(GogPolicy(writeTier: .edit)) {
            try await GogTransportProvider.$current.withValue(transport) {
                try await GogCredentials.$current.withValue(
                    StubProvider(token: "t", accountHint: nil)
                ) {
                    try await shell.runCapturing("gog tasks complete T1")
                }
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("completed: T1"))
        #expect(transport.lastMethod == "PATCH")
        #expect(transport.lastURL?.absoluteString.contains("/@default/tasks/T1") == true)
        // The PATCH body flips status to completed.
        #expect(String(decoding: transport.lastBody ?? Data(), as: UTF8.self)
            .contains("completed"))
    }

    @Test func tasksDeleteSendsDeleteToListPath() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 204, body: Data()))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog tasks delete T1 --list L9")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("deleted: T1"))
        #expect(transport.lastMethod == "DELETE")
        #expect(transport.lastURL?.absoluteString.contains("/lists/L9/tasks/T1") == true)
    }

    // MARK: - Writes: Gmail modify / trash / untrash

    @Test func gmailModifyRequiresALabel() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing("gog gmail modify M1")
        #expect(run.exitStatus == ExitStatus(2))
        #expect(run.stderr.contains("--add-label"))
    }

    @Test func gmailModifyDryRunDoesNotWrite() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing(
            "gog gmail modify M1 --remove-label UNREAD --dry-run")
        #expect(run.exitStatus == .success)
        #expect(run.stderr.contains("dry-run: not modifying"))
        #expect(run.stdout.contains("UNREAD"))
    }

    @Test func gmailModifyPostsToModifyEndpoint() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"id":"M1"}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing(
                    "gog gmail modify M1 --add-label STARRED --remove-label UNREAD")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("modified: M1"))
        #expect(transport.lastMethod == "POST")
        #expect(transport.lastURL?.absoluteString.hasSuffix("/messages/M1/modify") == true)
        let body = String(decoding: transport.lastBody ?? Data(), as: UTF8.self)
        #expect(body.contains("addLabelIds") && body.contains("STARRED"))
        #expect(body.contains("removeLabelIds") && body.contains("UNREAD"))
    }

    @Test func gmailTrashDryRunDoesNotTrash() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing("gog gmail trash M1 --dry-run")
        #expect(run.exitStatus == .success)
        #expect(run.stderr.contains("dry-run: not trashing"))
        #expect(run.stdout.contains("would trash: M1"))
    }

    @Test func gmailTrashPostsToTrashEndpoint() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"id":"M1"}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog gmail trash M1")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("trashed: M1"))
        #expect(transport.lastMethod == "POST")
        #expect(transport.lastURL?.absoluteString.hasSuffix("/messages/M1/trash") == true)
    }

    @Test func gmailUntrashPostsToUntrashEndpoint() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"id":"M1"}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog gmail untrash M1")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("untrashed: M1"))
        #expect(transport.lastURL?.absoluteString.hasSuffix("/messages/M1/untrash") == true)
    }

    // MARK: - Writes: Drive trash / untrash / rename / mkdir

    @Test func driveTrashDryRunDoesNotTrash() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing("gog drive trash F1 --dry-run")
        #expect(run.exitStatus == .success)
        #expect(run.stderr.contains("dry-run: not trashing"))
        #expect(run.stdout.contains("would trash: F1"))
    }

    @Test func driveTrashPatchesTrashedTrue() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"id":"F1"}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive trash F1")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("trashed: F1"))
        #expect(transport.lastMethod == "PATCH")
        #expect(transport.lastURL?.absoluteString.contains("/files/F1") == true)
        #expect(transport.lastURL?.absoluteString.contains("supportsAllDrives=true") == true)
        #expect(String(decoding: transport.lastBody ?? Data(), as: UTF8.self)
            .contains(#""trashed":true"#))
    }

    @Test func driveUntrashPatchesTrashedFalse() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"id":"F1"}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive untrash F1")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("untrashed: F1"))
        #expect(String(decoding: transport.lastBody ?? Data(), as: UTF8.self)
            .contains(#""trashed":false"#))
    }

    @Test func driveRenameDryRunDoesNotWrite() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing(
            "gog drive rename F1 --name Renamed.txt --dry-run")
        #expect(run.exitStatus == .success)
        #expect(run.stderr.contains("dry-run: not renaming"))
        #expect(run.stdout.contains("Renamed.txt"))
    }

    @Test func driveRenamePatchesName() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200,
                body: Data(#"{"id":"F1","name":"Renamed.txt"}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive rename F1 --name Renamed.txt")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("renamed: F1"))
        #expect(transport.lastMethod == "PATCH")
        #expect(String(decoding: transport.lastBody ?? Data(), as: UTF8.self)
            .contains("Renamed.txt"))
    }

    @Test func driveMkdirDryRunDoesNotWrite() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing("gog drive mkdir Reports --dry-run")
        #expect(run.exitStatus == .success)
        #expect(run.stderr.contains("dry-run: not creating folder"))
        #expect(run.stdout.contains("vnd.google-apps.folder"))
    }

    @Test func driveMkdirPostsFolderUnderParent() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200,
                body: Data(#"{"id":"D9","name":"Reports"}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive mkdir Reports --parent P1")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("created folder: D9"))
        #expect(transport.lastMethod == "POST")
        let body = String(decoding: transport.lastBody ?? Data(), as: UTF8.self)
        #expect(body.contains("vnd.google-apps.folder"))
        #expect(body.contains("P1"))
    }

    // MARK: - Writes: Drive cp / mv / share / unshare

    @Test func driveCopyDryRunDoesNotCopy() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing(
            "gog drive cp F1 --name Clone.txt --parent P1 --dry-run")
        #expect(run.exitStatus == .success)
        #expect(run.stderr.contains("dry-run: not copying"))
        #expect(run.stdout.contains("Clone.txt") && run.stdout.contains("P1"))
    }

    @Test func driveCopyPostsToCopyEndpoint() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200,
                body: Data(#"{"id":"F2","name":"Clone.txt"}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive cp F1 --name Clone.txt")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("copied: F2"))
        #expect(transport.lastMethod == "POST")
        #expect(transport.lastURL?.absoluteString.contains("/files/F1/copy") == true)
    }

    @Test func driveMovePatchesParentsWithExplicitFrom() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"id":"F1"}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive mv F1 --to NEW --from OLD")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("moved: F1 -> NEW"))
        #expect(transport.lastMethod == "PATCH")
        // Single call: no parent lookup when --from is given.
        #expect(transport.urls.count == 1)
        let url = transport.lastURL?.absoluteString ?? ""
        #expect(url.contains("addParents=NEW") && url.contains("removeParents=OLD"))
    }

    @Test func driveMoveLooksUpParentsWhenFromOmitted() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        // First call (GET fields=parents) and the PATCH both see this response;
        // the GET decode yields the old parent to remove.
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"parents":["OLD"]}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive mv F1 --to NEW")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(transport.urls.count == 2)            // lookup, then move
        let url = transport.lastURL?.absoluteString ?? ""
        #expect(url.contains("addParents=NEW") && url.contains("removeParents=OLD"))
    }

    @Test func driveMoveDropsDestinationFromRemovedParents() async throws {
        // File already under NEW: must not send removeParents=NEW alongside
        // addParents=NEW (an ambiguous parent mutation Drive can reject).
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"parents":["NEW"]}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive mv F1 --to NEW")
            }
        }
        #expect(run.exitStatus == .success)
        let url = transport.lastURL?.absoluteString ?? ""
        #expect(url.contains("addParents=NEW"))
        #expect(!url.contains("removeParents"))
    }

    @Test func driveShareRequiresEmailOrAnyone() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing("gog drive share F1")
        #expect(run.exitStatus == ExitStatus(2))
        #expect(run.stderr.contains("exactly one"))
    }

    @Test func driveShareRejectsBadRole() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing(
            "gog drive share F1 --email a@b.com --role admin")
        #expect(run.exitStatus == ExitStatus(2))
        #expect(run.stderr.contains("reader, writer, or commenter"))
    }

    @Test func driveSharePostsUserPermission() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"id":"PERM1"}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing(
                    "gog drive share F1 --email a@b.com --role writer")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("shared: PERM1"))
        #expect(transport.lastMethod == "POST")
        #expect(transport.lastURL?.absoluteString.contains("/files/F1/permissions") == true)
        let body = String(decoding: transport.lastBody ?? Data(), as: UTF8.self)
        #expect(body.contains("\"type\":\"user\""))
        #expect(body.contains("writer") && body.contains("a@b.com"))
    }

    @Test func driveShareAnyoneUsesAnyoneType() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"id":"PERM2"}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive share F1 --anyone")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(String(decoding: transport.lastBody ?? Data(), as: UTF8.self)
            .contains("\"type\":\"anyone\""))
    }

    @Test func driveUnshareDeletesPermission() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 204, body: Data()))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive unshare F1 --permission P1")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("revoked: P1"))
        #expect(transport.lastMethod == "DELETE")
        #expect(transport.lastURL?.absoluteString.contains("/files/F1/permissions/P1") == true)
    }

    // MARK: - Writes: Sheets append / clear

    @Test func sheetsAppendDryRunDoesNotWrite() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing(
            "gog sheets append S1 'Sheet1!A1' --values-json '[[\"x\",\"y\"]]' --dry-run")
        #expect(run.exitStatus == .success)
        #expect(run.stderr.contains("dry-run: not appending"))
        #expect(run.stdout.contains("\"x\"") && run.stdout.contains("\"y\""))
    }

    @Test func sheetsAppendRejectsBadJson() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing(
            "gog sheets append S1 'Sheet1!A1' --values-json notjson")
        #expect(run.exitStatus == ExitStatus(2))
        #expect(run.stderr.contains("JSON array of rows"))
    }

    @Test func sheetsAppendPostsToAppendEndpoint() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200,
                body: Data(#"{"updates":{"updatedRange":"Sheet1!A2:B2","updatedCells":2}}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing(
                    "gog sheets append S1 'Sheet1!A1' --values-json '[[\"x\",\"y\"]]'")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("appended: Sheet1!A2:B2"))
        #expect(transport.lastMethod == "POST")
        let url = transport.lastURL?.absoluteString ?? ""
        #expect(url.contains(":append"))
        #expect(url.contains("valueInputOption=USER_ENTERED"))
    }

    @Test func sheetsClearDryRunDoesNotClear() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing("gog sheets clear S1 'Sheet1!A1:D9' --dry-run")
        #expect(run.exitStatus == .success)
        #expect(run.stderr.contains("dry-run: not clearing"))
        #expect(run.stdout.contains("would clear: Sheet1!A1:D9"))
    }

    @Test func sheetsClearPostsToClearEndpoint() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200,
                body: Data(#"{"clearedRange":"Sheet1!A1:D9"}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog sheets clear S1 'Sheet1!A1:D9'")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("cleared: Sheet1!A1:D9"))
        #expect(transport.lastMethod == "POST")
        #expect(transport.lastURL?.absoluteString.contains(":clear") == true)
    }

    // MARK: - Writes: Contacts create / update / delete

    @Test func contactsCreateRequiresAField() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing("gog contacts create")
        #expect(run.exitStatus == ExitStatus(2))
        #expect(run.stderr.contains("requires --given"))
    }

    @Test func contactsCreateDryRunDoesNotWrite() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing(
            "gog contacts create --given Jane --family Doe --dry-run")
        #expect(run.exitStatus == .success)
        #expect(run.stderr.contains("dry-run: not creating"))
        #expect(run.stdout.contains("givenName") && run.stdout.contains("Jane"))
        #expect(run.stdout.contains("familyName") && run.stdout.contains("Doe"))
    }

    @Test func contactsCreatePostsToCreateContact() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200,
                body: Data(#"{"resourceName":"people/c1"}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing(
                    "gog contacts create --given Jane --family Doe --email jane@x.com")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("created: people/c1"))
        #expect(transport.lastMethod == "POST")
        // create takes no personFields query (matches gogcli).
        #expect(transport.lastURL?.absoluteString.hasSuffix("people:createContact") == true)
        let body = String(decoding: transport.lastBody ?? Data(), as: UTF8.self)
        #expect(body.contains("givenName") && body.contains("Jane"))
        #expect(body.contains("familyName") && body.contains("Doe"))
        #expect(body.contains("jane@x.com"))
    }

    @Test func contactsUpdateRequiresAField() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing("gog contacts update people/c1")
        #expect(run.exitStatus == ExitStatus(2))
        #expect(run.stderr.contains("--given, --family, --email, --phone"))
    }

    @Test func contactsUpdateReadsEtagThenPatches() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        // Both the GET (etag + metadata.sources lookup) and the PATCH see this
        // response; the GET decode supplies the etag and source metadata the
        // PATCH body must echo back — updateContact 400s without them.
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(
                #"{"resourceName":"people/c1","etag":"ETAG1","names":[{"givenName":"Old","familyName":"Doe"}],"metadata":{"sources":[{"type":"CONTACT","id":"src1","etag":"SRCE"}]}}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing(
                    "gog contacts update people/c1 --given Jane")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("updated: people/c1"))
        #expect(transport.urls.count == 2)            // get (etag+metadata), then patch
        #expect(transport.lastMethod == "PATCH")
        // The read mask asks for metadata so the sources come back.
        #expect(transport.urls.first?.absoluteString.contains("metadata") == true)
        let url = transport.lastURL?.absoluteString ?? ""
        #expect(url.contains(":updateContact") && url.contains("updatePersonFields=names"))
        // The PATCH body echoes etag + metadata.sources, sets the new given name,
        // and preserves the family name that wasn't passed.
        let body = String(decoding: transport.lastBody ?? Data(), as: UTF8.self)
        #expect(body.contains("ETAG1") && body.contains("\"givenName\":\"Jane\""))
        #expect(body.contains("\"familyName\":\"Doe\""))
        #expect(body.contains("sources") && body.contains("SRCE"))
    }

    @Test func contactsDeleteDryRunDoesNotDelete() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing("gog contacts delete people/c1 --dry-run")
        #expect(run.exitStatus == .success)
        #expect(run.stderr.contains("dry-run: not deleting"))
        #expect(run.stdout.contains("would delete: people/c1"))
    }

    @Test func contactsDeleteCallsDeleteContact() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data("{}".utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog contacts delete people/c1")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("deleted: people/c1"))
        #expect(transport.lastMethod == "DELETE")
        #expect(transport.lastURL?.absoluteString.hasSuffix("people/c1:deleteContact") == true)
    }

    @Test func driveShareGroupUsesGroupType() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"id":"PERM3"}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing(
                    "gog drive share F1 --email team@x.com --type group")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(String(decoding: transport.lastBody ?? Data(), as: UTF8.self)
            .contains("\"type\":\"group\""))
    }

    @Test func driveShareRejectsBadType() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing(
            "gog drive share F1 --email a@b.com --type domain")
        #expect(run.exitStatus == ExitStatus(2))
        #expect(run.stderr.contains("--type must be user or group"))
    }

    @Test func driveShareEncodesFileIdAsSingleSegment() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"id":"PERM4"}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive share 'a/b' --email x@y.com")
            }
        }
        #expect(run.exitStatus == .success)
        // The file id is encoded as one path segment, not split by its slash.
        #expect(transport.lastURL?.absoluteString.contains("/files/a%2Fb/permissions") == true)
    }

    // MARK: - Write-tier gate (host-only policy)

    @Test func readOnlyTierBlocksAnyWrite() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        // Re-bind read-only, overriding the suite's .full.
        let run = try await GogPolicies.$current.withValue(
            GogPolicy(writeTier: .readOnly)
        ) { try await shell.runCapturing("gog tasks complete T1") }
        #expect(run.exitStatus == ExitStatus(3))
        #expect(run.stderr.contains("read-only by default"))
    }

    @Test func editTierBlocksDestructiveWrite() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        // .edit is not enough for a .full (destructive) op like drive trash.
        let run = try await GogPolicies.$current.withValue(
            GogPolicy(writeTier: .edit)
        ) { try await shell.runCapturing("gog drive trash F1") }
        #expect(run.exitStatus == ExitStatus(3))
        #expect(run.stderr.contains("write tier 'full'"))
    }

    @Test func editTierAllowsAdditiveWrite() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200,
                body: Data(#"{"id":"T1","status":"completed"}"#.utf8)))
        let run = try await GogPolicies.$current.withValue(GogPolicy(writeTier: .edit)) {
            try await GogTransportProvider.$current.withValue(transport) {
                try await GogCredentials.$current.withValue(
                    StubProvider(token: "t", accountHint: nil)
                ) {
                    try await shell.runCapturing("gog tasks complete T1")
                }
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("completed: T1"))
    }

    @Test func gmailModifyTrashLabelNeedsFullTier() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        // Adding TRASH is destructive (like `gmail trash`): .edit must refuse.
        let run = try await GogPolicies.$current.withValue(GogPolicy(writeTier: .edit)) {
            try await shell.runCapturing("gog gmail modify M1 --add-label TRASH")
        }
        #expect(run.exitStatus == ExitStatus(3))
        #expect(run.stderr.contains("write tier 'full'"))
    }

    @Test func driveShareDefaultsToNoNotificationEmail() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"id":"P1"}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive share F1 --email a@b.com")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(transport.lastURL?.absoluteString.contains("sendNotificationEmail=false")
            == true)
    }

    @Test func driveShareNotifyEnablesNotificationEmail() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"id":"P1"}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive share F1 --email a@b.com --notify")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(transport.lastURL?.absoluteString.contains("sendNotificationEmail=true")
            == true)
    }

    @Test func contactsUpdatePreservesUneditedNameComponents() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        // Readback has a middle name; updating only --given must keep it (the
        // People API replaces the whole `names` field).
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(
                #"{"etag":"e","names":[{"givenName":"Jo","familyName":"Lee","middleName":"Q"}]}"#
                    .utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog contacts update people/c1 --given Joey")
            }
        }
        #expect(run.exitStatus == .success)
        let body = String(decoding: transport.lastBody ?? Data(), as: UTF8.self)
        #expect(body.contains("Joey"))                 // requested change applied
        #expect(body.contains(#""middleName":"Q""#))   // unedited component kept
        // The read is restricted to the contact's own source (not a linked
        // profile), so the preserved base name is the contact's.
        #expect(transport.urls.first?.absoluteString.contains("READ_SOURCE_TYPE_CONTACT")
            == true)
    }

    @Test func driveCopyIntoParentNeedsFullTier() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        // A plain copy is .edit, but copying into a folder can expose the data
        // (folder permissions propagate), so a parented copy needs .full.
        let run = try await GogPolicies.$current.withValue(GogPolicy(writeTier: .edit)) {
            try await shell.runCapturing("gog drive cp F1 --parent SHARED")
        }
        #expect(run.exitStatus == ExitStatus(3))
        #expect(run.stderr.contains("write tier 'full'"))
    }

    @Test func gmailDraftDryRunDoesNotCreate() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing(
            "gog gmail draft --to a@b.com --subject Hi --body Yo --dry-run")
        #expect(run.exitStatus == .success)
        #expect(run.stderr.contains("dry-run: not creating draft"))
        #expect(run.stdout.contains("message"))   // the MIME payload preview
    }

    @Test func driveUploadIntoParentNeedsFullTier() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        // Uploading into a folder can expose the file, like a parented copy.
        let run = try await GogPolicies.$current.withValue(GogPolicy(writeTier: .edit)) {
            try await shell.runCapturing("gog drive upload /gog/x.txt --parent SHARED")
        }
        #expect(run.exitStatus == ExitStatus(3))
        #expect(run.stderr.contains("write tier 'full'"))
    }

    @Test func sheetsUpdateBlankCellStaysEditTier() async throws {
        // Writing "" via `update` is a targeted overwrite, not a `clear`, so it
        // stays allowed at .edit (clearing a whole range is the .full op). Pins
        // that deliberate choice so the tier never becomes value-dependent.
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"updatedCells":1}"#.utf8)))
        let run = try await GogPolicies.$current.withValue(GogPolicy(writeTier: .edit)) {
            try await GogTransportProvider.$current.withValue(transport) {
                try await GogCredentials.$current.withValue(
                    StubProvider(token: "t", accountHint: nil)
                ) {
                    try await shell.runCapturing(
                        #"gog sheets update S1 'Sheet1!A1' --values-json '[[""]]'"#)
                }
            }
        }
        #expect(run.exitStatus == .success)
        #expect(transport.lastMethod == "PUT")
        // The blank value reaches the request body (not dropped before the PUT).
        #expect(String(decoding: transport.lastBody ?? Data(), as: UTF8.self)
            .contains(#"[[""]]"#))
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

    // MARK: - Writes: Docs / Slides

    @Test func docsCreatePostsToDocumentsEndpoint() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"documentId":"D1"}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog docs create --title 'My Doc'")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("created: D1"))
        #expect(transport.lastMethod == "POST")
        #expect(transport.lastURL?.absoluteString.hasSuffix("/v1/documents") == true)
        #expect(String(decoding: transport.lastBody ?? Data(), as: UTF8.self).contains("My Doc"))
    }

    @Test func docsAppendPostsBatchUpdate() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data("{}".utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog docs append D1 --text Hello")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(transport.lastMethod == "POST")
        #expect(transport.lastURL?.absoluteString.contains("/documents/D1:batchUpdate") == true)
        let body = String(decoding: transport.lastBody ?? Data(), as: UTF8.self)
        #expect(body.contains("insertText") && body.contains("endOfSegmentLocation"))
        // Appended text is prefixed with a newline so it lands in a new paragraph.
        #expect(body.contains(#"\nHello"#))
    }

    @Test func docsAppendTargetsTabWhenGiven() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data("{}".utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog docs append D1 --text Hi --tab-id t.0")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(String(decoding: transport.lastBody ?? Data(), as: UTF8.self)
            .contains(#""tabId":"t.0""#))
    }

    @Test func docsFindReplaceRequiresFind() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing(
            "gog docs find-replace D1 --find '' --replace x")
        #expect(run.exitStatus == ExitStatus(2))
        #expect(run.stderr.contains("--find"))
    }

    @Test func docsFindReplacePostsReplaceAllText() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data("{}".utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing(
                    "gog docs find-replace D1 --find foo --replace bar")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(transport.lastMethod == "POST")
        let body = String(decoding: transport.lastBody ?? Data(), as: UTF8.self)
        #expect(body.contains("replaceAllText"))
        #expect(body.contains("foo") && body.contains("bar"))
    }

    @Test func docsCreateDryRunDoesNotPost() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing("gog docs create --title X --dry-run")
        #expect(run.exitStatus == .success)
        #expect(run.stderr.contains("dry-run: not creating"))
        #expect(run.stdout.contains("X"))
    }

    @Test func slidesCreatePostsToPresentationsEndpoint() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200,
                body: Data(#"{"presentationId":"P1"}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog slides create --title Deck")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("created: P1"))
        #expect(transport.lastMethod == "POST")
        #expect(transport.lastURL?.absoluteString.hasSuffix("/v1/presentations") == true)
    }

    @Test func slidesAddSlidePostsBatchUpdate() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data("{}".utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog slides add-slide P1")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(transport.lastMethod == "POST")
        #expect(transport.lastURL?.absoluteString.contains("/presentations/P1:batchUpdate")
            == true)
        #expect(String(decoding: transport.lastBody ?? Data(), as: UTF8.self)
            .contains("createSlide"))
    }

    @Test func slidesReplaceTextPostsReplaceAllText() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data("{}".utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing(
                    "gog slides replace-text P1 --find foo --replace bar")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(transport.lastMethod == "POST")
        let body = String(decoding: transport.lastBody ?? Data(), as: UTF8.self)
        #expect(body.contains("replaceAllText") && body.contains("foo"))
    }

    @Test func docsClearDeletesBodyRange() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200,
                body: Data(#"{"body":{"content":[{"endIndex":1},{"endIndex":50}]}}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog docs clear D1")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(transport.lastMethod == "POST")
        #expect(transport.lastURL?.absoluteString.contains("/documents/D1:batchUpdate") == true)
        let body = String(decoding: transport.lastBody ?? Data(), as: UTF8.self)
        #expect(body.contains("deleteContentRange"))
        #expect(body.contains(#""startIndex":1"#) && body.contains(#""endIndex":49"#))
    }

    @Test func docsClearEmptyDocMakesNoEdit() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200,
                body: Data(#"{"body":{"content":[{"endIndex":2}]}}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog docs clear D1")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("already empty"))
        #expect(transport.lastMethod == "GET")   // no batchUpdate POST issued
    }

    @Test func slidesListSlidesPrintsObjectIds() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200,
                body: Data(#"{"slides":[{"objectId":"s1"},{"objectId":"s2"}]}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog slides list-slides P1")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("s1") && run.stdout.contains("s2"))
        #expect(transport.lastURL?.absoluteString.contains("/presentations/P1") == true)
    }

    @Test func slidesListSlidesFailEmptyExitsThree() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200, body: Data(#"{"slides":[]}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog slides list-slides P1 --fail-empty")
            }
        }
        #expect(run.exitStatus == ExitStatus(3))
    }

    @Test func slidesDeleteSlidePostsDeleteObject() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        // The same response serves the validation GET (s1 is a real slide) and
        // the deleteObject POST.
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200,
                body: Data(#"{"slides":[{"objectId":"s1"}]}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog slides delete-slide P1 s1")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(transport.lastMethod == "POST")
        #expect(transport.lastURL?.absoluteString.contains("/presentations/P1:batchUpdate")
            == true)
        let body = String(decoding: transport.lastBody ?? Data(), as: UTF8.self)
        #expect(body.contains("deleteObject") && body.contains(#""objectId":"s1""#))
    }

    @Test func slidesDeleteSlideRejectsNonSlideId() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        // x9 isn't among the presentation's slide object IDs — refuse (exit 2)
        // rather than deleteObject an arbitrary page element.
        let transport = RecordingTransport(
            response: HTTPResponse(status: 200,
                body: Data(#"{"slides":[{"objectId":"s1"}]}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog slides delete-slide P1 x9")
            }
        }
        #expect(run.exitStatus == ExitStatus(2))
        #expect(run.stderr.contains("not a slide"))
        #expect(transport.lastMethod == "GET")   // no deleteObject POST issued
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

    @Test func adminSuspendDisabledByDefault() async throws {
        // Default policy disables admin writes; suspend must exit 3 before any
        // network, even with no policy explicitly bound.
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await shell.runCapturing("gog admin suspend alice@x.com")
        #expect(run.exitStatus == ExitStatus(3))
        #expect(run.stderr.contains("disabled by host policy"))
    }

    @Test func adminSuspendDryRunWhenEnabled() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        // Writes enabled by host; --dry-run previews without any network.
        let run = try await GogPolicies.$current.withValue(
            GogPolicy(adminWriteDisabled: false)
        ) {
            try await shell.runCapturing("gog admin suspend alice@x.com --dry-run")
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("suspend alice@x.com"))
        #expect(run.stdout.contains(#""suspended":true"#))
    }

    @Test func adminSuspendPatchesWhenEnabled() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = MockTransport(
            response: HTTPResponse(
                status: 200, body: Data(#"{"primaryEmail":"alice@x.com"}"#.utf8)))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogPolicies.$current.withValue(GogPolicy(adminWriteDisabled: false)) {
                try await GogCredentials.$current.withValue(
                    StubProvider(token: "t", accountHint: nil)
                ) {
                    try await shell.runCapturing("gog admin suspend alice@x.com")
                }
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("suspended: alice@x.com"))
    }

    @Test func adminMemberAddRejectsBadRole() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await GogPolicies.$current.withValue(
            GogPolicy(adminWriteDisabled: false)
        ) {
            try await shell.runCapturing(
                "gog admin member-add eng@x.com bob@x.com --role FOO")
        }
        #expect(run.exitStatus == ExitStatus(2))
    }

    @Test func adminMemberAddRejectsNonEmail() async throws {
        // members.insert needs an email; a bare id must be rejected up front.
        let shell = Shell()
        shell.registerGogCommands()
        let run = try await GogPolicies.$current.withValue(
            GogPolicy(adminWriteDisabled: false)
        ) {
            try await shell.runCapturing(
                "gog admin member-add eng@x.com someUserId123 --dry-run")
        }
        #expect(run.exitStatus == ExitStatus(2))
        #expect(run.stderr.contains("needs an email"))
    }

    @Test func adminMemberRemoveDeletesWhenEnabled() async throws {
        let shell = Shell()
        shell.registerGogCommands()
        let transport = RecordingTransport(
            response: HTTPResponse(status: 204, body: Data()))
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogPolicies.$current.withValue(GogPolicy(adminWriteDisabled: false)) {
                try await GogCredentials.$current.withValue(
                    StubProvider(token: "t", accountHint: nil)
                ) {
                    try await shell.runCapturing(
                        "gog admin member-remove eng@x.com bob@x.com")
                }
            }
        }
        #expect(run.exitStatus == .success)
        #expect(transport.lastURL?.absoluteString.contains("/members/bob@x.com") == true)
        #expect(run.stdout.contains("removed bob@x.com from eng@x.com"))
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

    // MARK: - Credential confinement + end-to-end sandbox smoke

    @Test func tokenNeverSurfacesInEnvironment() async throws {
        let shell = Shell()
        shell.registerStandardCommands()   // printenv / env live here
        shell.registerGogCommands()
        let secret = "secret-token-do-not-leak-1234"
        let transport = MockTransport(
            response: HTTPResponse(
                status: 200, body: Data(#"{"names":[{"displayName":"Ada"}]}"#.utf8)))
        // Authenticate a request, then dump the environment in the same shell/task
        // via the very commands model-authored bash would use to fish for secrets.
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: secret, accountHint: nil)
            ) {
                try await shell.runCapturing("gog me --json && printenv && env")
            }
        }
        #expect(run.exitStatus == .success)
        // The token authenticated the call but is bound out-of-band (task-local),
        // so it must never appear in the environment, argv, or any output.
        #expect(!run.stdout.contains(secret))
        #expect(!run.stderr.contains(secret))
    }

    @Test func e2eDriveListPipesThroughGrep() async throws {
        let shell = Shell()
        shell.registerStandardCommands()   // grep lives here
        shell.registerGogCommands()
        let json = #"{"files":[{"id":"f1","name":"Quarterly.pdf","mimeType":"application/pdf"}]}"#
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data(json.utf8)))
        // gog's JSON must flow through a real pipe to another sandbox command.
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing("gog drive ls --json | grep Quarterly")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("Quarterly.pdf"))
    }

    @Test func e2eDownloadThenReadBackThroughShell() async throws {
        let mounted = MountedFileSystem(
            mounts: [.init(virtual: "/gog", host: "/gog")],
            backing: InMemoryFileSystem())
        let shell = Shell(fileSystem: mounted)
        shell.registerStandardCommands()   // cat lives here
        try await shell.fileSystem.createDirectory("/gog", intermediates: true)
        shell.registerGogCommands()
        let transport = MockTransport(
            response: HTTPResponse(status: 200, body: Data("REPORT-BODY".utf8)))
        // Download into the mount, then read it back with `cat` (a separate sandbox
        // command) — proving gog writes into /gog and composes end-to-end.
        let run = try await GogTransportProvider.$current.withValue(transport) {
            try await GogCredentials.$current.withValue(
                StubProvider(token: "t", accountHint: nil)
            ) {
                try await shell.runCapturing(
                    "gog drive download FID --out /gog/report.txt && cat /gog/report.txt")
            }
        }
        #expect(run.exitStatus == .success)
        #expect(run.stdout.contains("REPORT-BODY"))
    }
}
