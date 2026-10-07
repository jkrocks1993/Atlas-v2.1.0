import SwiftUI
import AppKit

struct ResultsPane: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HSplitView {
                FileListView()
                    .frame(minWidth: 420)
                PreviewPane()
                    .frame(minWidth: 460)
            }
        }
        .background(Theme.paper)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Theme.muted)
            HStack(spacing: 4) {
                TextField("Search name, path or folder", text: $state.searchText)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                if !state.searchText.isEmpty {
                    Button { state.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 6)
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
            .frame(maxWidth: 300)
            Button("Select All") { state.selectAllVisible() }
                .buttonStyle(MatteButtonStyle(kind: .quiet))
            Button("Select Duplicates") { state.selectInferiorDuplicates() }
                .buttonStyle(MatteButtonStyle(kind: .quiet))
                .help("Checks inferior copies only. BEST stays unmarked.")
            if state.activeSubtab == .duplicates {
                Button("NOT DUPLICATE") { state.markSelectedAsNotDuplicate() }
                    .buttonStyle(MatteButtonStyle(kind: .normal, enabled: !state.checkedIDs.isEmpty))
                    .disabled(state.checkedIDs.isEmpty || state.phase == .scanning || state.phase == .paused)
                    .help("Teach ATLAS that the selected item(s) are not duplicates. The decision is stored locally.")
            } else if state.activeSubtab == .unique {
                Button("NOT UNIQUE") { state.markSelectedAsNotUnique() }
                    .buttonStyle(MatteButtonStyle(kind: .normal, enabled: !state.checkedIDs.isEmpty))
                    .disabled(state.checkedIDs.isEmpty || state.phase == .scanning || state.phase == .paused)
                    .help("Teach ATLAS that the selected item(s) should be treated as duplicate evidence. The decision is stored locally.")
            }
            Button("Clear") { state.clearChecks() }
                .buttonStyle(MatteButtonStyle(kind: .quiet))
            HStack(spacing: 2) {
                ForEach(ResultLayout.allCases) { layout in
                    Button {
                        state.setResultLayout(layout)
                    } label: {
                        Image(systemName: layout.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 28, height: 24)
                            .foregroundColor(state.resultLayout == layout ? Theme.ink : Theme.text)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(state.resultLayout == layout ? Theme.copper : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(layout.label)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.raised))
            .help("List, tiles, or large tiles. Duplicate groups stay separated.")
            Text("learned \(OfflinePairModel.shared.trainedExamples)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(Theme.muted)
                .help("Local corrections stored on this Mac. Nothing is uploaded.")
            if state.isLoadingRows {
                ProgressView().controlSize(.small)
                Text(state.searchText.isEmpty ? "Loading results…" : "Searching current tab…")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(state.searchText.isEmpty
                 ? "Loaded \(state.loadedFileRowCount.formatted()) / \(state.activeResultTotalCount.formatted()) items"
                 : "\(state.loadedFileRowCount.formatted()) matching items loaded")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text("Sort")
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(Theme.text)
            Picker("Sort", selection: $state.sortField) {
                ForEach(SortField.allCases) { field in
                    Text(field.label).tag(field)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            Picker("Direction", selection: $state.sortDirection) {
                ForEach(SortDirection.allCases) { dir in
                    Text(dir.label).tag(dir)
                }
            }
            .labelsHidden()
            .frame(width: 120)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.paperDeep)
    }
}
