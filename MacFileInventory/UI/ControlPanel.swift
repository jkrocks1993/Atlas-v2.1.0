import SwiftUI

struct ControlPanel: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                locationColumn
                selectedPath
            }
            categories
            controls
            progressBlock
            statsLine
            categoryStatusLine
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.paper)
    }

    private var locationColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Location")
            HStack(spacing: 8) {
                Button("Entire Mac") { state.chooseEntireMac() }
                    .buttonStyle(MatteButtonStyle(kind: state.location.isEntireMac ? .copper : .quiet))
                Button("Select Folder…") { state.chooseFolder() }
                    .buttonStyle(MatteButtonStyle(kind: state.location.isEntireMac ? .quiet : .normal))
                Menu {
                    ForEach(state.mountedVolumes, id: \.path) { url in
                        Button(url.path) { state.chooseVolume(url) }
                    }
                    Divider()
                    Button("Refresh list") { state.refreshVolumes() }
                } label: {
                    Text("Mounted drives ▾")
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundColor(Theme.text)
                        .padding(.horizontal, 13)
                        .frame(height: Theme.controlHeight)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised2))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.22), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
            }
        }
    }

    private var selectedPath: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(text: state.location.isEntireMac ? "Selected location · Entire Mac" : "Selected location")
            Text(state.location.displayPath)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .foregroundColor(Theme.text)
            if state.location.isEntireMac {
                Text("Internal system volume only. Grant Full Disk Access if folders are skipped.")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.line, lineWidth: 1)
                )
        )
    }

    private var categories: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Scan types")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], alignment: .leading, spacing: 6) {
                ForEach(FileCategory.uiCases) { category in
                    Toggle(category.displayName, isOn: Binding(
                        get: { state.enabledCategories.contains(category) },
                        set: { on in
                            if on {
                                state.enabledCategories.insert(category)
                            } else if state.enabledCategories.count > 1 {
                                state.enabledCategories.remove(category)
                                if state.activeCategory == category,
                                   let first = FileCategory.allCases.first(where: { state.enabledCategories.contains($0) }) {
                                    state.activeCategory = first
                                }
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(Theme.text)
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button("Scan") { state.startScan() }
                .buttonStyle(MatteButtonStyle(kind: .normal, enabled: state.phase != .scanning))
                .disabled(state.phase == .scanning)
            Button("Pause") { state.pauseScan() }
                .buttonStyle(MatteButtonStyle(kind: .quiet, enabled: state.phase == .scanning))
                .disabled(state.phase != .scanning)
            Button("Resume") { state.resumeScan() }
                .buttonStyle(MatteButtonStyle(kind: .quiet, enabled: state.phase == .paused))
                .disabled(state.phase != .paused)
            Button("Stop") { state.stopScan() }
                .buttonStyle(MatteButtonStyle(kind: .destructive, enabled: state.phase == .scanning || state.phase == .paused))
                .disabled(!(state.phase == .scanning || state.phase == .paused))
            Spacer()
        }
    }

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.progressTrack)
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.progressGreen)
                        .frame(width: max(0, geo.size.width * CGFloat(state.progress)))
                    HStack {
                        Text("PROGRESS")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .tracking(1)
                            .foregroundColor(Color.white.opacity(0.55))
                            .padding(.leading, 10)
                        Spacer()
                        Text(state.etaLabel.isEmpty
                             ? "\(Int((state.progress * 100).rounded()))%"
                             : "\(Int((state.progress * 100).rounded()))%  ·  \(state.etaLabel)")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.trailing, 10)
                    }
                }
            }
            .frame(height: Theme.progressHeight)
            Text(state.currentPath.isEmpty ? " " : "Scanning: \(state.currentPath)")
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(Theme.muted)
        }
    }

    private var categoryStatusLine: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(categoryStatusColor)
                .frame(width: 6, height: 6)
            Text(categoryStatusText)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundColor(Theme.textDim)
                .lineLimit(1)
            Spacer()
        }
        .frame(height: 16)
    }

    private var categoryStatusColor: Color {
        if state.categoryCompleted.contains(state.activeCategory) { return Theme.progressGreen }
        if state.phase == .scanning || state.phase == .paused { return Theme.copper }
        if state.phase == .stopped { return Theme.matteRed }
        return Theme.textDim
    }

    private var categoryStatusText: String {
        let category = state.activeCategory.displayName
        if state.categoryCompleted.contains(state.activeCategory) {
            return "\(category) released — results are ready to browse."
        }
        if state.phase == .scanning || state.phase == .paused {
            let p = Int(((state.categoryProgress[state.activeCategory] ?? 0) * 100).rounded())
            return "\(category) processing — \(p)%"
        }
        if state.phase == .stopped {
            return "Scan stopped — use the released results; remaining items were not fully verified."
        }
        return "\(category) is waiting to be processed."
    }

    private var statsLine: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(state.statistics.singleLine)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(Theme.textDim)
                .padding(.vertical, 2)
        }
        .frame(height: 20)
    }
}
