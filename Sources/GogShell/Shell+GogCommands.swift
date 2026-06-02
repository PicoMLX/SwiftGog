import BashInterpreter
import BashCommandKit
import GogCommands

public extension Shell {
    /// Register `gog` (and its full nested subcommand tree) into this shell —
    /// the one-call integration mirroring `registerStandardCommands()` /
    /// `registerSwiftPortsCommands()`.
    ///
    /// `gog` is not in SwiftBash's `BinCatalog`, so it is slotted under
    /// `/usr/local/bin` — the same convention SwiftPorts uses for off-catalog
    /// commands like `fd`. (Using the bare `install(_:)` would trap on the
    /// missing catalog entry.)
    func registerGogCommands() {
        install(GogCommand.self, at: "/usr/local/bin/gog")
    }
}
