import SwiftUI

struct ResultTabs: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            categoryBar
            releaseStatus
            subtabBar
        }
        .background(Theme.ink)
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(FileCategory.uiCases) { category in
                    let enabled = state.categoryCompleted.contains(category)
                    let selected = enabled && state.activeCategory == category
                    let progress = min(1, max(0, state.categoryProgress[category] ?? 0))
                    let running = state.phase == .scanning && !enabled && progress > 0
                    let releasedAfterStop = state.phase == .stopped && enabled

                    Button {
                        guard enabled else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            state.activeCategory = category
                            state.activeKind = nil
                        }
                    } label: {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                // Not-ready tabs intentionally use the normal disabled/ghosted
                                // appearance. Red is reserved for an actively running category.
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(selected ? Theme.matteBlue : (enabled ? Theme.progressGreen : Theme.raised))
                                    .opacity(enabled ? 0.96 : 0.48)

                                if running {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(progressColor(progress))
                                        .frame(width: geo.size.width * CGFloat(progress))
                                        .animation(.easeInOut(duration: 0.22), value: progress)
                                }

                                HStack(spacing: 5) {
                                    if enabled {
                                        Image(systemName: releasedAfterStop ? "pause.circle.fill" : "checkmark.circle.fill")
                                            .font(.system(size: 9, weight: .bold))
                                    }

                                    Text(category.displayName)

                                    if enabled || running {
                                        Text(shortCount(state.count(for: category)))
                                            .foregroundColor(.white.opacity(enabled ? 0.78 : 0.82))
                                    }

                                    if running {
                                        Text("\(Int(progress * 100))%")
                                            .font(.system(size: 9, weight: .bold, design: .rounded))
                                            .foregroundColor(.white.opacity(0.88))
                                    }
                                }
                                .font(.system(size: 11.5, weight: selected ? .bold : .medium, design: .rounded))
                                .foregroundColor(enabled || running ? .white : Color.white.opacity(0.42))
                                .frame(maxWidth: .infinity, alignment: .center)
                            }
                        }
                        .frame(width: 154, height: 29)
                    }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                    .opacity(enabled || running ? 1.0 : 0.72)
                    .help(tabHelp(category: category, enabled: enabled, running: running, progress: progress))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minHeight: 45, idealHeight: 45, maxHeight: 45)
    }

    private func tabHelp(category: FileCategory, enabled: Bool, running: Bool, progress: Double) -> String {
        if enabled {
            return "\(category.displayName) is ready. Click to view released results."
        }
        if running {
            return "Analysing \(category.displayName): \(Int(progress * 100))%"
        }
        return "\(category.displayName) is not ready yet."
    }

    private func shortCount(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000.0) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000.0) }
        return "\(value)"
    }

    private func progressColor(_ progress: Double) -> Color {
        let p = min(1, max(0, progress))
        if p < 0.33 {
            return Color(red: 0.95, green: 0.12 + 0.68 * p / 0.33, blue: 0.06)
        } else if p < 0.66 {
            return Color(red: 1.0, green: 0.78 + 0.22 * (p - 0.33) / 0.33, blue: 0.06 + 0.18 * (p - 0.33) / 0.33)
        } else {
            return Color(red: 0.82 - 0.48 * (p - 0.66) / 0.34, green: 0.98, blue: 0.22 + 0.42 * (p - 0.66) / 0.34)
        }
    }

    private var releaseStatus: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(statusColor)

            Text(statusText)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundColor(Theme.textDim)
                .lineLimit(1)

            Spacer(minLength: 4)

            if state.phase == .scanning || state.phase == .paused {
                Text("\(completedCount)/\(FileCategory.uiCases.count) released")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.textDim)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 24)
    }

    private var completedCount: Int { state.categoryCompleted.intersection(Set(FileCategory.uiCases)).count }

    private var statusIcon: String {
        switch state.phase {
        case .scanning: return "arrow.triangle.2.circlepath"
        case .paused: return "pause.circle"
        case .stopped: return "stop.circle.fill"
        case .completed: return "checkmark.seal.fill"
        case .idle: return "circle"
        }
    }

    private var statusColor: Color {
        switch state.phase {
        case .scanning: return Theme.copper
        case .paused: return Theme.copper
        case .stopped: return Theme.matteRed
        case .completed: return Theme.progressGreen
        case .idle: return Theme.textDim
        }
    }

    private var statusText: String {
        switch state.phase {
        case .scanning:
            return state.statusMessage.isEmpty ? "Processing categories — completed tabs are released immediately." : state.statusMessage
        case .paused:
            return "Paused — released tabs remain available."
        case .stopped:
            return "Stopped — released and partial results remain available."
        case .completed:
            return "Scan complete — all released results are fully available."
        case .idle:
            return "Start a scan to release results category by category."
        }
    }

    private var subtabBar: some View {
        HStack(spacing: 6) {
            subtab("Unique \(state.uniqueCount(for: state.activeCategory))", .unique)
            subtab("Duplicates \(state.duplicateCount(for: state.activeCategory))", .duplicates)
            subtab("Uncompared \(state.uncomparedCount(for: state.activeCategory))", .uncompared)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func subtab(_ title: String, _ value: ResultSubtab) -> some View {
        let selected = state.activeSubtab == value
        return Button {
            state.activeSubtab = value
            state.activeKind = nil
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: selected ? .bold : .regular, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(selected ? Theme.matteBlue : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}
