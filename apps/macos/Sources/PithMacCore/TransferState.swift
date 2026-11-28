import Foundation
import PithCore

public enum TransferKind: Equatable, Sendable {
    case importLogseq
    case exportMarkdown

    public var runningTitle: String {
        switch self {
        case .importLogseq: return "Importing Logseq graph…"
        case .exportMarkdown: return "Exporting Markdown…"
        }
    }

    public var finishedTitle: String {
        switch self {
        case .importLogseq: return "Import complete"
        case .exportMarkdown: return "Export complete"
        }
    }

    public var failedTitle: String {
        switch self {
        case .importLogseq: return "Import failed"
        case .exportMarkdown: return "Export failed"
        }
    }
}

public struct TransferSummary: Equatable, Sendable {
    public let kind: TransferKind
    public let headline: String
    public let details: String

    public init(kind: TransferKind, headline: String, details: String) {
        self.kind = kind
        self.headline = headline
        self.details = details
    }
}

public enum TransferPhase: Equatable, Sendable {
    case idle
    case running(kind: TransferKind, done: Int, total: Int, cancelling: Bool)
    case finished(TransferSummary)
    case cancelled(kind: TransferKind)
    case failed(kind: TransferKind, message: String)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

public final class ProgressBridge: FfiProgressCallback, @unchecked Sendable {
    private let cancelFlag: CancelFlag
    private let onUpdate: @Sendable (Int, Int) -> Void

    public init(cancelFlag: CancelFlag, onUpdate: @escaping @Sendable (Int, Int) -> Void) {
        self.cancelFlag = cancelFlag
        self.onUpdate = onUpdate
    }

    public func onProgress(done: UInt64, total: UInt64) -> Bool {
        onUpdate(Int(done), Int(total))
        return !cancelFlag.isCancelled
    }
}

@MainActor
public final class TransferState: ObservableObject {
    @Published public private(set) var phase: TransferPhase = .idle
    @Published public var showReportDetails = false

    private var cancelFlag: CancelFlag?

    public init() {}

    public var isRunning: Bool {
        phase.isRunning
    }

    public func begin(_ kind: TransferKind) -> CancelFlag {
        let flag = CancelFlag()
        cancelFlag = flag
        showReportDetails = false
        phase = .running(kind: kind, done: 0, total: 0, cancelling: false)
        return flag
    }

    public func updateProgress(kind: TransferKind, done: Int, total: Int) {
        guard case let .running(currentKind, _, _, cancelling) = phase, currentKind == kind else { return }
        phase = .running(kind: kind, done: done, total: total, cancelling: cancelling)
    }

    public func requestCancel() {
        cancelFlag?.cancel()
        if case let .running(kind, done, total, _) = phase {
            phase = .running(kind: kind, done: done, total: total, cancelling: true)
        }
    }

    public func finish(_ summary: TransferSummary) {
        cancelFlag = nil
        phase = .finished(summary)
    }

    public func markCancelled(_ kind: TransferKind) {
        cancelFlag = nil
        phase = .cancelled(kind: kind)
    }

    public func fail(_ kind: TransferKind, message: String) {
        cancelFlag = nil
        phase = .failed(kind: kind, message: message)
    }

    public func dismiss() {
        guard !isRunning else { return }
        showReportDetails = false
        phase = .idle
    }

    public static func summarizeImport(_ report: FfiImportReport) -> TransferSummary {
        let headline = "Imported \(report.pagesImported) pages, \(report.journalsImported) journals, \(report.blocksImported) blocks"
        var lines: [String] = [
            "Logseq schema: \(report.schemaMajor).\(report.schemaMinor)",
            "Pages imported: \(report.pagesImported) (\(report.pagesAlreadyPresent) already present)",
            "Journals imported: \(report.journalsImported)",
            "Blocks imported: \(report.blocksImported) (\(report.blocksAlreadyPresent) already present)",
            "Collapsed: \(report.collapsedApplied), Favorites: \(report.favoritesApplied), Txns: \(report.txnsWritten)",
        ]
        let s = report.skipped
        let skippedTotal = s.builtInOrHidden + s.recycledOrDeleted + s.views + s.assets
            + s.whiteboards + s.properties + s.history + s.files + s.kv + s.other
        lines.append("Skipped: \(skippedTotal) (built-in=\(s.builtInOrHidden), deleted=\(s.recycledOrDeleted), views=\(s.views), assets=\(s.assets), props=\(s.properties), history=\(s.history))")
        lines.append("Unresolved refs: \(report.unresolvedRefs.count)")
        for ref in report.unresolvedRefs.prefix(10) {
            lines.append("  [\(ref.kind)] \(ref.sourceBlock) -> \(ref.target)")
        }
        if !report.downgraded.isEmpty {
            lines.append("Downgraded:")
            for item in report.downgraded {
                lines.append("  \(item.kind): \(item.count)")
                for sample in item.samples.prefix(5) {
                    lines.append("    - \(sample)")
                }
            }
        }
        return TransferSummary(kind: .importLogseq, headline: headline, details: lines.joined(separator: "\n"))
    }

    public static func summarizeExport(_ report: FfiExportReport, outDir: String) -> TransferSummary {
        let headline = "Exported \(report.pagesExported) pages, \(report.journalsExported) journals (\(report.blocksExported) blocks)"
        let details = [
            "Destination: \(outDir)",
            "Pages exported: \(report.pagesExported)",
            "Journals exported: \(report.journalsExported)",
            "Blocks exported: \(report.blocksExported)",
            "Files written: \(report.filesWritten)",
        ].joined(separator: "\n")
        return TransferSummary(kind: .exportMarkdown, headline: headline, details: details)
    }
}
