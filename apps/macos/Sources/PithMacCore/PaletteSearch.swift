import Foundation
import PithCore

@MainActor
public final class PaletteSearch: ObservableObject {
    @Published public private(set) var query: String = ""
    @Published public private(set) var hits: [FfiSearchHit] = []
    @Published public var scope: PaletteScope = .everything
    public private(set) var pageHits: [FfiSearchHit] = []
    public private(set) var blockHits: [FfiSearchHit] = []

    public init() {}

    func show(_ query: String, hits: [FfiSearchHit]) {
        if self.query != query {
            self.query = query
        }
        if self.hits != hits {
            pageHits = hits.filter { if case .page = $0 { return true } else { return false } }
            blockHits = hits.filter { if case .block = $0 { return true } else { return false } }
            self.hits = hits
        }
    }
}
