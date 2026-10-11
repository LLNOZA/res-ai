import Foundation

/// Polls quickly while the user is likely in System Settings, then keeps checking
/// slowly instead of giving up, so a grant made minutes later still takes effect
/// without a relaunch.
public struct PermissionPollSchedule: Equatable, Sendable {
    public let fastAttempts: Int
    public let fastInterval: Duration
    public let slowInterval: Duration
    public let slowLogEvery: Int

    public init(fastAttempts: Int, fastInterval: Duration, slowInterval: Duration, slowLogEvery: Int) {
        self.fastAttempts = max(1, fastAttempts)
        self.fastInterval = fastInterval
        self.slowInterval = slowInterval
        self.slowLogEvery = max(1, slowLogEvery)
    }

    public static let standard = PermissionPollSchedule(
        fastAttempts: 120,
        fastInterval: .seconds(1),
        slowInterval: .seconds(30),
        slowLogEvery: 10
    )

    public func interval(afterAttempt attempt: Int) -> Duration {
        attempt < fastAttempts ? fastInterval : slowInterval
    }

    /// True on the attempt that ends the fast phase.
    public func isFastPhaseEnd(_ attempt: Int) -> Bool {
        attempt == fastAttempts
    }

    public func shouldLog(attempt: Int) -> Bool {
        if attempt == 1 {
            return true
        }
        if attempt <= fastAttempts {
            return attempt % 10 == 0
        }
        return (attempt - fastAttempts) % slowLogEvery == 0
    }
}
