import SwiftUI

/// Completed-downloads library: list, sort, delete, export, storage usage,
/// and a preview player to verify files (AD-15 — full playback still planned
/// separately).
struct LibraryView: View {
    @Bindable var model: LibraryModel
    @State private var shareItem: URL?
    @State private var previewItem: URL?
    @State private var deleteTarget: LibraryModel.LibraryFile?

    var body: some View {
        List {
            Section {
                if model.files.isEmpty {
                    Text("No downloads yet")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("libraryEmpty")
                }
                ForEach(model.files) { file in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name)
                                .font(.subheadline)
                                .lineLimit(2)
                                .accessibilityIdentifier("libraryFile")
                            Text("\(sizeText(file.size)) · \(file.date.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            previewItem = file.url
                        } label: {
                            Image(systemName: "play.circle")
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("libraryPreviewButton")
                        Button {
                            shareItem = file.url
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("libraryShareButton")
                        Button {
                            deleteTarget = file
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("libraryDeleteRowButton")
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            model.delete(file)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .accessibilityIdentifier("libraryDeleteButton")
                    }
                }
            } footer: {
                Text("\(model.files.count) files · \(sizeText(model.totalBytes)) used")
                    .accessibilityIdentifier("libraryStorage")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $model.sortOrder) {
                        ForEach(LibraryModel.SortOrder.allCases, id: \.self) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityIdentifier("librarySortButton")
            }
        }
        .sheet(isPresented: Binding(
            get: { shareItem != nil },
            set: { if !$0 { shareItem = nil } }
        )) {
            if let shareItem {
                ShareSheet(items: [shareItem])
            }
        }
        .sheet(isPresented: Binding(
            get: { previewItem != nil },
            set: { if !$0 { previewItem = nil } }
        )) {
            if let previewItem {
                PreviewPlayerSheet(url: previewItem)
            }
        }
        .confirmationDialog(
            "Delete \(deleteTarget?.name ?? "")?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let file = deleteTarget { model.delete(file) }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("This removes the file from your device. You can download it again later.")
        }
        .onAppear { model.refresh() }
    }

    private func sizeText(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }
}