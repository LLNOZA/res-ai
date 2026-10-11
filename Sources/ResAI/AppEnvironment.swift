import AppKit
import Foundation
import ResAICore

enum AppRuntime {
    /// True inside an XCTest process (`swift test`). The app never loads XCTest.
    static let isRunningUnitTests = NSClassFromString("XCTestCase") != nil
}

/// Everything the app reads or writes outside its own memory: settings, Keychain,
/// clipboard, and System Settings. Tests use `isolated()` so a run never changes the
/// user's real state.
@MainActor
struct AppEnvironment {
    var defaults: UserDefaults
    var secretStore: any SecretStringStoring
    var pasteboard: NSPasteboard
    /// Opens System Settings panes. Returns false when nothing opened.
    var openURL: (URL) -> Bool
    /// Set by `isolated()` so `discard()` can remove the temporary settings domain.
    private(set) var temporarySuiteName: String?

    init(
        defaults: UserDefaults,
        secretStore: any SecretStringStoring,
        pasteboard: NSPasteboard,
        openURL: @escaping (URL) -> Bool,
        temporarySuiteName: String? = nil
    ) {
        self.defaults = defaults
        self.secretStore = secretStore
        self.pasteboard = pasteboard
        self.openURL = openURL
        self.temporarySuiteName = temporarySuiteName
    }

    static var live: AppEnvironment {
        AppEnvironment(
            defaults: .standard,
            secretStore: KeychainStore(),
            pasteboard: .general,
            openURL: { NSWorkspace.shared.open($0) }
        )
    }

    /// The real environment in the app and an isolated one inside a test process, so a
    /// default argument can never reach the user's settings, Keychain, or clipboard from a test.
    static var current: AppEnvironment {
        AppRuntime.isRunningUnitTests ? .isolated() : .live
    }

    /// A private settings suite, in-memory Keychain, uniquely named pasteboard, and a
    /// URL opener that opens nothing unless the test supplies one.
    static func isolated(openURL: @escaping (URL) -> Bool = { _ in false }) -> AppEnvironment {
        let suiteName = "ai.res.resai.tests.\(UUID().uuidString)"
        return AppEnvironment(
            defaults: UserDefaults(suiteName: suiteName) ?? .standard,
            secretStore: InMemorySecretStore(),
            pasteboard: NSPasteboard.withUniqueName(),
            openURL: openURL,
            temporarySuiteName: suiteName
        )
    }

    /// Removes the temporary settings domain and pasteboard created by `isolated()`.
    func discard() {
        guard let temporarySuiteName else { return }
        defaults.removePersistentDomain(forName: temporarySuiteName)
        pasteboard.releaseGlobally()
    }
}
