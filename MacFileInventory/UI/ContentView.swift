import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ControlPanel()
            Hairline()
            ResultTabs()
            ResultsPane()
            Hairline()
            footer
        }
        .background(Theme.paper)
        .alert(state.alertTitle, isPresented: $state.showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(state.alertMessage)
        }
        .sheet(isPresented: $state.showMoveConfirm) {
            MoveConfirmSheet()
                .environmentObject(state)
        }
        .sheet(isPresented: $state.showEnhance) {
            EnhanceSheet()
                .environmentObject(state)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Theme.copper, Theme.copper.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)
                    .shadow(color: Theme.copper.opacity(0.35), radius: 8, y: 2)
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundColor(Theme.ink)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("ATLAS")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .tracking(3.2)
                    .foregroundColor(Theme.copper)
                Text("File Inventory & Duplicates")
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .foregroundColor(Theme.text)
            }
            Spacer()
            versionBadge
            phaseChip
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Theme.ink)
    }

    private var versionBadge: some View {
        Text("v2.1.0")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundColor(.white.opacity(0.82))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .help("Atlas v2.1.0 — local learning, tiles and large preview")
    }

    private var phaseChip: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(phaseColor)
                .frame(width: 8, height: 8)
            Text(state.statusMessage.uppercased())
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundColor(.white.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.10)))
    }

    private var phaseColor: Color {
        switch state.phase {
        case .scanning: return Theme.progressGreen
        case .paused: return Theme.copper
        case .completed: return Theme.matteBlue
        case .stopped: return Theme.matteRed
        case .idle: return Color.white.opacity(0.35)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Delete → Trash") { state.deleteChecked() }
                .buttonStyle(MatteButtonStyle(kind: .destructive, enabled: !state.checkedIDs.isEmpty && state.phase != .scanning && state.phase != .paused))
                .disabled(state.checkedIDs.isEmpty || state.phase == .scanning || state.phase == .paused)
            Button("Move…") { state.requestMove() }
                .buttonStyle(MatteButtonStyle(kind: .normal, enabled: !state.checkedIDs.isEmpty && state.phase != .scanning && state.phase != .paused))
                .disabled(state.checkedIDs.isEmpty || state.phase == .scanning || state.phase == .paused)
            Button("Go to Folder") { state.revealSelectedInFinder() }
                .buttonStyle(MatteButtonStyle(kind: .quiet, enabled: state.selectedFile != nil))
                .disabled(state.selectedFile == nil)
            Button("Enhance") { state.enhanceSelected() }
                .buttonStyle(MatteButtonStyle(
                    kind: state.selectedFile != nil ? .copper : .quiet,
                    enabled: state.selectedFile != nil
                ))
                .disabled(state.selectedFile == nil)
            Spacer()
            Text("\(state.checkedIDs.count) marked")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(Theme.text)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.paperDeep)
    }
}
