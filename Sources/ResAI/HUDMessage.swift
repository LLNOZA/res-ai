import CoreGraphics
import Foundation

struct HUDMessage: Equatable {
    enum Tone: Equatable {
        case idle
        case loading
        case success
        case warning
        case error
    }

    var title: String
    var detail: String?
    var preview: String?
    var tone: Tone
    var inputFrame: CGRect?
    var duration: TimeInterval?

    init(
        title: String,
        detail: String? = nil,
        preview: String? = nil,
        tone: Tone = .idle,
        inputFrame: CGRect? = nil,
        duration: TimeInterval? = 1.6
    ) {
        self.title = title
        self.detail = detail
        self.preview = preview
        self.tone = tone
        self.inputFrame = inputFrame
        self.duration = duration
    }
}
