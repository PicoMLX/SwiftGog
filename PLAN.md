# Port `gogcli` → `SwiftGog` (a SwiftBash-based Swift CLI)

> **Status:** planning · **Branch:** `claude/tender-gates-vc7Mi` · **Repo:** `picomlx/SwiftGog`
> **Revision v2** — see *Changes from v1* below. All SwiftBash/gogcli claims in this
> document were verified against the checked-out sources at `/home/user/SwiftBash` and
> `/home/user/gogcli`.

## Changes from v1 (decisions locked with the user)

- **Google OAuth is out of scope.** The host app owns the entire Google token lifecycle
  (interactive consent, storage, refresh) — it already does, because it is a multitenant
  Google app. `SwiftGog` performs **no** OAuth: no browser flow, no token endpoint, no
  Keychain. It **consumes an injected access token** per request and reacts to `401`s.
  → Removes the `ASWebAuthenticationSession` / localhost-callback / Keychain subsystems
  that were the largest risk in v1.
- **Credentials are injected out-of-band, never via argv/env.** A host-implemented
  `GogCredentialProvider` is bound as a task-local around each run. Tokens never enter the
  shell `environment`, the `gog …` argv, or the mounted filesystem — because `env` /
  `printenv` dump `Shell.bashCurrent.environment.variables` verbatim and are reachable by
  model-authored bash.
- **MCP is entirely app-side.** The app exposes `gog` to the model however it likes
  (e.g. translating tool calls → `shell.runCapturing("gog …")`, reusing its existing MCP
  Swift SDK). **No MCP code, server, or scaffolding in this repo.**
- **Multitenancy = one sandboxed `Shell` per tenant**, each with its own
  `MountedFileSystem` root and its own bound `GogCredentialProvider`, sharing the same
  Google `networkConfig` allow-list.
- **API-name fixes:** all shell access is `Shell.bashCurrent.*` (not `Shell.current.*`);
  the network allow-list uses explicit `AllowedURLEntry` **literal prefixes** (no globs).
- **Output goal is structural parity, not byte parity** (Go `encoding/json` and Swift
  `JSONEncoder` differ in key order / escaping / number formatting; the LLM consumer only
  needs structural equality).
- **Codegen leverage clarified:** `GogSchemaGen` scaffolds the *arg-parsing shell* only;
  every leaf's REST mapping + output is still hand-written. That long tail is the real cost.

---

## Decisions & open questions

### OAuth token *refresh* ownership — **DECIDED 2026-06-02: host refreshes (Option A)**

When an injected access token expires (`gog` gets a `401`), the **host** performs the OAuth
refresh — `SwiftGog` never calls the token endpoint; it asks the provider for a fresh token
and retries once. This is **revisit-able**; Option B is kept on record so we don't forget it.

- **Option A — host owns refresh (CHOSEN).** `GogCredentialProvider.refreshedAccessToken()`
  returns a freshly-minted token from the host; `SwiftGog` never calls the token endpoint.
  The network allow-list stays **API-hosts-only** (no `oauth2.googleapis.com`); `SwiftGog`
  contains **zero** OAuth. *Implemented:* `GoogleHTTPClient` retries a `401` once with
  `refreshedAccessToken()`, then exits 7 ("re-auth required") if still rejected.
- **Option B — `SwiftGog` refreshes (NOT chosen; documented for a possible revisit).** The
  host injects a refresh token + client ID/secret; `GogCore` does the
  `POST https://oauth2.googleapis.com/token` through `SecureFetcher`. Revisiting means:
  re-add `oauth2.googleapis.com` to the allow-list (~40 LOC) and widen
  `GogCredentialProvider` with the refresh token + client creds.

---

## Context

`gogcli` (`picomlx/gogcli`) is a ~211K-LOC (≈95K excl. tests) Go **Google Workspace CLI**
(binary `gog`): Gmail, Drive, Calendar, Docs, Sheets, Contacts, Tasks, Admin, Chat, Meet,
etc. We want its capabilities available to a **local MLX LLM tool chain** inside an
**iOS/macOS app**. That app already uses **SwiftBash** (`picomlx/SwiftBash`) as the model's
in-process, sandboxed code interpreter. The goal is a **new Swift package, `SwiftGog`**,
that registers `gog` and its subcommands into a SwiftBash `Shell`, so the model can run
`gog gmail send …`, `gog drive ls …`, etc. **inside SwiftBash's filesystem + network
sandbox**, with output piped to the existing `jq` / `tar` / `git` tools.

**Why reimplement in Swift (chosen) rather than embed the Go binary:** the Google work
`gogcli` does that *must* be confined is its **Drive downloads, Gmail attachments, and
config/state/cache file I/O**, plus **all HTTPS**. SwiftBash's sandbox (`MountedFileSystem`
+ `SecureFetcher`) is a *pure-Swift, in-process* gate. Only a Swift reimplementation that
routes every file touch through `Shell.bashCurrent.fileSystem` and every HTTPS call through
`SecureFetcher` is actually confined by it. An embedded Go static library does its own
libc/TLS syscalls and bypasses the sandbox entirely (and gogcli's `gog mcp` mode `exec`s
subprocesses, which iOS forbids). Reimplementing is the only option that delivers the
sandboxing requirement.

> Credentials are *not* a reason to reimplement anymore — they never touch disk in
> `SwiftGog`; the host injects a live token (see *Identity & credentials*).

**Scope locked with the user:** Option A (reimplement in Swift) · MVP = **Drive + Gmail +
Calendar + minimal identity** (`auth status`, `me`/`whoami`) · **Google OAuth out of
scope** (host-managed) · **MCP out of scope** (app-side) · LLM surface = SwiftBash commands ·
repo `picomlx/SwiftGog` (already created).

---

## Does gogcli need SwiftBash commands we'd have to port first? — No.

Verified by grepping `os/exec` across `gogcli/internal`. gogcli does **not** orchestrate
external CLIs for its real work; the only shell-outs are:

| gogcli shell-out | File | Disposition in the port |
|---|---|---|
| `git` (backups) | `internal/backup/git.go` | **SwiftBash already ships `git`** — no port needed; backups are post-MVP |
| `open`/`xdg-open`/`rundll32` (OAuth/Meet open URL) | `internal/googleauth/open_browser.go`, `internal/cmd/meet.go` | Host action; OAuth itself is out of scope · **not** a SwiftBash command |
| `open`/`xdg-open`/`rundll32` (Calendar propose-time URL) | `internal/cmd/calendar_propose_time.go` | Same: host action / post-MVP (Calendar MVP covers `events`/`get`/`create`, not propose-time) |
| `security` (macOS keychain unlock) | `internal/secrets/keychain_darwin.go` | **Dropped** — no secrets stored by `SwiftGog` |
| `wrangler`, a slides asset tool | `internal/tracking/deploy.go`, `internal/cmd/slides_assets.go` | Niche; **out of scope** |
| re-`exec`s itself (`gog mcp`) | `internal/cmd/mcp.go` | **Dropped** — MCP is app-side |

**The real prerequisites are library-level, not commands** (Phase 0): sandboxed HTTP, the
credential-provider seam, config-paths→virtual-FS mapping, output formatter. SwiftBash's
~80 standard commands + SwiftPorts (`jq`, `yq`, `tar`, `zip`, `gzip`, `git`, `gh`, `rg`,
`fd`) already cover the shell-utility side, including `base64`, `sed`, `awk`, `grep`,
`sort`, `cut`, `tr`, `xargs`; the LLM pipes `gog` JSON into them. **No new bash commands
are required for the MVP.**

> Guardrail: `gog` decodes its **own** binary payloads (Gmail base64url bodies, Drive
> media) internally and writes them via `Shell.bashCurrent.openOutputPath`. Never design a
> flow that shuttles binary data through a text pipe into `base64 -d`.

---

## Architecture

New SwiftPM package **`SwiftGog`** (Swift tools 6.2; platforms macOS 13 / iOS 16 to match
SwiftBash). Depends on SwiftBash products **`BashInterpreter`** + **`BashCommandKit`**.
The network types (`SecureFetcher`, `NetworkConfig`, `NetworkRequest`, `NetworkFetcher`,
`NetworkError`) originate in **ShellKit** and are reachable through `import BashInterpreter`
— so this dependency set suffices. **Not** SwiftScript (nothing here needs the Swift
interpreter).

Targets:
- **`GogCore`** (lib) — the engine: `GoogleHTTPClient` (wraps `SecureFetcher`), per-service
  typed clients (`DriveClient`, `GmailClient`, `CalendarClient`), the
  **`GogCredentialProvider`** seam (host-implemented; *no* OAuth/Keychain logic here), the
  config-paths→virtual-FS resolver, and `OutFmt` (JSON/TSV/human, porting `internal/outfmt`).
- **`GogCommands`** (lib) — the ArgumentParser tree: a single root
  `GogCommand: AsyncParsableCommand` whose `configuration.subcommands` lists service groups
  (`Drive`, `Gmail`, `Calendar`, `Auth`), each listing its leaves (`DriveLs`,
  `DriveDownload`, `GmailSend`, …). Depends on `GogCore`, `BashCommandKit`,
  `swift-argument-parser`.
- **`GogShell`** (lib) — one-call integration:
  `extension Shell { func registerGogCommands() }` doing `install(GogCommand.self)`
  (mirrors `registerStandardCommands()` / `registerSwiftPortsCommands()`).
- **`gog`** (executable, dev/macOS only) — a `swift-bash`-style host for parity testing
  against the real `gog`. Not shipped to iOS.
- **`GogSchemaGen`** (dev tool, not a runtime dep) — consumes `gog schema` JSON, emits
  `*.generated.swift` command stubs.
- Test targets per lib (Swift Testing + a `CapturingShell` helper).

**`gog` is a first-class SwiftBash command — exactly like `ls`.** Registered with one
`shell.install(GogCommand.self)` call and invoked as `gog …` in any bash the model writes;
it pipes like any other command. Structurally it mirrors `gh` (a single registration
exposing a nested subcommand tree); at the call site it's indistinguishable from `ls`/`cat`.

**How the app + MLX LLM invoke it** (per `SwiftBash/Docs/Sandboxing.md`): the app builds
**one sandboxed `Shell` per tenant** — `MountedFileSystem` mounting that tenant's
app-container workspace at a virtual root (e.g. `/gog`) + `/tmp`; `hostInfo = .synthetic`;
the Google `networkConfig` allow-list (below) — then calls `registerStandardCommands()` +
`registerGogCommands()`, and binds the tenant's `GogCredentialProvider` around each run:

```swift
try await GogCredentials.$current.withValue(tenant.provider) {
    let run = try await shell.runCapturing("gog drive ls --max 20 --json")
    // feed run.stdout (JSON) back to the model
}
```

Piping works: `gog gmail messages --json | jq '.messages[].id'`.

**Network allow-list (verified API; literal prefixes, no globs):**
```swift
networkConfig = NetworkConfig(
    allowedURLPrefixes: [
        AllowedURLEntry("https://www.googleapis.com/"),    // Drive v3, Calendar v3
        AllowedURLEntry("https://gmail.googleapis.com/"),  // Gmail v1
        AllowedURLEntry("https://people.googleapis.com/"), // identity (me) + contacts
        AllowedURLEntry("https://tasks.googleapis.com/"),  // Tasks
        AllowedURLEntry("https://sheets.googleapis.com/"), // Sheets (Docs/Slides export via www)
        AllowedURLEntry("https://chat.googleapis.com/"),   // Chat
        AllowedURLEntry("https://forms.googleapis.com/"),  // Forms
    ],
    allowedMethods: [.GET, .POST, .PATCH, .PUT, .DELETE])
```
Add a host prefix as each family lands. No `oauth2.googleapis.com` / `accounts.google.com`
— those belong to the host's auth flow, which is out of scope. Optional defense-in-depth:
narrow `allowedMethods` (e.g. drop `POST`) to enforce a read-only profile at the network
layer — this backs `--gmail-no-send` with a second, sandbox-level guarantee.

**Subcommand mapping (verified):** `BashCommandKit/API/AsyncParsableCommandBridge.swift`
dispatches via `Parsed.parseAsRoot(args)`, resolving nested `subcommands:` to the concrete
leaf; `Shell+SwiftPortsCommands.swift:79` proves `install(GhCommand.self)` makes the whole
`gh issue list …` tree addressable from one registration. So the entire kong tree in
`gogcli/internal/cmd/root.go` maps to one `GogCommand` + nested `subcommands:` + one
`install`. gogcli's `RootFlags` (global `--json/--account/--dry-run/--force/--no-input`)
become a shared `@OptionGroup` repeated on leaves (ArgumentParser doesn't inherit parent
options the way kong's `embed`+`Bind` does — `GogSchemaGen` emits the repetition).

---

## Identity & credentials (host-owned)

`SwiftGog` runs **no OAuth**. The host implements and injects:

```swift
// GogCore — implemented by the app; GogCore contains NO OAuth/Keychain logic.
public protocol GogCredentialProvider: Sendable {
    /// A currently-valid OAuth access token for the active account/tenant.
    func accessToken() async throws -> String
    /// Called after a 401: the host returns a freshly-refreshed token (or throws).
    func refreshedAccessToken() async throws -> String
    /// Optional account/tenant label, surfaced by `gog auth status`.
    var accountHint: String? { get }
}

public enum GogCredentials {
    @TaskLocal public static var current: GogCredentialProvider?
}
```

`GoogleHTTPClient`:
1. reads `GogCredentials.current`; if `nil`, **fails closed** with an exit-7-style
   "no credentials" error (mirrors `CurlCommand`'s `ExitStatus(7)` on a nil `networkConfig`);
2. attaches `Authorization: Bearer <accessToken()>`;
3. on `401`, retries **once** with `refreshedAccessToken()` — the *host* decides how to
   refresh (it owns the refresh token and the token endpoint). If that still fails, the
   command exits with a "re-auth required" status the host can interpret.

Consequences: no token-refresh concurrency to manage in `GogCore` (the provider, being an
actor/`Sendable`, handles its own); `--account` becomes a hint the provider may use to
select a tenant, not something `SwiftGog` stores; the token lives only in memory for the
duration of a request and **must never be printed** (skill safety rule + lint intent).

---

## Critical contracts (violating these silently defeats the sandbox)

1. **File I/O only through the shell FS.** Use `Shell.bashCurrent.fileSystem.{readData,
   writeData,list,metadata,createDirectory,copy,move,remove}`,
   `Shell.bashCurrent.resolvePath(_:)`, `openInputPath/openOutputPath`, `readDataAtPath`.
   **Never** `FileManager`, `Data(contentsOf:)`, `FileHandle`, or `URL` file I/O — those
   bypass `MountedFileSystem` (its own code rejects such targets:
   `MountedFileSystem.swift:361` "FileManager bypasses our virtual mount table"). Confirmed
   pattern in `LsCommand.swift`, `CatCommand.swift`, `MkdirCommand.swift`, `TeeCommand.swift`
   (all use `Shell.bashCurrent`).
2. **HTTPS only through `SecureFetcher`.** `GoogleHTTPClient` builds
   `SecureFetcher(config: Shell.bashCurrent.networkConfig)` (fail closed with an
   exit-7-style error if `nil`) and issues `NetworkRequest`s — exactly as
   `CurlCommand.run(argv:fetcher:)` does, including its injectable `NetworkFetcher` seam for
   tests. **Never** a raw `URLSession` (bypasses the allow-list).
3. **Credentials only through the injected provider.** Read tokens from
   `GogCredentials.current` only. **Never** stash them in `Shell.environment`, in the `gog`
   argv, or on the mounted FS — `env`/`printenv` and any `cat` would expose them to
   model-authored bash.
4. **Guard it in CI.** A test (or SwiftLint rule) that greps `GogCore`+`GogCommands` and
   fails on `FileManager`, `Data(contentsOf:`, bare `URLSession`, and any token write into
   `environment`/argv.

---

## Command-mapping pattern (worked example: `gog drive ls`)

Reference Go: group struct in `gogcli/internal/cmd/drive.go`; impl in
`internal/cmd/drive_listing.go` (validate flags → service → `Files.List().Q().PageSize()
.Fields()` → JSON `{"files":…,"nextPageToken":…}` or human/TSV via `outfmt`).

Swift: `struct DriveLs: AsyncParsableCommand`, `commandName "ls"`, nested under `struct Drive`.
- **Flags from schema:** `@Option var parent/max(=100)/page/fields`, `@Flag var all/allDrives`,
  `@OptionGroup var global: GlobalFlags`.
- **`run()`:** validate (`max>0`, `--all` vs `--parent`) → `DriveClient` issues
  `GET https://www.googleapis.com/drive/v3/files?q=…` via `GoogleHTTPClient`/`SecureFetcher`
  with `Authorization: Bearer <token from GogCredentials.current>` → decode → emit via
  `OutFmt` (**structurally** equivalent to `drive_listing.go`; "No files" to stderr) →
  return mapped `ExitStatus`.
- **File-touching siblings:** `gog drive download` writes via
  `Shell.bashCurrent.openOutputPath(dest)` into `/gog/…`; `gog drive upload` /
  `gog gmail send --attach` read via `Shell.bashCurrent.readDataAtPath`.

**Scaffold the rest:** `gog schema --include-hidden` (`internal/cmd/schema.go`,
codegen-grade: emits name/aliases/help/flags(type,short,default,enum,envs)/positionals/
nested subcommands) → `GogSchemaGen` emits one stub per node (struct, `commandName`,
`@Option/@Flag/@Argument`, `subcommands:`), leaving each `run()` a `notImplemented` throw.
The stub gives you arg-parsing for free; **engineers still hand-write the REST call +
output mapping for every leaf** — that is the bulk of the work, not the scaffolding.

---

## Cross-cutting subsystems → Apple frameworks

- **Identity (`auth status`, `me`/`whoami`):** call People API (`people.googleapis.com`)
  with the injected token to report the active account / scopes. gogcli's
  `auth add`/`login`/`logout`/`remove` (which manage stored refresh tokens) are **host
  concerns and out of scope** — drop them, or stub them to print "auth is managed by the
  host." No interactive flow in this repo.
- **Config/state/cache paths:** port `internal/config/paths.go` to return **virtual paths**
  under the mounted workspace (`/gog/config`, `/gog/data`, `/gog/drive-downloads`,
  `/gog/gmail-attachments`, `/gog/state/gmail-watch`). **No credentials are written
  anywhere** (host-owned). All dir creation through `Shell.bashCurrent.fileSystem`.
  `--home`/`GOG_HOME` remaps the root within the virtual tree.
- **Output:** port `internal/outfmt` → `GogCore.OutFmt` writing to
  `Shell.bashCurrent.stdout`; preserve "JSON when piped" so model-consumed output is
  structured. Target **structural** parity (decode-and-compare), not byte equality.
- **Agent skill doc (carry over + adapt):** copy gogcli's `.agents/skills/gog/SKILL.md`
  into SwiftGog at the same path. Keep the command/JSON conventions and safety rules (esp.
  *"never print tokens"*). **Revise/remove** the auth + keyring sections (`GOG_KEYRING_*`,
  file-keyring, `HOME`, "baked safety-profile binary", login/logout) — auth is host-managed
  and there is no on-device credential store. Command gating is via the host registering
  only allowed commands plus the ported `--enable-commands`/`--disable-commands`/
  `--gmail-no-send`/`--dry-run`/`--force` flags.
- **MCP / backups / admin:** **MCP is removed from this repo** (the app exposes `gog` to the
  model host-side over `runCapturing`). Backups (age + `tar`/`zip` via SwiftPorts) and admin
  are post-MVP.

---

## Phased roadmap

**Phase 0 — Foundation (gates everything):** ① `GoogleHTTPClient` over `SecureFetcher`
(+ injectable `GogTransport`); ② `GogCredentialProvider` seam + `GogCredentials` task-local
+ 401-retry policy; ③ paths→virtual-FS resolver; ④ `OutFmt`; ⑤ `GogShell.registerGogCommands()`
+ root `GogCommand` skeleton; ⑥ `GogSchemaGen`.

**Phase 1 — MVP families:** **drive** (`ls`, `search`, `get`, `download`, `upload`) ·
**gmail** (`list`/`messages`, `get`, `send` — exercises `--gmail-no-send`) · **calendar**
(`events`, `get`, `create`) · **identity** (`auth status`, `me`/`whoami`) · global
`@OptionGroup` flags · top-level aliases (`gog ls`, `gog send`, `gog me` — verified present
in `root.go`) · carry over the adapted `.agents/skills/gog/SKILL.md`.

**Phase 2+ — breadth:** contacts/people, tasks, docs, sheets, slides, chat (REST-wrapper
families, scaffolded from schema). **Phase 3 — heavy/optional:** backups, admin,
analytics/searchconsole/youtube/photos/maps/keep.

**Realistic scale:** ~591 commands / ~25 product groups (verified in `root.go`); full parity
is multi-quarter, and most of the ~95K non-test Go LOC is per-service request/response
typing, pagination, field masks, retry, and error mapping that codegen does **not** cover.
MVP = foundation + 3 families + identity — enough for the model to do useful Google work
inside the sandbox.

---

## Verification

- **Per-command unit tests:** Swift Testing + `CapturingShell` (copy SwiftBash's
  `Tests/BashCommandKitTests/CapturingShell.swift` pattern) + a **fake `GogTransport`**
  returning canned Google JSON + a **stub `GogCredentialProvider`**;
  `shell.runCapturing("gog drive ls --json")`, assert `stdout`/`stderr`/`exitStatus`.
- **Output parity:** record real Google responses once → fixtures → replay through the mock
  fetcher; assert **structural** equality (decode both sides, compare) with gogcli's JSON.
  Mine `gogcli/internal/cmd/*_test.go` for expected shapes/edge cases.
- **Sandbox-enforcement tests (the core requirement):** a command writing outside the mounts
  fails `notFound`/`permissionDenied`; with `networkConfig = nil` every `gog` network command
  fails closed (exit 7); with `GogCredentials.current = nil` every authed command fails closed.
- **Credential-confinement tests:** after any `gog` run, assert the token string never
  appears in `Shell.environment`, in captured `stdout`/`stderr`, or on the mounted FS; assert
  `printenv`/`env` cannot surface it.
- **Lint-guard test:** no `FileManager`/`Data(contentsOf:)`/`URLSession`/env-token-write in
  `GogCore`+`GogCommands`.
- **E2E smoke through the sandbox:** with a `MountedFileSystem` workspace + allow-listed
  `NetworkConfig` (local stub/replay) + stub provider, run
  `gog drive ls --json | jq '.files | length'` and
  `gog drive download <id> --out /gog/out.pdf && ls -l /gog/out.pdf`; assert the file lands
  inside `/gog` and nowhere on the host.
- **Build matrix:** macOS + iOS, Swift 6.2; snapshot-test `GogSchemaGen` output.

---

## Critical files

**Reference — SwiftBash (`/home/user/SwiftBash`):** `Sources/BashInterpreter/API/FileSystem.swift`
(the FS protocol every command must use), `Sources/BashInterpreter/FileSystems/MountedFileSystem.swift`
(the confinement), `Sources/BashInterpreter/API/Shell+DevPaths.swift`
(`openInputPath`/`openOutputPath`/`readDataAtPath`), `Sources/BashCommandKit/Commands/CurlCommand.swift`
(sandboxed-HTTP + injectable-fetcher seam + exit-7 fail-closed), `Sources/BashCommandKit/API/AsyncParsableCommandBridge.swift`
+ `API/Shell+SwiftPortsCommands.swift` (nested-subcommand registration), `API/ParsableBashCommand.swift`
+ `API/Shell+ParsableCommand.swift` (install bridges), `Tests/BashCommandKitTests/CapturingShell.swift`,
`Tests/BashInterpreterTests/SecureFetcherTests.swift` (NetworkConfig/AllowedURLEntry API),
`Docs/Sandboxing.md`.

**Reference — gogcli (`/home/user/gogcli`):** `internal/cmd/schema.go` (scaffolding source),
`internal/cmd/root.go` (tree + global flags + aliases), `internal/cmd/drive_listing.go`
(mapping example), `internal/config/paths.go` (paths to virtualize), `internal/outfmt/`
(formatter). `internal/googleauth/` + `internal/secrets/` are **reference only** for the
token-consumption shape (Bearer header, 401 handling) — their flows are *not* ported.

**Create — repo `picomlx/SwiftGog`:** `Package.swift`; `Sources/GogCore/*` (incl.
`GogCredentialProvider`, `GoogleHTTPClient`, clients, `OutFmt`, paths resolver);
`Sources/GogCommands/*` (root + `Auth`/`Drive`/`Gmail`/`Calendar` groups & leaves);
`Sources/GogShell/*`; `Sources/gog/*` (dev host); `Tools/GogSchemaGen/*`; `Tests/*`;
`.agents/skills/gog/SKILL.md` (carried over from gogcli, adapted: no auth/keyring sections).

## First implementation steps (after approval)

1. The repo `picomlx/SwiftGog` already exists and is checked out on branch
   `claude/tender-gates-vc7Mi` — develop there.
2. Scaffold `Package.swift` + targets; add SwiftBash as a package dependency
   (`BashInterpreter` + `BashCommandKit`).
3. Prove the wiring end-to-end with a trivial `gog version` command run through a
   **sandboxed** `Shell` via `runCapturing` (plus a sandbox-deny test, a `networkConfig = nil`
   deny test, and a `GogCredentials.current = nil` deny test) before building Phase 0.
4. Build Phase 0 foundation, then Phase 1 families, scaffolding stubs from `gog schema`.
