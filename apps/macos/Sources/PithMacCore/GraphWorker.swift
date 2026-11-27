import Foundation
import PithCore

public final class GraphWorker: @unchecked Sendable {
    private let graph: PithGraph
    private let queue: DispatchQueue

    public init(graph: PithGraph, qos: DispatchQoS = .userInitiated) {
        self.graph = graph
        self.queue = DispatchQueue(label: "app.pith.graph-worker.\(qos.qosClass)", qos: qos)
    }

    public convenience init(path: String, qos: DispatchQoS = .userInitiated) throws {
        self.init(graph: try PithGraph.open(path: path), qos: qos)
    }

    public func run<Value: Sendable>(_ job: @escaping @Sendable (PithGraph) throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [graph] in
                continuation.resume(with: Result { try job(graph) })
            }
        }
    }
}
