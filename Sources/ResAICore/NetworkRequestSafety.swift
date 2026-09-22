import Foundation

/// Shared, side-effect-free network guards. User-configured endpoints are accepted only over
/// HTTPS; plain HTTP is permitted for loopback development servers and nowhere else.
public enum NetworkRequestSafety {
    public static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()
    public static func isAllowedURL(_ url: URL, allowLoopbackHTTP: Bool = true) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
            return false
        }
        guard url.user == nil && url.password == nil else { return false }
        switch scheme {
        case "https": return true
        case "http" where allowLoopbackHTTP: return isLoopbackHost(host)
        default: return false
        }
    }

    static func safeBody(_ body: String, limit: Int = 512) -> String {
        var sanitized = body
        let patterns = [
            #"(?i)(api[-_ ]?key|authorization|bearer|token|secret|password)(\s*[:=]\s*|\s+)[^\s,;]+"#,
            #"(?i)(AIza[0-9A-Za-z_-]{20,})"#,
            #"(?i)(ya29\.[0-9A-Za-z_-]{20,})"#
        ]
        for pattern in patterns {
            if let expression = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized)
                sanitized = expression.stringByReplacingMatches(
                    in: sanitized,
                    range: range,
                    withTemplate: "[redacted]"
                )
            }
        }
        sanitized = sanitized
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard sanitized.count > limit else {
            return sanitized
        }
        return String(sanitized.prefix(limit)) + "…"
    }

    static func runWithTimeout<T: Sendable>(
        _ timeout: TimeInterval,
        timeoutError: Error,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard timeout.isFinite, timeout > 0 else { throw timeoutError }
        let state = TimeoutState<T>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                state.install(continuation: continuation)
                let operationTask = Task { () -> Void in
                    do {
                        state.finish(.success(try await operation()))
                    } catch {
                        state.finish(.failure(error))
                    }
                }
                let timerTask = Task { () -> Void in
                    do {
                        let nanoseconds = UInt64(min(timeout, 3600) * 1_000_000_000)
                        try await Task.sleep(nanoseconds: nanoseconds)
                        state.finish(.failure(timeoutError))
                        operationTask.cancel()
                    } catch {
                        // Cancellation means the operation completed or the caller cancelled it.
                    }
                }
                state.install(operationTask: operationTask, timerTask: timerTask)
            }
        }, onCancel: {
            state.cancel()
        })
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return normalized == "localhost"
            || normalized == "127.0.0.1"
            || normalized == "::1"
    }
}

// Shared-secret headers must not be forwarded to a redirected host or cleartext URL.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class TimeoutState<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var operationTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var cancelled = false
    private var finished = false

    func install(continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        self.continuation = continuation
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel {
            finish(.failure(CancellationError()))
        }
    }

    func install(operationTask: Task<Void, Never>, timerTask: Task<Void, Never>) {
        lock.lock()
        self.operationTask = operationTask
        self.timerTask = timerTask
        let shouldCancel = cancelled || finished
        lock.unlock()
        if shouldCancel {
            operationTask.cancel()
            timerTask.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let operationTask = self.operationTask
        let timerTask = self.timerTask
        let shouldFinish = !finished && continuation != nil
        lock.unlock()
        operationTask?.cancel()
        timerTask?.cancel()
        if shouldFinish {
            finish(.failure(CancellationError()))
        }
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard !finished, let continuation else {
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        let operationTask = self.operationTask
        let timerTask = self.timerTask
        lock.unlock()
        operationTask?.cancel()
        timerTask?.cancel()
        continuation.resume(with: result)
    }
}
