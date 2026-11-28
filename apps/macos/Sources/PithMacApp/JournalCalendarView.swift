import PithCore
import PithMacCore
import SwiftUI

struct JournalCalendarView: View {
    @ObservedObject var controller: OutlinerController
    let history: JournalHistory
    let today: JournalDay
    @Binding var state: JournalCalendarState
    let width: CGFloat
    @ObservedObject private var settings = AppSettings.shared
    @State private var loaded: (pageId: String, preview: FfiLinkPreview)?
    @State private var hovered: JournalDay?

    private var layout: JournalCalendarLayout {
        JournalCalendarLayout(width: width)
    }

    private var selectedEntry: FfiJournalDay? {
        history.entry(state.selected)
    }

    private var preview: FfiLinkPreview? {
        guard let loaded, loaded.pageId == selectedEntry?.pageId else { return nil }
        return loaded.preview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            JournalStatsLine(stats: history.stats(today: today), compact: !layout.showsSidePreview)
            if layout.showsSidePreview {
                HStack(alignment: .top, spacing: JournalCalendarLayout.paneGap) {
                    monthColumn
                    dayPreview(compact: false)
                }
            } else {
                dayPreview(compact: true)
                monthColumn
            }
        }
        .task(id: selectedEntry?.pageId) {
            guard let pageId = selectedEntry?.pageId else { return }
            if let preview = await controller.journalPreview(pageId: pageId) {
                loaded = (pageId, preview)
            }
        }
    }

    private func dayPreview(compact: Bool) -> some View {
        JournalDayPreview(
            day: state.selected,
            today: today,
            entry: selectedEntry,
            preview: preview,
            title: settings.formatJournalTitle(state.selected.iso),
            compact: compact,
            onOpen: { controller.openJournal(date: state.selected.iso) }
        )
    }

    private var monthColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: JournalCalendarLayout.gap) {
                ForEach(Array(JournalMonth.weekdayInitials.enumerated()), id: \.offset) { _, initial in
                    Text(initial)
                        .font(Typography.ui(TypeScale.label, .medium))
                        .foregroundColor(Theme.textTertiary)
                        .frame(width: layout.cell)
                }
            }
            .padding(.bottom, 8)
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(history.months(today: today, selected: state.selected)) { month in
                            Section {
                                JournalMonthGrid(
                                    month: month,
                                    cell: layout.cell,
                                    history: history,
                                    today: today,
                                    selected: state.selected,
                                    onHover: { day in
                                        hovered = day
                                        state.selected = day
                                    },
                                    onOpen: { day in
                                        state.selected = day
                                        controller.openJournal(date: day.iso)
                                    }
                                )
                                .padding(.bottom, 10)
                            } header: {
                                JournalMonthHeader(month: month, written: history.writtenCount(in: month))
                            }
                            .id(month.id)
                        }
                    }
                    .padding(.bottom, 24)
                }
                .onAppear { proxy.scrollTo(state.selected.calendarMonth.id, anchor: .top) }
                .onChange(of: state.selected) { day in
                    guard day != hovered else { return }
                    hovered = nil
                    withAnimation(Motion.fast) { proxy.scrollTo(day.id) }
                }
            }
        }
        .frame(width: layout.gridWidth, alignment: .leading)
    }
}

private struct JournalStatsLine: View {
    let stats: JournalStats
    let compact: Bool

    var body: some View {
        Text(parts.joined(separator: "  ·  "))
            .font(Typography.ui(TypeScale.meta))
            .foregroundColor(Theme.textTertiary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var parts: [String] {
        guard stats.writtenDays > 0 else { return ["No journal entries yet"] }
        var out = ["\(stats.writtenDays) \(stats.writtenDays == 1 ? "day" : "days") written"]
        if let since = stats.since, !compact {
            out.append("since \(since.calendarMonth.title)")
        }
        if stats.currentStreak > 1 {
            out.append("\(stats.currentStreak)-day streak")
        }
        if stats.longestStreak > 1 {
            out.append("longest \(stats.longestStreak)")
        }
        return out
    }
}

private struct JournalMonthHeader: View {
    let month: JournalMonth
    let written: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(month.title)
                .font(Typography.ui(TypeScale.ui, .semibold))
                .foregroundColor(Theme.textStrong)
            Spacer(minLength: 8)
            if written > 0 {
                Text("\(written) \(written == 1 ? "day" : "days")")
                    .font(Typography.ui(TypeScale.label))
                    .foregroundColor(Theme.textTertiary)
                    .monospacedDigit()
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(Theme.canvas)
    }
}

private struct JournalMonthGrid: View {
    let month: JournalMonth
    let cell: CGFloat
    let history: JournalHistory
    let today: JournalDay
    let selected: JournalDay
    let onHover: (JournalDay) -> Void
    let onOpen: (JournalDay) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: JournalCalendarLayout.gap) {
            ForEach(Array(month.weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: JournalCalendarLayout.gap) {
                    ForEach(0..<7, id: \.self) { index in
                        if let day = week[index] {
                            JournalDayCell(
                                day: day,
                                size: cell,
                                ink: history.ink(day),
                                isToday: day == today,
                                isFuture: day > today,
                                isSelected: day == selected,
                                onHover: { onHover(day) },
                                onOpen: { onOpen(day) }
                            )
                            .id(day.id)
                        } else {
                            Color.clear.frame(width: cell, height: cell)
                        }
                    }
                }
            }
        }
    }
}

private struct JournalDayCell: View {
    let day: JournalDay
    let size: CGFloat
    let ink: JournalInk
    let isToday: Bool
    let isFuture: Bool
    let isSelected: Bool
    let onHover: () -> Void
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            Text("\(day.day)")
                .font(Typography.ui(TypeScale.meta, isToday || ink > .none ? .semibold : .regular))
                .monospacedDigit()
                .foregroundColor(numberColor)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.journalInk(ink)))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(isSelected ? Theme.textStrong : Color.clear, lineWidth: 1.5)
                )
                .overlay(alignment: .bottom) {
                    if isToday {
                        Capsule()
                            .fill(Theme.accent)
                            .frame(width: 10, height: 2)
                            .padding(.bottom, 5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .onHover { inside in
            if inside { onHover() }
        }
        .help(ink == .none ? "Start \(day.iso)" : "Open \(day.iso)")
    }

    private var numberColor: Color {
        if isToday { return Theme.textStrong }
        if ink > .none { return Theme.textStrong }
        return isFuture ? Theme.bullet : Theme.textTertiary
    }
}

private struct JournalDayPreview: View {
    let day: JournalDay
    let today: JournalDay
    let entry: FfiJournalDay?
    let preview: FfiLinkPreview?
    let title: String
    let compact: Bool
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel(title: day.weekdayName)
                    Spacer(minLength: 8)
                    Text(JournalRelative.label(day, today: today))
                        .font(Typography.ui(TypeScale.label))
                        .foregroundColor(day == today ? Theme.accent : Theme.textTertiary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title)
                        .font(Typography.ui(compact ? TypeScale.searchInput : TypeScale.sectionTitle, .semibold))
                        .tracking(-0.3)
                        .foregroundColor(Theme.textStrong)
                        .lineLimit(1)
                    if compact {
                        Text(meta)
                            .font(Typography.ui(TypeScale.meta))
                            .foregroundColor(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                if !compact {
                    Text(meta)
                        .font(Typography.ui(TypeScale.meta))
                        .foregroundColor(Theme.textTertiary)
                }
            }
            Rectangle().fill(Theme.divider).frame(height: 1)
            content
            HStack(spacing: 14) {
                KeyHint(keys: "↵", label: entry == nil ? "Start writing" : "Open")
                if !compact {
                    KeyHint(keys: "⌥←→", label: "Written days")
                    KeyHint(keys: "T", label: "Today")
                }
            }
        }
        .padding(compact ? 14 : 20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.elevatedBorder, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
    }

    private var meta: String {
        guard let entry else { return "Nothing written" }
        return "\(entry.blockCount) \(entry.blockCount == 1 ? "block" : "blocks")"
    }

    @ViewBuilder
    private var content: some View {
        if entry == nil {
            PreviewNote(text: emptyNote)
                .fixedSize(horizontal: false, vertical: true)
        } else if let preview {
            let lines = compact ? Array(preview.lines.prefix(3)) : preview.lines
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    OutlineLine(depth: line.depth, spans: line.spans, isTarget: false)
                        .lineLimit(compact ? 1 : nil)
                }
            }
            .padding(.horizontal, -6)
            if preview.totalBlocks > UInt64(lines.count) {
                PreviewNote(text: "+\(preview.totalBlocks - UInt64(lines.count)) more")
            }
        } else {
            Color.clear.frame(height: compact ? 20 : 60)
        }
    }

    private var emptyNote: String {
        if day == today { return "Nothing yet today. The page is created when you write." }
        if day > today { return "This day hasn't come yet. You can still plan it." }
        return "Nothing was written this day. The page is created only when you write."
    }
}
