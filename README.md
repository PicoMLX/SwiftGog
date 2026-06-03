# SwiftGog

A **sandboxed Google Workspace CLI** that registers a `gog` command into a
[SwiftBash](https://github.com/picomlx/SwiftBash) `Shell`, so a local LLM (or any
shell automation) can read and write Google Drive, Gmail, Calendar, Contacts,
Tasks, Docs, Sheets, Slides, Chat, Forms, YouTube, and Admin Directory — all
confined by SwiftBash's `MountedFileSystem` and allow-listed network layer.

```bash
gog drive ls --max 20 --json | jq '.files[].name'
gog gmail messages -q 'newer_than:7d' --json
gog calendar freebusy --json
```

`gog` behaves like any other sandbox command: structured data to **stdout**,
hints/progress/errors to **stderr**, composable through pipes.

## Design in one breath

- **The host owns auth.** `gog` performs no OAuth — no browser flow, no token
  endpoint, no Keychain. The host injects a Google access token per run via a
  `GogCredentialProvider`; on a `401`, `gog` asks the host to refresh once, then
  fails closed (exit 7) for the host to handle.
- **Credentials stay out-of-band.** The token is never placed in the shell
  environment, the command argv, or the mounted filesystem — it is only attached
  as an `Authorization` header by the HTTP layer. `printenv` / `echo $TOKEN`
  cannot surface it.
- **Files stay in the sandbox.** All I/O goes through `Shell.fileSystem`
  (`MountedFileSystem`); paths outside the mounts are rejected, so download and
  upload targets must be sandbox paths.
- **Network is allow-listed.** Only the Google API hosts you configure are
  reachable; with no `networkConfig`, networked commands fail closed (exit 7).
- **Mutations are gated.** Writes that send or change things (`gmail send`,
  `chat send`, the `admin` directory writes) honour a host `GogPolicy` and
  support `--dry-run`.

See [`PLAN.md`](PLAN.md) for the full architecture and decisions, and
[`.agents/skills/gog/SKILL.md`](.agents/skills/gog/SKILL.md) for the
agent-facing command reference.

## Installation

Add SwiftGog (and SwiftBash) as package dependencies:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/picomlx/SwiftGog.git", branch: "main"),
    .package(url: "https://github.com/picomlx/SwiftBash.git", branch: "main"),
],
```

The package vends three libraries:

| Library       | What it provides                                                       |
| ------------- | ---------------------------------------------------------------------- |
| `GogCore`     | the host seams: `GogCredentialProvider`, `GogPolicy`, `GogTransport`   |
| `GogCommands` | the `gog` command tree (`ArgumentParser` commands)                     |
| `GogShell`    | `Shell.registerGogCommands()` — one call installs the whole tree       |

## Host integration

Build a sandboxed `Shell`, allow-list the Google API hosts, register `gog`, then
run commands with a credential provider (and optional policy) bound around the
run:

```swift
import BashInterpreter   // Shell, NetworkConfig, AllowedURLEntry, MountedFileSystem
import GogCore           // GogCredentials, GogPolicy, GogPolicies, GogCredentialProvider
import GogShell          // registerGogCommands()

// 1. The host's token source (no OAuth lives in gog).
struct MyProvider: GogCredentialProvider {
    let account: String
    func accessToken() async throws -> String { try await myTokenStore.token(for: account) }
    func refreshedAccessToken() async throws -> String { try await myTokenStore.refresh(for: account) }
    var accountHint: String? { account }
}

// 2. A sandboxed shell: a mounted workspace + an allow-list of Google API hosts.
let shell = Shell(fileSystem: myMountedFileSystem)   // e.g. mounts "/gog"
shell.networkConfig = NetworkConfig(
    allowedURLPrefixes: [
        AllowedURLEntry("https://www.googleapis.com/"),     // Drive, Calendar
        AllowedURLEntry("https://gmail.googleapis.com/"),
        AllowedURLEntry("https://people.googleapis.com/"),  // identity + contacts
        AllowedURLEntry("https://admin.googleapis.com/"),   // Admin Directory + Reports
        // …add a host prefix per service family you enable; see PLAN.md.
    ],
    allowedMethods: [.GET, .POST, .PATCH, .PUT, .DELETE])

// 3. Install the gog command tree (off-catalog, at /usr/local/bin/gog).
shell.registerGogCommands()

// 4. Run, with the provider (and any policy) bound for this run only.
let run = try await GogCredentials.$current.withValue(MyProvider(account: "alice@corp.com")) {
    try await GogPolicies.$current.withValue(GogPolicy(gmailSendDisabled: true)) {
        try await shell.runCapturing("gog drive ls --json")
    }
}
print(run.stdout)            // structured JSON
assert(run.exitStatus == .success)
```

Because the provider and policy are bound as **task-local** values around the
run, LLM-authored bash inside the shell cannot read or change them — they are
not command flags or environment variables.

### Multi-tenant

Bind a different `GogCredentialProvider` per run (or per task) — there is no
global mutable auth state, so concurrent tenants don't interfere:

```swift
try await GogCredentials.$current.withValue(tenantA.provider) { … }   // tenant A
try await GogCredentials.$current.withValue(tenantB.provider) { … }   // tenant B
```

## Safety policy & gated writes

`GogPolicy` (bound via `GogPolicies.$current`) lets the host disable specific
mutations. Sending is allowed by default but can be turned off; high-blast-radius
directory mutations are **off by default** and must be opted in. Every gated
write also supports `--dry-run`, which builds and prints the request without
calling Google.

```swift
// Disable outbound mail and chat for this run.
GogPolicy(gmailSendDisabled: true, chatSendDisabled: true)
```

A blocked mutation fails closed with **exit 3** before any network call. The host
also controls *which* commands exist — `registerGogCommands()` installs the full
tree, but a host may install a narrower command set instead.

### Compatibility note: directory-write gating differs from `gogcli`

Upstream [`gogcli`](https://github.com/steipete/gogcli) guards destructive
directory operations (suspending a user, changing group membership) with an
**interactive confirmation prompt** plus a `--force` flag, and in non-interactive
use it refuses them unless `--force` is passed. SwiftGog runs **LLM-authored bash
with no human at a terminal**, so it replaces that with a **host-bound policy**:
directory writes are **disabled by default** (`GogPolicy.adminWriteDisabled` —
the one gate that defaults to *off*, unlike the send gates), and there is
intentionally **no `--force` flag** — a command-line escape hatch would let the
model escalate past the gate. The *host*, not the model, decides whether to
enable directory writes. The fail-closed intent matches gogcli's non-interactive
behaviour; the control simply moves from argv to host policy.

## Exit codes

| Code | Meaning                                                                   |
| ---- | ------------------------------------------------------------------------- |
| 0    | success                                                                   |
| 1    | a Google API error (HTTP ≥ 400); the message is echoed to stderr          |
| 2    | usage / validation error (bad flag, out-of-range `--max`, bad input)      |
| 3    | refused by host policy (e.g. sending disabled, admin writes disabled)     |
| 7    | fail-closed: no network configured, or missing / rejected credentials     |
| 23   | could not write the requested sandbox destination                         |

## Security contracts

These are enforced and CI-guarded; a consumer can rely on them:

- **No host filesystem or networking primitives.** `GogCore`/`GogCommands` never
  use `FileManager`, `Data(contentsOf:)`, or `URLSession` — a CI lint-guard
  fails the build if they appear. All file I/O goes through `Shell.fileSystem`;
  all HTTPS goes through the allow-listed transport.
- **Token confinement.** The injected token is only ever an `Authorization`
  header. It is never written to `Shell.environment`, argv, stdout/stderr, or the
  mounted FS.
- **Fail-closed by default.** No network config ⇒ exit 7. No credentials ⇒
  exit 7. Out-of-mount path ⇒ rejected.

## Testing

`GogTransport` is an injectable seam: production uses `SecureTransport` (over
SwiftBash's allow-listed fetcher), and tests bind a fake via
`GogTransportProvider.$current` to return canned Google JSON — no real network:

```swift
// MockTransport / StubProvider are your own test doubles conforming to
// GogTransport / GogCredentialProvider.
let json = #"{"files":[]}"#
let transport = MockTransport(response: HTTPResponse(status: 200, body: Data(json.utf8)))
try await GogTransportProvider.$current.withValue(transport) {
    try await GogCredentials.$current.withValue(StubProvider()) {
        try await shell.runCapturing("gog drive ls --json")
    }
}
```

See `Tests/GogShellTests/GogWiringTests.swift` for the full pattern (fakes,
sandbox-deny tests, and per-command behaviour).

## Status

The command surface spans identity, Drive, Gmail, Calendar, Contacts, Tasks,
Docs, Sheets, Slides, Chat, Forms, YouTube, and Admin (Directory + Reports),
read-first with gated writes. See `SKILL.md` for the current command list and
`PLAN.md` for the roadmap.
