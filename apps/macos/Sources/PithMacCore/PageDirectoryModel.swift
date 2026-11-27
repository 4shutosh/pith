import Foundation
import PithCore

@MainActor
public final class PageDirectoryModel: ObservableObject {
    @Published public private(set) var summaries: [FfiPageSummary] = []
    @Published public private(set) var isLoaded: Bool = false

    public init() {}

    func show(_ summaries: [FfiPageSummary]) {
        if self.summaries != summaries {
            self.summaries = summaries
        }
        if !isLoaded {
            isLoaded = true
        }
    }
}
