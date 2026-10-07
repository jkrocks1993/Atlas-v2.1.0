import SwiftUI

enum Theme {
    static let ink = Color(red: 0.05, green: 0.055, blue: 0.07)
    static let inkSoft = Color(red: 0.10, green: 0.11, blue: 0.14)
    static let raised = Color(red: 0.14, green: 0.15, blue: 0.19)
    static let raised2 = Color(red: 0.20, green: 0.21, blue: 0.26)
    static let paper = Color(red: 0.07, green: 0.075, blue: 0.09)
    static let paperDeep = Color(red: 0.04, green: 0.045, blue: 0.055)
    static let line = Color(red: 0.42, green: 0.36, blue: 0.24)
    static let matteBlue = Color(red: 0.28, green: 0.58, blue: 0.92)
    static let matteBluePressed = Color(red: 0.18, green: 0.44, blue: 0.74)
    static let matteRed = Color(red: 0.90, green: 0.32, blue: 0.30)
    static let matteRedPressed = Color(red: 0.70, green: 0.20, blue: 0.20)
    static let copper = Color(red: 0.93, green: 0.74, blue: 0.32)
    static let progressGreen = Color(red: 0.22, green: 0.86, blue: 0.62)
    static let progressTrack = Color(red: 0.16, green: 0.17, blue: 0.21)
    static let separator = Color(red: 0.28, green: 0.26, blue: 0.20)
    static let cardFill = Color(red: 0.12, green: 0.125, blue: 0.16)
    static let muted = Color(red: 0.78, green: 0.76, blue: 0.70)
    static let bestGold = Color(red: 0.98, green: 0.82, blue: 0.38)
    static let selection = Color(red: 0.28, green: 0.58, blue: 0.92).opacity(0.32)
    static let chrome = paper
    static let text = Color(red: 0.96, green: 0.95, blue: 0.92)
    static let textDim = Color(red: 0.72, green: 0.71, blue: 0.66)

    static let controlHeight: CGFloat = 30
    static let progressHeight: CGFloat = 28
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(1.6)
            .foregroundColor(Theme.copper)
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [Theme.copper.opacity(0.05), Theme.copper.opacity(0.55), Theme.copper.opacity(0.05)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
    }
}

struct MatteButtonStyle: ButtonStyle {
    enum Kind { case normal, destructive, quiet, copper }

    var kind: Kind = .normal
    var enabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        let base: Color = {
            switch kind {
            case .normal: return configuration.isPressed ? Theme.matteBluePressed : Theme.matteBlue
            case .destructive: return configuration.isPressed ? Theme.matteRedPressed : Theme.matteRed
            case .quiet: return Theme.raised2
            case .copper: return configuration.isPressed ? Theme.copper.opacity(0.8) : Theme.copper
            }
        }()
        let fg: Color = {
            if !enabled { return Color.white.opacity(0.62) }
            switch kind {
            case .quiet: return Theme.text
            case .copper: return Theme.ink
            default: return Color.white
            }
        }()
        configuration.label
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .foregroundColor(fg)
            .padding(.horizontal, 13)
            .frame(height: Theme.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(enabled ? base : Theme.raised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.28), Color.white.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(enabled ? 0.35 : 0.1), radius: 3, y: 1)
    }
}
