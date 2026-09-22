import Foundation

/// A small, pure traversal guard shared by AX readers and usable in regression tests. AX trees
/// are untrusted application data: depth, node count, and elapsed time are independent limits.
public struct AXTraversalBudget: Equatable, Sendable {
    public let maxDepth: Int
    public let maxNodes: Int
    public let maxMilliseconds: UInt64

    public init(maxDepth: Int = 10, maxNodes: Int = 500, maxMilliseconds: UInt64 = 750) {
        self.maxDepth = max(0, maxDepth)
        self.maxNodes = max(1, maxNodes)
        self.maxMilliseconds = max(1, maxMilliseconds)
    }

    public func allows(depth: Int, visitedNodes: Int, elapsedMilliseconds: UInt64) -> Bool {
        depth <= maxDepth
            && visitedNodes < maxNodes
            && elapsedMilliseconds < maxMilliseconds
    }
}
