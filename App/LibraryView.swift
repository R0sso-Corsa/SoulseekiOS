import SwiftUI

/// Completed-downloads library, grouped by album: tap a title to preview
/// (album queue), play-all per album, two-step delete (swipe → Delete →
/// confirm) for tracks and whole albums. AD-15 — full playback still
/// planned separately.
struct LibraryView: View {
    @Bindable var model: LibraryModel
    @State private var shareItem: URL?
    @State private var previewQueue: [URL] = []
    @State private var previewIndex = 0
    @State private var deleteTarget: LibraryModel.LibraryFile?
    @State private var deleteAlbumTarget: LibraryModel.Album?

    var body: some View {
        List {
            if model.files.isEmpty {
                Text("No downloads yet")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("libraryEmpty")
            }
            ForEach(model.albums) { album in
                Section {
                    ForEach(album.files) { file in
                        HStack {
                            Button {
                                previewQueue = album.files.map(\.url)
                                previewIndex = album.files.firstIndex(of: file) ?? 0
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.name)
                                        .font(.subheadline)
                                        .lineLimit(2)
                                        .accessibilityIdentifier("libraryFile")
                                    Text("\(sizeText(file.size)) · \(file.date.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("libraryTitleButton")
                            Spacer()
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
                            // Two-step: swipe reveals Delete; tapping it asks
                            // for confirmation before removing anything.
                            Button(role: .destructive) {
                                deleteTarget = file
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .accessibilityIdentifier("libraryDeleteButton")
                        }
                    }
                } header: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(album.name)
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                                .accessibilityIdentifier("albumHeader")
                            Text("\(album.files.count) track\(album.files.count == 1 ? "" : "s") · \(sizeText(album.totalBytes))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            previewQueue = album.files.map(\.url)
                            previewIndex = 0
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("albumPlayButton")
                        Menu {
                            Button("Delete album", role: .destructive) {
                                deleteAlbumTarget = album
                            }
                            .accessibilityIdentifier("albumDeleteOption")
                        } label: {
                            Image(systemName: "ellipsis")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("albumMenu")
                    }
                }
            }
            Section {
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
            get: { !previewQueue.isEmpty },
            set: { if !$0 { previewQueue = [] } }
        )) {
            PreviewPlayerSheet(urls: previewQueue, startIndex: previewIndex)
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
        .confirmationDialog(
            "Delete album \(deleteAlbumTarget?.name ?? "")?",
            isPresented: Binding(
                get: { deleteAlbumTarget != nil },
                set: { if !$0 { deleteAlbumTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete \(deleteAlbumTarget?.files.count ?? 0) tracks", role: .destructive) {
                if let album = deleteAlbumTarget { model.deleteAlbum(album) }
                deleteAlbumTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteAlbumTarget = nil }
        } message: {
            Text("This removes every track in the album from your device.")
        }
        .onAppear { model.refresh() }
    }

    private func sizeText(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }
}