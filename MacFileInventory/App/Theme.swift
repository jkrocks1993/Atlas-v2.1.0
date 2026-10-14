import SwiftUI

enum Theme {
    static let ink = Color(red: 0.03, green: 0.035, blue: 0.05)
    static let inkSoft = Color(red: 0.07, green: 0.08, blue: 0.11)
    static let raised = Color(red: 0.11, green: 0.125, blue: 0.165)
    static let raised2 = Color(red: 0.16, green: 0.18, blue: 0.24)
    static let paper = Color(red: 0.045, green: 0.05, blue: 0.07)
    static let paperDeep = Color(red: 0.025, green: 0.028, blue: 0.04)
    static let line = Color(red: 0.55, green: 0.46, blue: 0.28).opacity(0.55)
    static let matteBlue = Color(red: 0.32, green: 0.58, blue: 0.98)
    static let matteBluePressed = Color(red: 0.20, green: 0.42, blue: 0.82)
    static let matteRed = Color(red: 0.90, green: 0.32, blue: 0.34)
    static let matteRedPressed = Color(red: 0.70, green: 0.20, blue: 0.22)
    static let copper = Color(red: 0.96, green: 0.76, blue: 0.34)
    static let progressGreen = Color(red: 0.18, green: 0.86, blue: 0.62)
    static let progressTrack = Color(red: 0.10, green: 0.12, blue: 0.16)
    static let separator = Color(red: 0.55, green: 0.46, blue: 0.28).opacity(0.45)
    static let cardFill = Color(red: 0.09, green: 0.10, blue: 0.14)
    static let muted = Color(red: 0.78, green: 0.80, blue: 0.86)
    static let bestGold = Color(red: 0.98, green: 0.82, blue: 0.38)
    static let selection = Color(red: 0.32, green: 0.58, blue: 0.98).opacity(0.38)
    static let chrome = paper
    static let text = Color(red: 0.96, green: 0.97, blue: 0.99)
    static let textDim = Color(red: 0.72, green: 0.75, blue: 0.82)

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
                            colors: [Color.white.opacity(0.34), Color.white.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: (enabled && kind == .normal ? Theme.matteBlue : Color.black).opacity(enabled ? 0.28 : 0.08), radius: configuration.isPressed ? 1 : 6, y: configuration.isPressed ? 0 : 2)
            .scaleEffect(configuration.isPressed && enabled ? 0.97 : 1)
    }
}
