import Foundation
import PithCore

@MainActor
public final class PaletteSearch: ObservableObject {
    @Published public private(set) var query: String = ""
    @Published public private(set) var hits: [FfiSearchHit] = []
    @Published public var scope: PaletteScope = .everything
    @Published public var input: String = ""

    public init() {}

    func show(_ query: String, hits: [FfiSearchHit]) {
        if self.query != query {
            self.query = query
        }
        if self.hits != hits {
            self.hits = hits
        }
    }
}
