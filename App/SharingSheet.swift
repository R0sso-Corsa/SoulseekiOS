import SwiftUI
import UniformTypeIdentifiers

/// Sharing settings: pick folders to share, manage roots, upload slots.
struct SharingSheet: View {
    let appModel: AppModel
    @State private var roots: [String] = []
    @State private var fileCount = 0
    @State private var folderCount = 0
    @State private var showPicker = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showPicker = true } label: {
                        Label("Add folder…", systemImage: "folder.badge.plus")
                    }
                    .accessibilityIdentifier("addShareButton")
                    Text("Folders are copied into the app so they stay shared. Audio files only.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Section("Shared folders") {
                    if roots.isEmpty {
                        Text("Nothing shared yet")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("noSharesLabel")
                    }
                    ForEach(roots, id: \.self) { root in
                        HStack {
                            Text(URL(fileURLWithPath: root).lastPathComponent)
                                .font(.subheadline)
                                .accessibilityIdentifier("shareRootRow")
                            Spacer()
                            Button(role: .destructive) {
                                appModel.removeShareRoot(root)
                                reloadSoon()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityIdentifier("removeShareButton")
                        }
                    }
                }
                Section {
                    HStack {
                        Text("Files")
                        Spacer()
                        Text("\(fileCount)").foregroundStyle(.secondary)
                            .accessibilityIdentifier("shareFileCount")
                    }
                    HStack {
                        Text("Folders")
                        Spacer()
                        Text("\(folderCount)").foregroundStyle(.secondary)
                    }
                    Stepper("Upload slots: \(appModel.uploadsModel.slots)",
                            value: Binding(
                                get: { appModel.uploadsModel.slots },
                                set: { appModel.uploadsModel.setSlots($0) }
                            ), in: 1...8)
                        .accessibilityIdentifier("slotsStepper")
                }
            }
            .navigationTitle("Sharing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    appModel.addShareRoot(url)
                    reloadSoon()
                }
            }
            .task { await reload() }
        }
    }

    private func reload() async {
        roots = await appModel.shareRoots()
        let counts = await appModel.shareCounts()
        fileCount = counts.files
        folderCount = counts.folders
    }

    private func reloadSoon() {
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await reload()
        }
    }
}