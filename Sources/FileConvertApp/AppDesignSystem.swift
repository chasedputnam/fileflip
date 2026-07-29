import AppKit
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
    static let popoverSurface = adaptive(
        light: NSColor(srgbRed: 1.0, green: 0.992, blue: 0.973, alpha: 1),
        dark: NSColor(srgbRed: 0.075, green: 0.102, blue: 0.094, alpha: 1)
    )
    static let primaryInk = adaptive(
        light: NSColor(srgbRed: 0.098, green: 0.208, blue: 0.180, alpha: 1),
        dark: NSColor(srgbRed: 0.945, green: 0.949, blue: 0.925, alpha: 1)
    )
    static let secondaryInk = adaptive(
        light: NSColor(srgbRed: 0.337, green: 0.439, blue: 0.412, alpha: 1),
        dark: NSColor(srgbRed: 0.672, green: 0.716, blue: 0.694, alpha: 1)
    )
    static let success = adaptive(
        light: NSColor(srgbRed: 0.141, green: 0.345, blue: 0.282, alpha: 1),
        dark: NSColor(srgbRed: 0.510, green: 0.820, blue: 0.686, alpha: 1)
    )
    static let successFill = adaptive(
        light: NSColor(srgbRed: 0.851, green: 0.933, blue: 0.894, alpha: 1),
        dark: NSColor(srgbRed: 0.090, green: 0.239, blue: 0.192, alpha: 1)
    )
    static let progress = Color.blue
    static let progressFill = adaptive(
        light: NSColor(srgbRed: 0.855, green: 0.914, blue: 0.980, alpha: 1),
        dark: NSColor(srgbRed: 0.090, green: 0.184, blue: 0.310, alpha: 1)
    )
    static let warning = adaptive(
        light: NSColor(srgbRed: 0.788, green: 0.365, blue: 0.239, alpha: 1),
        dark: NSColor(srgbRed: 1.0, green: 0.596, blue: 0.443, alpha: 1)
    )
    static let warningFill = adaptive(
        light: NSColor(srgbRed: 1.0, green: 0.882, blue: 0.835, alpha: 1),
        dark: NSColor(srgbRed: 0.310, green: 0.137, blue: 0.094, alpha: 1)
    )
    static let critical = Color.red
    static let criticalFill = adaptive(
        light: NSColor(srgbRed: 1.0, green: 0.863, blue: 0.851, alpha: 1),
        dark: NSColor(srgbRed: 0.314, green: 0.102, blue: 0.106, alpha: 1)
    )
    static let divider = adaptive(
        light: NSColor(srgbRed: 0.753, green: 0.792, blue: 0.769, alpha: 0.55),
        dark: NSColor(white: 1, alpha: 0.15)
    )
    static let controlFill = adaptive(
        light: NSColor(srgbRed: 0.925, green: 0.933, blue: 0.918, alpha: 1),
        dark: NSColor(white: 1, alpha: 0.09)
    )

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

enum AppMotion {
    static let stateChange = Animation.easeOut(duration: 0.2)
}
struct AppIconTile: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let systemImage: String
    let foreground: Color
    let fill: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: 34, height: 34)
            .background(
                colorSchemeContrast == .increased ? Color.clear : fill,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                if colorSchemeContrast == .increased {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(foreground, lineWidth: 1.5)
                }
            }
            .accessibilityHidden(true)
    }
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
        AppIconTile(
            systemImage: state.systemImage,
            foreground: state.tint,
            fill: state.iconFill
        )
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

    var iconFill: Color {
        switch self {
        case .idle, .monitoring: AppColor.successFill
        case .converting: AppColor.progressFill
        case .paused, .needsChoice: AppColor.warningFill
        case .conversionFailed, .degraded, .blocked, .needsRecovery: AppColor.criticalFill
        }
    }
}
