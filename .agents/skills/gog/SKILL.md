---
name: gog
description: "gog: sandboxed Google Workspace CLI for SwiftBash — JSON-first reads/writes for Drive, Gmail, and Calendar, with host-managed auth."
---

# gog

`gog` is a Google Workspace CLI that runs **inside SwiftBash's sandbox**. Use it
to read and write Google Drive, Gmail, and Calendar from shell automation that
needs stable JSON. It pipes like any other command:

```bash
gog drive ls --max 20 --json | jq '.files[].name'
```

## How it runs (sandbox model)

- **Auth is host-managed.** The app injects a Google access token for the active
  account; `gog` never performs OAuth, stores credentials, or reads tokens from
  the environment. There is no `gog auth add` / login here. On an expired token
  `gog` asks the host to refresh and retries once; if it still fails it exits 7
  ("re-auth required") for the host to handle.
- **Files stay in the sandbox.** Reads and writes go through the mounted
  workspace (e.g. `/gog`). Paths outside the mounts are rejected, so download
  and upload targets must be sandbox paths.
- **Network is allow-listed.** Only Google API hosts are reachable; with no
  network configured, networked commands fail closed (exit 7).
- **JSON for agents.** Pass `--json` for machine-readable output. Data goes to
  stdout; hints, progress, and errors go to stderr.

## Safety rules

- **Never print tokens or secrets.** `gog` does not emit them, they are not in
  the environment, and you should not try to extract or echo credentials.
- **Sending email is gated.** `gog gmail send` refuses to send when the host has
  disabled sending (exit 3). Use `--dry-run` to preview a message without
  sending. Only send when sending is the requested task.
- **Preview writes with `--dry-run`** where supported (`gmail send`,
  `calendar create`) before performing the mutation.
- **Command availability is host-controlled.** The host registers only the
  commands it allows; if a command isn't available, it wasn't enabled.

## Identity

```bash
gog me --json            # your Google profile (People API)
gog whoami               # alias of `me`
gog auth status          # can the sandbox reach Google with the injected token?
```

## Drive

```bash
gog drive ls --max 20 --json
gog drive ls --parent <folderId> --json
gog drive search 'quarterly report' --json
gog drive get <fileId> --json
gog drive download <fileId> --out /gog/report.pdf
```

`download` writes into the sandbox workspace — choose a path under a mount
(e.g. `/gog/...`).

## Gmail

```bash
gog gmail messages --max 20 --json
gog gmail messages -q 'newer_than:7d from:example@example.com' --json
gog gmail get <messageId> --json
gog gmail send --to user@example.com --subject 'Hi' --body 'Hello' --dry-run
```

Drop `--dry-run` to actually send (subject to the host send policy).

## Calendar

```bash
gog calendar events --max 20 --json
gog calendar events --from 2026-06-01T00:00:00Z --json
gog calendar get <eventId> --json
gog calendar create --summary 'Standup' \
  --start 2026-06-02T10:00:00Z --end 2026-06-02T10:30:00Z --dry-run
```

## Contacts

```bash
gog contacts list --max 20 --json
gog contacts get people/c123 --json
```

## Tasks

```bash
gog tasks lists --json
gog tasks list --list <listId> --json
gog tasks add 'Buy milk' --list <listId>
```

## Docs

```bash
gog docs cat <documentId>                 # prints the doc's text
gog docs cat <documentId> --format markdown
gog docs cat <documentId> --out /gog/doc.md
```

## Sheets

```bash
gog sheets get <spreadsheetId> 'Sheet1!A1:D20' --json
gog sheets update <spreadsheetId> 'Sheet1!A1' --values-json '[["hello","world"]]' --dry-run
```

## Discovery

```bash
gog --help
gog <service> --help
gog <service> <command> --help
gog version
```

## Notes

- With `--json` the output is structured JSON; otherwise it is a compact
  human / TSV form (id, then key fields, tab-separated).
- Surface: identity, Drive, Gmail, Calendar, Contacts, Tasks, Docs, Sheets.
  More services are planned — see `PLAN.md`.
