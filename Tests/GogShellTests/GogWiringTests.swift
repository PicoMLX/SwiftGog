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

        let run = try await GogCredentials.$current.withValue(
            StubProvider(token: "secret-token-xyz",
                         accountHint: "alice@example.com")
        ) {
            try await shell.runCapturing("gog auth status --json")
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
