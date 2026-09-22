import Foundation
import ResAICore

@MainActor
enum AppLog {
    static let textPreviewLoggingKey = "diagnostics.textPreviewLoggingEnabled"

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        LogFileSink.shared.append(line)
    }

    static func writeTextPreview(_ message: @autoclosure () -> String, redacted: String) {
        guard isTextPreviewLoggingEnabled else {
            write(redacted)
            return
        }

        write(message())
    }

    static func flushSync() {
        LogFileSink.shared.flushSync()
    }

    static var isTextPreviewLoggingEnabled: Bool {
        let env = ProcessInfo.processInfo.environment["RESAI_LOG_TEXT_PREVIEWS"]?.lowercased()
        if ["1", "true", "yes"].contains(env) {
            return true
        }

        return UserDefaults.standard.bool(forKey: textPreviewLoggingKey)
    }

    static var logURL: URL {
        LogFileSink.logURL
    }
}

/// File I/O on a utility serial queue. `buffer` is protected by `lock`.
private final class LogFileSink: @unchecked Sendable {
    static let shared = LogFileSink()

    private let lock = NSLock()
    private var buffer = Data()
    private let queue = DispatchQueue(label: "ai.res.resai.log", qos: .utility)
    private var flushWorkItem: DispatchWorkItem?

    static var logURL: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        return (library ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library"))
            .appendingPathComponent("Logs")
            .appendingPathComponent("ResponseAi")
            .appendingPathComponent("responseai.log")
    }

    static var rotatedLogURL: URL {
        logURL.deletingLastPathComponent().appendingPathComponent("responseai.1.log")
    }

    func append(_ line: String) {
        guard let data = line.data(using: .utf8) else {
            return
        }

        lock.lock()
        buffer.append(data)
        let overflow = buffer.count >= 8 * 1024
        lock.unlock()

        if overflow {
            flushAsync(immediate: true)
        } else {
            scheduleDebouncedFlush()
        }
    }

    func flushSync() {
        lock.lock()
        let pending = buffer
        buffer = Data()
        flushWorkItem?.cancel()
        flushWorkItem = nil
        lock.unlock()

        queue.sync {
            Self.writeToFile(pending)
        }
    }

    private func scheduleDebouncedFlush() {
        lock.lock()
        if flushWorkItem != nil {
            lock.unlock()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.flushAsync(immediate: true)
        }
        flushWorkItem = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 0.250, execute: work)
    }

    private func flushAsync(immediate: Bool) {
        lock.lock()
        flushWorkItem?.cancel()
        flushWorkItem = nil
        let pending = buffer
        buffer = Data()
        lock.unlock()

        if pending.isEmpty {
            return
        }

        if immediate {
            queue.async {
                Self.writeToFile(pending)
            }
        } else {
            queue.async {
                Self.writeToFile(pending)
            }
        }
    }

    private static func writeToFile(_ data: Data) {
        guard !data.isEmpty else {
            return
        }

        let logURL = self.logURL
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        LogRotationPolicy.rotateIfNeeded(current: logURL, rotated: rotatedLogURL)

        if FileManager.default.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }
}
