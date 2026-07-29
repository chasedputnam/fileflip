import SwiftUI

enum AppSpacing {
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let xLarge: CGFloat = 24
    static let xxLarge: CGFloat = 32
}

enum AppRadius {
    static let panel: CGFloat = 12
}

enum AppLayout {
    static let menuWidth: CGFloat = 360
    static let onboardingWidth: CGFloat = 560
    static let settingsMinimumWidth: CGFloat = 680
    static let settingsMinimumHeight: CGFloat = 500
    static let sliderWidth: CGFloat = 220
    static let historySidebarMinimumWidth: CGFloat = 260
    static let historySidebarIdealWidth: CGFloat = 300
    static let historyMinimumWidth: CGFloat = 760
    static let historyMinimumHeight: CGFloat = 480
    static let historyDefaultWidth: CGFloat = 820
    static let historyDefaultHeight: CGFloat = 520
    static let dialogWidth: CGFloat = 460
}

enum AppColor {
    static let success = Color.green
    static let progress = Color.blue
    static let warning = Color.orange
    static let critical = Color.red
}

enum AppMotion {
    static let stateChange = Animation.easeOut(duration: 0.2)
}

struct AppPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(AppSpacing.large)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: AppRadius.panel))
    }
}

struct AppEmptyState: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct AppStatusMark: View {
    let state: MenuBarState

    var body: some View {
        Label(state.title, systemImage: state.systemImage)
            .font(.headline)
            .foregroundStyle(state.tint)
            .accessibilityLabel("FileFlip status: \(state.accessibilityDescription)")
    }
}

extension MenuBarState {
    var tint: Color {
        switch self {
        case .idle, .monitoring: AppColor.success
        case .converting: AppColor.progress
        case .paused, .needsChoice: AppColor.warning
        case .conversionFailed, .degraded, .blocked, .needsRecovery: AppColor.critical
        }
    }
}
