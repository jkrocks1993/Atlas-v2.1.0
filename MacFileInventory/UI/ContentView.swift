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
        .sheet(isPresented: $state.showReleaseNotes, onDismiss: { state.dismissReleaseNotes() }) {
            ReleaseNotesSheet()
                .environmentObject(state)
        }
        .onAppear { state.noteCurrentReleaseIfNeeded() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Theme.copper, Color(red: 0.98, green: 0.55, blue: 0.28)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 40, height: 40)
                    .shadow(color: Theme.copper.opacity(0.45), radius: 10, y: 3)
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.ink)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("ATLAS")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .tracking(3.4)
                    .foregroundColor(Theme.copper)
                Text("File Inventory & Duplicates")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.text)
            }
            Spacer()
            versionBadge
            phaseChip
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            LinearGradient(
                colors: [Theme.ink, Color(red: 0.05, green: 0.07, blue: 0.12)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    private var versionBadge: some View {
        Button { state.showReleaseNotes = true } label: {
            Text("v\(ReleaseNotes.currentVersion)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.82))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help("Atlas v\(ReleaseNotes.currentVersion) — click for what changed")
    }

    private var phaseChip: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(phaseColor)
                .frame(width: 8, height: 8)
                .shadow(color: phaseColor.opacity(state.phase == .scanning ? 0.9 : 0), radius: 5)
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
                .buttonStyle(MatteButtonStyle(kind: .destructive, enabled: state.canTrashSelection))
                .disabled(!state.canTrashSelection)
                .help(state.phase == .scanning || state.phase == .paused
                      ? "While a scan is running, only inferior duplicates of a finished tab can be deleted. BEST stays so later tabs can still match it."
                      : "Move the checked files to Trash.")
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
            Text("\(state.checkedIDs.count) selected")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(Theme.text)
                .help("Click a file to preview it without changing the checks. Use the checkbox, Select Duplicates, Command-click, Shift-click, or a drag to change the selection.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.paperDeep)
    }
}

enum ReleaseNotes {
    static let currentVersion = "2.1.8"
    static let currentBuild = "22"

    struct Entry: Identifiable {
        let id: String
        let version: String
        let build: String
        let lines: [String]
    }

    static let history: [Entry] = [
        Entry(id: "2.1.8", version: "2.1.8", build: "22", lines: [
            "Arrow keys keep the highlighted file inside the list. Down parks it on the bottom edge. Up parks it on the top edge. A file already on screen does not move the list."
        ]),
        Entry(id: "2.1.7", version: "2.1.7", build: "21", lines: [
            "Arrow keys now scroll the list with the preview. The highlighted file stays on screen, and the list only moves when that file would leave the top or the bottom.",
            "Visual refresh. Same controls, darker glass layout, brighter selected tabs, hover on rows and tiles, and a moving progress sheen."
        ]),
        Entry(id: "2.1.6", version: "2.1.6", build: "20", lines: [
            "Fixed the 2.1.5 build error. The app compiles again.",
            "Everything from 2.1.5 is included: tile arrow keys, preview that does not clear a selection, comparison ETA, and delete for inferior duplicates of a finished tab."
        ]),
        Entry(id: "2.1.5", version: "2.1.5", build: "19", lines: [
            "Arrow keys move one tile at a time, including left and right. Preview no longer clears a selection.",
            "Select Duplicates stays checked while you preview other files.",
            "The time estimate now follows comparison, not the fast survey.",
            "Finished scans keep the result list on screen.",
            "While a scan is still running, Delete works on inferior duplicates of a finished tab. BEST stays until the scan ends. After completion, every checked file can be deleted."
        ]),
        Entry(id: "2.1.4", version: "2.1.4", build: "18", lines: [
            "Drag selection now starts in the empty space under and beside the tiles, not only on a tile.",
            "The selection rectangle stays smooth. The list updates only when the set of selected files changes."
        ]),
        Entry(id: "2.1.3", version: "2.1.3", build: "17", lines: [
            "Drag across files with the trackpad or mouse to select them.",
            "The blue rectangle selects every file it touches, in the list and in tiles.",
            "Hold Command while dragging to add to the selection you already have.",
            "Two-finger scrolling is unchanged."
        ]),
        Entry(id: "2.1.2", version: "2.1.2", build: "16", lines: [
            "Tiles and Large tiles now show real thumbnails.",
            "Photos, image PDFs, and videos use the picture itself, not a blank document icon.",
            "Other files still show their Finder icon."
        ]),
        Entry(id: "2.1.1", version: "2.1.1", build: "15", lines: [
            "Selection now works like Finder.",
            "Click a file, with the trackpad or the mouse, to select only that file.",
            "Command-click adds or removes a file without clearing the others.",
            "Shift-click selects every file from the last anchor to the one you clicked.",
            "Delete and Move use that selection. Arrow keys still only move the preview.",
            "This build installs into /Applications/Atlas.app, not Downloads.",
            "Later updates are patches. The version in the header changes, and the notes are listed here."
        ]),
        Entry(id: "2.1.0", version: "2.1.0", build: "14", lines: [
            "List, tile, and large-tile views, with duplicate groups kept apart.",
            "Local learning from NOT DUPLICATE and NOT UNIQUE.",
            "Large-scan results stay in a local SQLite database."
        ])
    ]
}

struct ReleaseNotesSheet: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ATLAS \(ReleaseNotes.currentVersion)")
                        .font(.system(size: 20, weight: .semibold, design: .serif))
                        .foregroundColor(Theme.text)
                    Text("Build \(ReleaseNotes.currentBuild)  \u00b7  installed in /Applications")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Close") { state.dismissReleaseNotes() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(ReleaseNotes.history) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("v\(entry.version)  \u00b7  build \(entry.build)")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundColor(Theme.copper)
                            ForEach(entry.lines, id: \.self) { line in
                                Text("\u2022  \(line)")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.text)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .frame(width: 520, height: 420)
        .background(Theme.paper)
    }
}
