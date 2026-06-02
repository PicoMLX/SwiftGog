/// Host-set safety policy — the SwiftBash form of gogcli's `--gmail-no-send`
/// and friends. The host binds it around a run via `GogPolicies.$current`;
/// LLM-authored bash cannot change it (it is not surfaced as a command flag).
public struct GogPolicy: Sendable {
    /// When true, `gog gmail send` refuses to send (exit 3).
    public var gmailSendDisabled: Bool

    public init(gmailSendDisabled: Bool = false) {
        self.gmailSendDisabled = gmailSendDisabled
    }
}

public enum GogPolicies {
    @TaskLocal public static var current = GogPolicy()
}
