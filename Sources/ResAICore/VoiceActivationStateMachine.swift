import Foundation

public struct VoiceActivationStateMachine: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case holding(since: TimeInterval)
        case toggled
        case finishing
    }

    public enum Event: Equatable, Sendable {
        case keyDown(at: TimeInterval)
        case keyUp(at: TimeInterval)
        case finished
    }

    public enum Action: Equatable, Sendable {
        case startListening
        case confirm
        case none
    }

    public var tapThreshold: TimeInterval = 0.25
    public private(set) var state: State = .idle

    public init() {}

    public mutating func handle(_ event: Event) -> Action {
        switch (state, event) {
        case (.idle, .keyDown(let at)):
            state = .holding(since: at)
            return .startListening

        case (.idle, .keyUp), (.idle, .finished):
            return .none

        case (.holding(let since), .keyUp(let at)):
            if at - since >= tapThreshold {
                state = .finishing
                return .confirm
            }
            state = .toggled
            return .none

        case (.holding, .keyDown):
            // Second press without a qualifying keyUp: menu toggle, or `.toggleOnly`
            // where keyUp is ignored and the machine stays in `.holding`.
            state = .finishing
            return .confirm

        case (.holding, .finished):
            state = .idle
            return .none

        case (.toggled, .keyDown):
            state = .finishing
            return .confirm

        case (.toggled, .keyUp):
            return .none

        case (.toggled, .finished):
            state = .idle
            return .none

        case (.finishing, .finished):
            state = .idle
            return .none

        case (.finishing, _):
            return .none
        }
    }

    /// Applies `activationMode`: `.toggleOnly` ignores `keyUp` entirely (press = start, press again = confirm).
    public mutating func handle(_ event: Event, mode: VoiceActivationMode) -> Action {
        if mode.ignoresKeyUp, case .keyUp = event {
            return .none
        }
        return handle(event)
    }
}
