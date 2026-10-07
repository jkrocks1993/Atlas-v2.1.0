import SwiftUI

struct MoveConfirmSheet: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        let records = state.pendingMoveRecords
        let summary = FileOperations.summarize(records: records)
        VStack(alignment: .leading, spacing: 16) {
            Text("\(records.count) files will be moved")
                .font(.system(size: 16, weight: .semibold))
            if let dest = state.pendingMoveDestination {
                Text("Destination: \(dest.path)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(summary) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(item.category.displayName) (\(item.total))")
                            .font(.system(size: 13, weight: .semibold))
                        Text("    Unique (\(item.uniqueCount))")
                            .font(.system(size: 12))
                        Text("    Duplicates (\(item.duplicateCount))")
                            .font(.system(size: 12))
                    }
                }
            }
            Text("Existing names at the destination are never overwritten. Colliding files become name (1).ext.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { state.cancelMove() }
                    .keyboardShortcut(.cancelAction)
                Button("Move") { state.confirmMove() }
                    .buttonStyle(MatteButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}

struct EnhanceSheet: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        let category = state.selectedFile?.category
        VStack(alignment: .leading, spacing: 16) {
            Text("Enhance")
                .font(.system(size: 16, weight: .semibold))
            if category == .images {
                Text("IMAGE").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                kindPicker(image: true)
            } else if category == .videos {
                Text("VIDEO").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                kindPicker(image: false)
            }
            Text("Quality").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            Picker("Quality", selection: $state.enhanceRequest.quality) {
                ForEach(EnhancementQuality.allCases) { q in
                    Text(q.rawValue).tag(q)
                }
            }
            .pickerStyle(.radioGroup)
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Preserve original", isOn: $state.enhanceRequest.preserveOriginal)
                    .toggleStyle(.checkbox)
                Toggle("Create enhanced copy", isOn: $state.enhanceRequest.createCopy)
                    .toggleStyle(.checkbox)
                Toggle("Open enhanced file when finished", isOn: $state.enhanceRequest.openWhenFinished)
                    .toggleStyle(.checkbox)
            }
            if EnhanceEngine.hasCoreMLModel {
                Text("A local Core ML super-resolution model is available and will be used.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                Text("No bundled Core ML model was found. The app will apply a local Core Image enhancement pipeline (Lanczos scale, noise reduction, unsharp mask). This is not advertised as AI.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { state.showEnhance = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(state.isEnhancing)
                Button(state.isEnhancing ? "Enhancing…" : "Enhance") {
                    state.runEnhancement()
                }
                .buttonStyle(MatteButtonStyle(enabled: !state.isEnhancing))
                .disabled(state.isEnhancing)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 440)
    }

    private func kindPicker(image: Bool) -> some View {
        Picker("Scale", selection: $state.enhanceRequest.kind) {
            Text(EnhancementKind.twoX.rawValue).tag(EnhancementKind.twoX)
            if image {
                Text(EnhancementKind.threeX.rawValue).tag(EnhancementKind.threeX)
            }
            Text(EnhancementKind.fourK.rawValue).tag(EnhancementKind.fourK)
            Text(EnhancementKind.maximum.rawValue).tag(EnhancementKind.maximum)
        }
        .pickerStyle(.radioGroup)
    }
}
