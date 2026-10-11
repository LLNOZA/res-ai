import CryptoKit
import Foundation
import MetricKit
import ResAICore

/// Records whether the previous run ended through `applicationWillTerminate`.
/// A run that is still marked as running at the next launch crashed, hung and was
/// force quit, or was killed.
@MainActor
struct SessionExitTracker {
    enum PreviousExit: Equatable {
        case firstLaunch
        case clean
        case unexpected(startedAt: Date?, version: String?)
    }

    let defaults: UserDefaults

    /// Reads the previous run's state and marks this run as running.
    func beginSession(version: String, now: Date = Date()) -> PreviousExit {
        let previous: PreviousExit
        switch defaults.object(forKey: Key.running) as? Bool {
        case nil:
            previous = .firstLaunch
        case false?:
            previous = .clean
        case true?:
            previous = .unexpected(
                startedAt: defaults.object(forKey: Key.startedAt) as? Date,
                version: defaults.string(forKey: Key.version)
            )
        }
        defaults.set(true, forKey: Key.running)
        defaults.set(now, forKey: Key.startedAt)
        defaults.set(version, forKey: Key.version)
        return previous
    }

    func endSession() {
        defaults.set(false, forKey: Key.running)
    }

    static func logLine(for exit: PreviousExit) -> String {
        switch exit {
        case .firstLaunch:
            return "previous session: none recorded"
        case .clean:
            return "previous session: ended normally"
        case .unexpected(let startedAt, let version):
            let started = startedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "?"
            return "previous session: ended unexpectedly (crash, hang, force quit, or kill) started=\(started) version=\(version ?? "?")"
        }
    }

    private enum Key {
        static let running = "diagnostics.session.running"
        static let startedAt = "diagnostics.session.startedAt"
        static let version = "diagnostics.session.version"
    }
}

/// Saves MetricKit crash and hang diagnostics as sanitized JSON under
/// `<log directory>/diagnostics/`. MetricKit delivers them at the next launch.
final class MetricKitDiagnosticsRecorder: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    @MainActor
    func start() {
        let manager = MXMetricManager.shared
        manager.add(self)
        record(manager.pastDiagnosticPayloads)
    }

    @MainActor
    func stop() {
        MXMetricManager.shared.remove(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        record(payloads)
    }

    private func record(_ payloads: [MXDiagnosticPayload]) {
        let saved = payloads.compactMap { payload in
            Self.write(payloadJSON: payload.jsonRepresentation(), to: directory)
        }
        guard !saved.isEmpty else { return }
        let names = saved.map(\.lastPathComponent).joined(separator: ",")
        Task { @MainActor in
            AppLog.write("metrickit diagnostics saved count=\(saved.count) files=\(names)")
        }
    }

    /// Writes one sanitized payload. The file name is derived from the content, so a
    /// payload delivered again (past payloads at every launch) is not duplicated.
    /// Returns nil when there was nothing to save or it already exists.
    static func write(payloadJSON: Data, to directory: URL) -> URL? {
        guard let sanitized = DiagnosticPayloadSanitizer.sanitize(payloadJSON) else {
            return nil
        }
        let digest = SHA256.hash(data: sanitized).prefix(8).map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent("diagnostic-\(digest).json")
        guard !FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try sanitized.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

enum DiagnosticsExportError: LocalizedError {
    case zipFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .zipFailed(let status):
            "診断情報の zip を作成できませんでした（ditto 終了コード \(status)）。"
        }
    }
}

/// Bundles the app log, MetricKit diagnostics, and a system summary into one zip.
struct DiagnosticsExporter {
    var logDirectory: URL
    var destinationDirectory: URL
    var systemSummary: String
    var now = Date()

    func export() throws -> URL {
        let fileManager = FileManager.default
        let name = "ResponseAi-diagnostics-\(Self.timestamp(now))"
        let workDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let staging = workDirectory.appendingPathComponent(name)
        defer { try? fileManager.removeItem(at: workDirectory) }

        let logs = staging.appendingPathComponent("logs")
        try fileManager.createDirectory(at: logs, withIntermediateDirectories: true)
        for fileName in ["responseai.log", "responseai.1.log"] {
            let source = logDirectory.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.copyItem(at: source, to: logs.appendingPathComponent(fileName))
            }
        }

        let diagnostics = logDirectory.appendingPathComponent("diagnostics")
        if let files = try? fileManager.contentsOfDirectory(at: diagnostics, includingPropertiesForKeys: nil) {
            let target = staging.appendingPathComponent("diagnostics")
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            for file in files where file.pathExtension == "json" {
                try fileManager.copyItem(at: file, to: target.appendingPathComponent(file.lastPathComponent))
            }
        }

        try Data(systemSummary.utf8).write(to: staging.appendingPathComponent("system.txt"))

        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let zipURL = uniqueURL(named: name, in: destinationDirectory)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", staging.path, zipURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DiagnosticsExportError.zipFailed(process.terminationStatus)
        }
        return zipURL
    }

    private func uniqueURL(named name: String, in directory: URL) -> URL {
        var url = directory.appendingPathComponent("\(name).zip")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(name)-\(suffix).zip")
            suffix += 1
        }
        return url
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

enum AppVersionInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
    }

    static var operatingSystem: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// e.g. "Mac14,2". Hardware model only; no serial number or user name.
    static var hardwareModel: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return "?"
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
            return "?"
        }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}
