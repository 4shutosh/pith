import PithMacCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @Binding var themeMode: ThemeMode
    let todayTitle: String
    let contentLeading: CGFloat
    let contentWidth: CGFloat
    @Namespace private var themeNamespace
    @Namespace private var surfaceNamespace
    @Namespace private var dateNamespace
    @Namespace private var accentNamespace

    private var hasNonDefaultSettings: Bool {
        themeMode != .system || settings.accent != .amber || settings.surface != .warm || settings.dateFormat != .iso || !settings.showLinkBrackets
    }

    var body: some View {
        ScrollView {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    appearanceCard
                    datesCard
                    editorCard
                }
                .frame(width: contentWidth, alignment: .leading)
                .padding(.leading, contentLeading)
                .padding(.top, 58)
                .padding(.bottom, 120)
                Spacer(minLength: 0)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Settings")
                    .font(Typography.ui(TypeScale.pageTitle, .semibold))
                    .tracking(-0.4)
                    .foregroundColor(Theme.textStrong)
                Text("Appearance, date format, and editor preferences")
                    .font(Typography.ui(TypeScale.ui))
                    .foregroundColor(Theme.textTertiary)
            }
            Spacer(minLength: 0)
            if hasNonDefaultSettings {
                Button {
                    withAnimation(Motion.fast) {
                        themeMode = .system
                        settings.resetToDefaults()
                    }
                } label: {
                    Text("Reset defaults")
                        .font(Typography.ui(TypeScale.meta, .medium))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hover))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.divider, lineWidth: 1))
                }
                .buttonStyle(PressButtonStyle(scale: 0.97))
                .cursor(.pointingHand)
                .transition(.opacity)
            }
        }
    }

    private var appearanceCard: some View {
        SettingsCard(title: "Appearance") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Theme")
                            .font(Typography.ui(TypeScale.listRow, .medium))
                            .foregroundColor(Theme.textPrimary)
                        Text("Match macOS or lock to light or dark")
                            .font(Typography.ui(TypeScale.meta))
                            .foregroundColor(Theme.textTertiary)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 2) {
                        ForEach(ThemeMode.allCases, id: \.self) { mode in
                            SegmentedPill(
                                title: mode.label,
                                isSelected: themeMode == mode,
                                namespace: themeNamespace,
                                id: "themeMode"
                            ) {
                                withAnimation(Motion.morph) { themeMode = mode }
                            }
                        }
                    }
                    .padding(3)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.canvas))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.divider, lineWidth: 1))
                }

                Rectangle().fill(Theme.divider).frame(height: 1)

                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Surface")
                            .font(Typography.ui(TypeScale.listRow, .medium))
                            .foregroundColor(Theme.textPrimary)
                        Text("Warm editorial paper & charcoal, or true black & white")
                            .font(Typography.ui(TypeScale.meta))
                            .foregroundColor(Theme.textTertiary)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 2) {
                        ForEach(SurfaceStyle.allCases) { style in
                            SegmentedPill(
                                title: style.label,
                                isSelected: settings.surface == style,
                                namespace: surfaceNamespace,
                                id: "surfaceStyle"
                            ) {
                                withAnimation(Motion.morph) { settings.surface = style }
                            }
                        }
                    }
                    .padding(3)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.canvas))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.divider, lineWidth: 1))
                }

                Rectangle().fill(Theme.divider).frame(height: 1)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("Accent")
                                    .font(Typography.ui(TypeScale.listRow, .medium))
                                    .foregroundColor(Theme.textPrimary)
                                Text(settings.accent.label)
                                    .font(Typography.ui(TypeScale.meta))
                                    .foregroundColor(Theme.textTertiary)
                            }
                            Text("Links, active highlights, and caret")
                                .font(Typography.ui(TypeScale.meta))
                                .foregroundColor(Theme.textTertiary)
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: 4) {
                            ForEach(AccentPalette.allCases) { palette in
                                AccentDotButton(
                                    palette: palette,
                                    isSelected: settings.accent == palette,
                                    namespace: accentNamespace
                                ) {
                                    withAnimation(Motion.morph) {
                                        settings.accent = palette
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                        .frame(height: 32)
                        .background(Capsule().fill(Theme.canvas))
                        .overlay(Capsule().stroke(Theme.divider, lineWidth: 1))
                    }

                    AccentLivePreview(
                        palette: settings.accent,
                        showBrackets: settings.showLinkBrackets
                    )
                }
            }
        }
    }

    private var datesCard: some View {
        SettingsCard(title: "Dates & Journals") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Journal date format")
                            .font(Typography.ui(TypeScale.listRow, .medium))
                            .foregroundColor(Theme.textPrimary)
                        Text("Display format for daily notes; stored canonically as YYYY-MM-DD")
                            .font(Typography.ui(TypeScale.meta))
                            .foregroundColor(Theme.textTertiary)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 2) {
                        ForEach(JournalDateFormat.allCases) { format in
                            SegmentedPill(
                                title: format.label,
                                isSelected: settings.dateFormat == format,
                                namespace: dateNamespace,
                                id: "dateFormat"
                            ) {
                                withAnimation(Motion.morph) { settings.dateFormat = format }
                            }
                        }
                    }
                    .padding(3)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.canvas))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.divider, lineWidth: 1))
                }

                HStack(spacing: 8) {
                    Text("Preview")
                        .font(Typography.ui(TypeScale.label, .medium))
                        .foregroundColor(Theme.textTertiary)
                    Text(settings.formatJournalTitle(todayTitle))
                        .font(Typography.ui(TypeScale.ui, .semibold))
                        .foregroundColor(Theme.textStrong)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.canvas))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.divider, lineWidth: 1))
            }
        }
    }

    private var editorCard: some View {
        SettingsCard(title: "Editor") {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show [[ ]] brackets around page links")
                        .font(Typography.ui(TypeScale.listRow, .medium))
                        .foregroundColor(Theme.textPrimary)
                    HStack(spacing: 6) {
                        Text("Outside editing:")
                            .foregroundColor(Theme.textTertiary)
                        if settings.showLinkBrackets {
                            HStack(spacing: 0) {
                                Text("[[").foregroundColor(Theme.bullet)
                                Text("Roadmap").foregroundColor(Theme.link)
                                Text("]]").foregroundColor(Theme.bullet)
                            }
                        } else {
                            Text("Roadmap").foregroundColor(Theme.link)
                        }
                    }
                    .font(Typography.ui(TypeScale.meta))
                }
                Spacer(minLength: 0)
                Toggle("", isOn: $settings.showLinkBrackets)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.accent)
                    .cursor(.pointingHand)
            }
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(Typography.ui(TypeScale.ui, .semibold))
                .foregroundColor(Theme.textStrong)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Rectangle().fill(Theme.divider).frame(height: 1)

            content()
                .padding(16)
        }
        .background(Theme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider, lineWidth: 1))
    }
}

private struct SegmentedPill: View {
    let title: String
    let isSelected: Bool
    let namespace: Namespace.ID
    let id: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.ui(TypeScale.meta, isSelected ? .medium : .regular))
                .foregroundColor(isSelected ? Theme.textStrong : (isHovered ? Theme.textPrimary : Theme.textSecondary))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Theme.selected)
                            .matchedGeometryEffect(id: id, in: namespace)
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Theme.hover)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .animation(Motion.hover, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

private struct AccentDotButton: View {
    let palette: AccentPalette
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var isHovered = false

    private var swatch: Color {
        Theme.accent(for: palette)
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if isSelected {
                    Circle()
                        .stroke(swatch, lineWidth: 1.5)
                        .frame(width: 22, height: 22)
                        .matchedGeometryEffect(id: "accentDotRing", in: namespace)
                }
                if palette == .monochrome {
                    ZStack {
                        Circle().fill(Theme.textStrong)
                        Circle()
                            .trim(from: 0, to: 0.5)
                            .fill(Theme.canvas)
                            .rotationEffect(.degrees(-45))
                        Circle().stroke(Theme.elevatedBorder, lineWidth: 1)
                    }
                    .frame(width: 14, height: 14)
                    .scaleEffect(isHovered ? 1.14 : 1)
                } else {
                    Circle()
                        .fill(swatch)
                        .frame(width: 14, height: 14)
                        .scaleEffect(isHovered ? 1.14 : 1)
                }
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .buttonStyle(PressButtonStyle(scale: 0.90))
        .cursor(.pointingHand)
        .animation(Motion.hover, value: isHovered)
        .onHover { isHovered = $0 }
        .help(palette.label)
        .accessibilityLabel(palette.label)
    }
}

private struct AccentLivePreview: View {
    let palette: AccentPalette
    let showBrackets: Bool

    private var accentColor: Color { Theme.accent(for: palette) }
    private var linkColor: Color { Theme.link(for: palette) }

    var body: some View {
        HStack(spacing: 8) {
            TaskMark(status: .doing)
                .foregroundColor(accentColor)

            HStack(spacing: 0) {
                Text("Review ")
                    .foregroundColor(Theme.textSecondary)
                if showBrackets {
                    Text("[[")
                        .foregroundColor(Theme.bullet)
                }
                Text("Roadmap")
                    .foregroundColor(linkColor)
                if showBrackets {
                    Text("]]")
                        .foregroundColor(Theme.bullet)
                }
                Text(" and ")
                    .foregroundColor(Theme.textSecondary)
                Text("ship v1")
                    .foregroundColor(Theme.textStrong)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(accentColor.opacity(0.22)))
            }
            .font(Typography.ui(TypeScale.ui))

            RoundedRectangle(cornerRadius: 1)
                .fill(accentColor)
                .frame(width: 1.5, height: 14)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.divider, lineWidth: 1))
        .animation(Motion.fast, value: palette)
    }
}
