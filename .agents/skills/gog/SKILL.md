---
name: gog
description: "gog: sandboxed Google Workspace CLI for SwiftBash — JSON-first reads and host-gated writes across Drive, Gmail, Calendar, Tasks, Sheets, Contacts and more, with host-managed auth."
---

# gog

`gog` is a Google Workspace CLI that runs **inside SwiftBash's sandbox**. Use it
to read and write Google Drive, Gmail, Calendar, Tasks, Sheets, Contacts and
more from shell automation that needs stable JSON. Writes are gated by a
host-set capability tier (read-only by default). It pipes like any other command:

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
- **Data writes need a host-granted tier.** Every create / edit / delete across
  Drive, Gmail (labels · trash · drafts), Calendar, Tasks, Sheets, and Contacts
  is gated by a write tier the host sets — **read-only by default**, so writes
  refuse with **exit 3** until the host grants `edit` (additive / in-place /
  reversible: create, rename, update, append, mkdir, cp, untrash, label edits)
  or `full` (also destructive or exposing: delete, trash, move, share, unshare,
  clear, adding the TRASH/SPAM labels, and copying or uploading *into a folder*).
  You **cannot** raise this from the command line — it is host-only. If a write
  exits 3 with "needs write tier …", it wasn't granted; don't try to bypass it.
- **Sending and directory writes have separate switches.** `gog gmail send` and
  `gog chat send` refuse (exit 3) when the host disables sending; `gog admin`
  suspend/unsuspend and member-add/remove are **off by default** (domain-wide
  blast radius) until the host enables admin writes. These are independent of the
  write tier above.
- **Preview any write with `--dry-run`.** Every mutating command builds and
  prints the request without calling Google when `--dry-run` is passed; use it
  before performing a mutation. Only send/mutate when that is the requested task.
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

gog drive permissions <fileId> --json   # who can access it (id, role, type, who)
gog drive revisions <fileId> --json      # version history
gog drive about --json                    # storage quota + account

# Writes — need the host's write tier (read-only by default); --dry-run previews
gog drive upload /gog/report.pdf --name Report.pdf      # edit (--parent needs full)
gog drive mkdir 'Q3 Reports' --parent <folderId>         # edit
gog drive rename <fileId> 'Final.pdf'                    # edit
gog drive cp <fileId> --name Copy.pdf                    # edit (--parent needs full)
gog drive untrash <fileId>                               # edit
gog drive trash <fileId>                                 # full (reversible via untrash)
gog drive mv <fileId> --to <folderId> [--from <oldId>]   # full
gog drive share <fileId> --email user@x.com --role reader [--notify]   # full
gog drive share <fileId> --anyone --role reader          # full
gog drive unshare <fileId> --permission <permId>         # full
```

`download` writes into the sandbox workspace — choose a path under a mount
(e.g. `/gog/...`).

## Gmail

```bash
gog gmail messages --max 20 --json
gog gmail messages -q 'newer_than:7d from:example@example.com' --json
gog gmail get <messageId> --json
gog gmail send --to user@example.com --subject 'Hi' --body 'Hello' --dry-run
gog gmail labels --json

gog gmail threads -q 'newer_than:7d' --json   # list threads
gog gmail thread <threadId> --json            # a thread's messages (From/Subject)
gog gmail drafts --json                        # list drafts
gog gmail draft --to user@example.com --subject 'Hi' --body 'Hello'  # compose (does NOT send)
gog gmail attachments <messageId> --json   # discover attachment IDs (id, filename, type, size)
gog gmail attachment <messageId> <attachmentId> --out /gog/file.pdf  # then download to sandbox

# Writes
gog gmail modify <messageId> --add-label STARRED --remove-label UNREAD   # edit
gog gmail untrash <messageId>                # edit
gog gmail trash <messageId>                  # full — reversible (adding TRASH/SPAM via modify also needs full)
```

Drop `--dry-run` to actually send (subject to the host send policy). `gog gmail
draft` only composes — it never sends, so it isn't gated by the send policy.

## Calendar

```bash
gog calendar events --max 20 --json
gog calendar events --from 2026-06-01T00:00:00Z --json
gog calendar get <eventId> --json
gog calendar create --summary 'Standup' \
  --start 2026-06-02T10:00:00Z --end 2026-06-02T10:30:00Z --dry-run

gog calendar calendars --json                 # your calendar list (id, summary, role)
gog calendar freebusy --json                  # busy slots, next 24h on primary
gog calendar freebusy --from <RFC3339> --to <RFC3339> \
  --calendar primary --calendar team@example.com --json   # busy across calendars

# Writes
gog calendar update <eventId> --summary 'Renamed' --dry-run   # edit (needs ≥1 field)
gog calendar delete <eventId>                                 # full (alias: rm)
```

## Contacts

```bash
gog contacts list --max 20 --json
gog contacts get people/c123 --json
gog contacts search 'jane' --json        # resolve a name → email (People searchContacts)
gog contacts other --json                 # auto-saved "other contacts"

# Writes
gog contacts create --given Jane --family Doe --email jane@x.com   # edit
gog contacts update people/c123 --given Janet --email new@x.com    # edit (keeps other name parts)
gog contacts delete people/c123                                    # full
```

## Tasks

```bash
gog tasks lists --json
gog tasks list --list <listId> --json
gog tasks add 'Buy milk' --list <listId>
gog tasks complete <taskId> --list <listId>             # edit (alias: done)
gog tasks delete <taskId> --list <listId>               # full (alias: rm)
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
gog sheets append <spreadsheetId> 'Sheet1!A1' --values-json '[["a","b"]]'   # edit (after the table)
gog sheets clear <spreadsheetId> 'Sheet1!A1:D9'                             # full
```

## Slides

```bash
gog slides export <presentationId> --out /gog/deck.pdf
gog slides export <presentationId> --mime text/plain --out /gog/deck.txt
```

## Chat

```bash
gog chat spaces --json
gog chat messages spaces/AAAA --json
gog chat send spaces/AAAA --text 'Hello' --dry-run
```

## Forms

```bash
gog forms get <formId> --json
gog forms responses <formId> --json
```

## YouTube

```bash
gog youtube my-channel --json
gog youtube search 'swift concurrency' --max 10 --json
gog youtube playlists --json
```

## Admin (Directory + Reports)

Admin SDK. Requires a host token with the matching admin scopes (Directory for
users/groups, `admin.reports.audit.readonly` for `activities`) belonging to a
Workspace admin; otherwise Google returns 403. Directory listings default to
the admin's own customer.

```bash
# Reads
gog admin users --json                    # directory users (--domain / --query to narrow)
gog admin user alice@example.com --json   # one user by email or id
gog admin groups --json                   # groups (--user <email> for a user's groups)
gog admin group eng@example.com --json    # one group
gog admin members eng@example.com --json  # a group's members (--roles OWNER,MANAGER)
gog admin activities login --json         # audit log (admin/drive/token/…; --user, --event)

# Writes — disabled by default; the host must opt in, and --dry-run previews
gog admin suspend alice@example.com --dry-run        # then drop --dry-run to apply
gog admin unsuspend alice@example.com
gog admin member-add eng@example.com bob@example.com --role MEMBER --dry-run
gog admin member-remove eng@example.com bob@example.com
```

These directory **writes are high-blast-radius and gated**: they refuse with
exit 3 unless the host has enabled admin writes. Always `--dry-run` first. The
host token also needs the **write** Directory scopes (the read-only scopes are
not enough): `…/auth/admin.directory.user` for suspend/unsuspend, and
`…/auth/admin.directory.group.member` (or `…/admin.directory.group`) for
member-add/remove — otherwise Google returns 403.

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
- List commands accept `--fail-empty` (aliases `--non-empty` /
  `--require-results`): exit 3 instead of 0 when there are no results, so a
  script can branch without parsing the output.
- Surface: identity, Drive, Gmail, Calendar, Contacts, Tasks, Docs, Sheets,
  Chat, Slides, Forms, YouTube, Admin (Directory + Reports). More services are planned —
  see `PLAN.md`.
