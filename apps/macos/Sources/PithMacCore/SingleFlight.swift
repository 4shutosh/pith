import Foundation

@MainActor
public final class SingleFlight<Input> {
    private let perform: (Input) async -> Void
    private var pending: Input?
    private var running: Task<Void, Never>?

    public init(_ perform: @escaping (Input) async -> Void) {
        self.perform = perform
    }

    public var hasPending: Bool {
        pending != nil
    }

    @discardableResult
    public func submit(_ input: Input) -> Task<Void, Never> {
        pending = input
        if let running {
            return running
        }
        let task = Task {
            while let next = pending {
                pending = nil
                await perform(next)
            }
            running = nil
        }
        running = task
        return task
    }

    public func settled() async {
        await running?.value
    }
}
