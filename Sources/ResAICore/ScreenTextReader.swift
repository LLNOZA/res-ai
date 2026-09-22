import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

public final class ScreenTextReader: Sendable {
    public init() {}

    public func captureContextLines(above inputFrame: CGRect?, maxLines: Int = 24) -> [ContextLine] {
        guard let inputFrame else {
            return []
        }
        guard Self.hasScreenCaptureAccess() else {
            return []
        }

        let captureRect = contextCaptureRect(above: inputFrame)
        guard captureRect.width >= 120, captureRect.height >= 80 else {
            return []
        }

        guard let image = captureImage(in: captureRect) else {
            return []
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        let lines = recognizedLines(from: request.results ?? [], captureRect: captureRect)
            .filter { !$0.text.isEmpty }
        // Keep the latest lines nearest the input as well as the opening context. A prefix here
        // drops the newest messages in long browser conversations before ContextTextFilter can
        // apply its own bounded head/tail policy.
        return ContextWindow.headAndTail(lines, limit: max(0, maxLines))
    }

    public static func hasScreenCaptureAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public static func requestScreenCaptureAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    private func contextCaptureRect(above inputFrame: CGRect) -> CGRect {
        let horizontalPadding: CGFloat = 300
        let verticalLookback: CGFloat = 920
        let gapAboveInput: CGFloat = 10
        // AX/AppKit screen coordinates may legitimately be negative on displays placed above or
        // left of the primary display. Keep the global rect intact; captureImageWithContentFilter
        // intersects it with the selected display's actual frame below.
        let minY = inputFrame.minY - verticalLookback
        let height = max(0, inputFrame.minY - minY - gapAboveInput)

        return CGRect(
            x: inputFrame.minX - horizontalPadding,
            y: minY,
            width: inputFrame.width + horizontalPadding * 2,
            height: height
        )
    }

    private func captureImage(in rect: CGRect) -> CGImage? {
        if #available(macOS 15.2, *) {
            return captureImageInRect(rect)
        }

        return captureImageWithContentFilter(in: rect)
    }

    @available(macOS 15.2, *)
    private func captureImageInRect(_ rect: CGRect) -> CGImage? {
        let semaphore = DispatchSemaphore(value: 0)
        let result = ScreenCaptureResultBox()

        SCScreenshotManager.captureImage(in: rect) { image, _ in
            result.set(image: image)
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 2.0)
        return result.image
    }

    private func captureImageWithContentFilter(in rect: CGRect) -> CGImage? {
        let semaphore = DispatchSemaphore(value: 0)
        let result = ScreenCaptureResultBox()

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            if let error {
                result.set(error: error)
                semaphore.signal()
                return
            }

            guard
                let display = content?.displays
                    .filter({ $0.frame.intersects(rect) })
                    .max(by: { lhs, rhs in
                        lhs.frame.intersection(rect).area < rhs.frame.intersection(rect).area
                    })
            else {
                semaphore.signal()
                return
            }

            let sourceRect = rect.intersection(display.frame)
            guard sourceRect.width >= 1, sourceRect.height >= 1 else {
                semaphore.signal()
                return
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = sourceRect
            configuration.width = Int(sourceRect.width.rounded(.up))
            configuration.height = Int(sourceRect.height.rounded(.up))
            configuration.showsCursor = false
            configuration.queueDepth = 1
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            if #available(macOS 14.0, *) {
                configuration.ignoreShadowsDisplay = true
                configuration.shouldBeOpaque = true
                configuration.captureResolution = .best
            }

            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                result.set(image: image, error: error)
                semaphore.signal()
            }
        }

        _ = semaphore.wait(timeout: .now() + 2.5)
        if result.hasError {
            return nil
        }
        return result.image
    }

    private func recognizedLines(
        from observations: [VNRecognizedTextObservation],
        captureRect: CGRect
    ) -> [ContextLine] {
        var seen = Set<String>()

        return observations.compactMap { observation -> ContextLine? in
            guard let candidate = observation.topCandidates(1).first else {
                return nil
            }

            let text = normalize(candidate.string)
            guard text.count >= 2 else {
                return nil
            }
            guard seen.insert(text.lowercased()).inserted else {
                return nil
            }

            return ContextLine(
                text: text,
                frame: frame(for: observation.boundingBox, in: captureRect)
            )
        }
        .sorted { lhs, rhs in
            guard let left = lhs.frame, let right = rhs.frame else {
                return lhs.text < rhs.text
            }
            if abs(left.minY - right.minY) > 8 {
                return left.minY < right.minY
            }
            return left.minX < right.minX
        }
    }

    private func frame(for boundingBox: CGRect, in captureRect: CGRect) -> CGRect {
        CGRect(
            x: captureRect.minX + boundingBox.minX * captureRect.width,
            y: captureRect.minY + (1 - boundingBox.maxY) * captureRect.height,
            width: boundingBox.width * captureRect.width,
            height: boundingBox.height * captureRect.height
        )
    }

    private func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else {
            return 0
        }
        return width * height
    }
}

private final class ScreenCaptureResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedImage: CGImage?
    private var storedError: Error?

    var image: CGImage? {
        lock.withLock {
            storedImage
        }
    }

    var hasError: Bool {
        lock.withLock {
            storedError != nil
        }
    }

    func set(image: CGImage? = nil, error: Error? = nil) {
        lock.withLock {
            storedImage = image
            storedError = error
        }
    }
}
