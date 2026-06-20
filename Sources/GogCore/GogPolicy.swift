/// Host-set safety policy — the SwiftBash form of gogcli's `--gmail-no-send`
/// and friends. The host binds it around a run via `GogPolicies.$current`;
/// LLM-authored bash cannot change it (it is not surfaced as a command flag).
public struct GogPolicy: Sendable {
    /// When true, `gog gmail send` refuses to send (exit 3).
    public var gmailSendDisabled: Bool
    /// When true, `gog chat send` refuses to send (exit 3).
    public var chatSendDisabled: Bool
    /// When true, the `gog admin` write commands (suspend/unsuspend a user,
    /// add/remove a group member) refuse (exit 3). Unlike sending, these
    /// directory mutations are **high-blast-radius, so they default to
    /// disabled** — the host must opt in by setting this to false.
    public var adminWriteDisabled: Bool
    /// The capability tier the host grants the **data-mutation** commands —
    /// everything that creates, edits, or deletes Google data (Calendar, Tasks,
    /// Gmail labels/trash, Drive, Sheets, Contacts). Defaults to `.readOnly`, so
    /// those commands refuse (exit 3) until the host raises it to `.edit`
    /// (additive / in-place / reversible — create, add, append, mkdir, cp,
    /// rename, update, label changes, untrash) or `.full` (also destructive /
    /// irreversible / sharing — delete, trash, move, share, unshare, clear).
    ///
    /// This does **not** cover the external-communication or directory flows,
    /// which keep their own dedicated switches: `gmailSendDisabled` /
    /// `chatSendDisabled` gate sending (default enabled) and `adminWriteDisabled`
    /// gates directory writes (default blocked). A fully locked-down host sets
    /// `writeTier = .readOnly` *and* disables sending.
    ///
    /// Host-only: bound via `GogPolicies.$current`, never a command flag or
    /// environment variable, so LLM-authored bash can't escalate.
    public var writeTier: GogWriteTier

    public init(gmailSendDisabled: Bool = false,
                chatSendDisabled: Bool = false,
                adminWriteDisabled: Bool = true,
                writeTier: GogWriteTier = .readOnly) {
        self.gmailSendDisabled = gmailSendDisabled
        self.chatSendDisabled = chatSendDisabled
        self.adminWriteDisabled = adminWriteDisabled
        self.writeTier = writeTier
    }
}

/// The tiers of write access a host can grant, in increasing order. `Comparable`
/// so a command can require a minimum (e.g. `.full`) and the gate checks
/// `granted >= required`.
public enum GogWriteTier: Int, Sendable, Comparable, CaseIterable {
    /// No mutations — list / get / search / download / export only (default).
    case readOnly
    /// Additive, in-place, or reversible writes (create, rename, update, …).
    case edit
    /// Also destructive, irreversible, or sharing / exposing writes.
    case full

    public static func < (lhs: GogWriteTier, rhs: GogWriteTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum GogPolicies {
    @TaskLocal public static var current = GogPolicy()
}
