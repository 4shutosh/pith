import PithMacCore
import SwiftUI

struct TransferBanner: View {
    @ObservedObject var transfer: TransferState
    let onCancel: () -> Void

    var body: some View {
        switch transfer.phase {
        case .idle:
            EmptyView()
        case let .running(kind, done, total, cancelling):
            Card(title: nil, contentPadding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(cancelling ? "Cancelling…" : kind.runningTitle)
                                .font(Typography.ui(TypeScale.ui, .medium))
                                .foregroundColor(Theme.textStrong)
                            Text(progressLabel(done: done, total: total))
                                .font(Typography.ui(TypeScale.meta))
                                .foregroundColor(Theme.textTertiary)
                        }
                        Spacer(minLength: 8)
                        if !cancelling {
                            SecondaryButton(title: "Cancel", action: onCancel)
                        }
                    }
                    progressBar(done: done, total: total)
                }
            }
            .frame(width: 320)
            .shadow(color: Theme.shadow, radius: 16, y: 6)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        case let .finished(summary):
            Card(title: nil, contentPadding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(summary.kind.finishedTitle)
                                .font(Typography.ui(TypeScale.ui, .semibold))
                                .foregroundColor(Theme.textStrong)
                            Text(summary.headline)
                                .font(Typography.ui(TypeScale.meta))
                                .foregroundColor(Theme.textSecondary)
                        }
                        Spacer(minLength: 8)
                        HStack(spacing: 8) {
                            SecondaryButton(title: transfer.showReportDetails ? "Hide" : "Report") {
                                withAnimation(Motion.fast) {
                                    transfer.showReportDetails.toggle()
                                }
                            }
                            SecondaryButton(title: "Done") {
                                withAnimation(Motion.fast) {
                                    transfer.dismiss()
                                }
                            }
                        }
                    }
                    if transfer.showReportDetails {
                        Rectangle().fill(Theme.divider).frame(height: 1)
                        ScrollView {
                            Text(summary.details)
                                .font(Typography.ui(TypeScale.meta))
                                .foregroundColor(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 200)
                    }
                }
            }
            .frame(width: transfer.showReportDetails ? 420 : 360)
            .shadow(color: Theme.shadow, radius: 16, y: 6)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        case let .cancelled(kind):
            Card(title: nil, contentPadding: 12) {
                HStack(spacing: 12) {
                    Text("\(kind == .importLogseq ? "Import" : "Export") cancelled")
                        .font(Typography.ui(TypeScale.ui, .medium))
                        .foregroundColor(Theme.textSecondary)
                    Spacer(minLength: 8)
                    SecondaryButton(title: "Dismiss") {
                        withAnimation(Motion.fast) { transfer.dismiss() }
                    }
                }
            }
            .frame(width: 300)
            .shadow(color: Theme.shadow, radius: 16, y: 6)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        case let .failed(kind, message):
            Card(title: nil, contentPadding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Text(kind.failedTitle)
                            .font(Typography.ui(TypeScale.ui, .semibold))
                            .foregroundColor(Theme.danger)
                        Spacer(minLength: 8)
                        SecondaryButton(title: "Dismiss") {
                            withAnimation(Motion.fast) { transfer.dismiss() }
                        }
                    }
                    Text(message)
                        .font(Typography.ui(TypeScale.meta))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 360)
            .shadow(color: Theme.shadow, radius: 16, y: 6)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func progressLabel(done: Int, total: Int) -> String {
        if total > 0 {
            return "\(done) / \(total)"
        }
        return "Preparing…"
    }

    private func progressBar(done: Int, total: Int) -> some View {
        GeometryReader { geo in
            let fraction: CGFloat = total > 0 ? min(1, max(0, CGFloat(done) / CGFloat(total))) : 0.15
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.hover)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.accent)
                    .frame(width: geo.size.width * fraction)
                    .animation(Motion.fast, value: fraction)
            }
        }
        .frame(height: 4)
    }
}
