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

    public init(gmailSendDisabled: Bool = false,
                chatSendDisabled: Bool = false,
                adminWriteDisabled: Bool = true) {
        self.gmailSendDisabled = gmailSendDisabled
        self.chatSendDisabled = chatSendDisabled
        self.adminWriteDisabled = adminWriteDisabled
    }
}

public enum GogPolicies {
    @TaskLocal public static var current = GogPolicy()
}
