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
