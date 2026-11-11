import Foundation
import os

/// Unified logging for the data layer and view models (Console.app:
/// subsystem `com.eplisium.omega-journal`, one category per layer).
///
/// Rules: anything that can carry user content — titles, tags, file names,
/// paths, SQLite error text that may quote a value — is interpolated with
/// `privacy: .private`. Fixed context strings and numbers may be public.
nonisolated enum OmegaLog {
    static let subsystem = "com.eplisium.omega-journal"

    /// SQLite connection, reads, writes, migrations.
    static let database = Logger(subsystem: subsystem, category: "database")
    /// Encryption keys and sealed data.
    static let encryption = Logger(subsystem: subsystem, category: "encryption")
    /// Full-text index and search.
    static let search = Logger(subsystem: subsystem, category: "search")
    /// Tags and organization.
    static let organization = Logger(subsystem: subsystem, category: "organization")
    /// View-model state (reloads, read failures shown to the user).
    static let viewModel = Logger(subsystem: subsystem, category: "viewmodel")
}
