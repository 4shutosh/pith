import Foundation
import PithCore

public struct RevealRequest: Equatable {
    public let blockId: String
    public let seq: UInt64
}

@MainActor
public final class FindState: ObservableObject {
    @Published public internal(set) var isOpen: Bool = false
    @Published public internal(set) var query: String = ""
    @Published public internal(set) var matches: [FfiPageMatch] = [] {
        didSet { index() }
    }
    @Published public internal(set) var activeIndex: Int = 0
    @Published public private(set) var revealRequest: RevealRequest?

    private var byBlock: [String: [FfiPageMatch]] = [:]
    private var firstIndexByBlock: [String: Int] = [:]

    public init() {}

    public var activeMatch: FfiPageMatch? {
        guard isOpen, matches.indices.contains(activeIndex) else { return nil }
        return matches[activeIndex]
    }

    public func matches(in blockId: String) -> [FfiPageMatch] {
        guard isOpen else { return [] }
        return byBlock[blockId] ?? []
    }

    public func activeOrdinal(in blockId: String) -> Int? {
        guard let active = activeMatch, active.blockId == blockId,
              let first = firstIndexByBlock[blockId] else { return nil }
        return activeIndex - first
    }

    func reveal(_ blockId: String) {
        revealRequest = RevealRequest(blockId: blockId, seq: (revealRequest?.seq ?? 0) &+ 1)
    }

    private func index() {
        byBlock = [:]
        firstIndexByBlock = [:]
        for (position, match) in matches.enumerated() {
            byBlock[match.blockId, default: []].append(match)
            if firstIndexByBlock[match.blockId] == nil {
                firstIndexByBlock[match.blockId] = position
            }
        }
    }
}
