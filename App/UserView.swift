import SwiftUI
import SoulseekCore
import SoulseekProtocol

/// User info (server stats/status) + share browsing (direct P connection).
struct UserView: View {
    let appModel: AppModel
    let username: String

    @State private var stats: UserStats?
    @State private var status: UserStatus?
    @State private var folders: [SharedFolder]?
    @State private var queuedNotice: String?
    @State private var browseError: String?
    @State private var browsing = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()
                List {
                    Section("User") {
                        Button {
                            appModel.buddyModel.add(username)
                        } label: {
                            Label("Add to buddies", systemImage: "person.badge.plus")
                        }
                        .accessibilityIdentifier("addBuddyFromUserButton")
                        HStack {
                            Text("Status")
                            Spacer()
                            statusLabel
                        }
                        if let stats {
                            HStack {
                                Text("Avg speed")
                                Spacer()
                                Text("\(stats.avgSpeed / 1024) KB/s").foregroundStyle(.secondary)
                            }
                            HStack {
                                Text("Shared")
                                Spacer()
                                Text("\(stats.files) files · \(stats.folders) folders")
                                    .foregroundStyle(.secondary)
                            }
                            HStack {
                                Text("Uploads")
                                Spacer()
                                Text("\(stats.uploadCount)").foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("Shares") {
                        Button {
                            let q = appModel.searchModel.queryText.trimmingCharacters(in: .whitespaces)
                            appModel.searchModel.searchInUser(username, query: q.isEmpty ? "*" : q)
                            appModel.selectedTab = 0
                            dismiss()
                        } label: {
                            Label("Search this user", systemImage: "magnifyingglass")
                        }
                        .accessibilityIdentifier("searchUserButton")
                        Button {
                            Task { await loadBrowse() }
                        } label: {
                            Label(browsing ? "Browsing…" : "Browse shares", systemImage: "folder")
                        }
                        .disabled(browsing)
                        .accessibilityIdentifier("browseButton")
                        if let browseError {
                            Text(browseError)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("browseError")
                        }
                    }
                    if let folders {
                        Section("\(folders.count) folders") {
                            ForEach(folders, id: \.path) { folder in
                                HStack {
                                    NavigationLink {
                                        FolderFilesView(folder: folder, username: username, appModel: appModel)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(folder.path)
                                                .font(.subheadline)
                                                .lineLimit(2)
                                            Text("\(folder.files.count) files")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .accessibilityIdentifier("browseFolder")
                                    Button {
                                        let n = appModel.searchModel.downloadFolder(folder, from: username)
                                        queuedNotice = "Queued \(n) track\(n == 1 ? "" : "s") from \(folder.path). See Transfers."
                                    } label: {
                                        Image(systemName: "arrow.down.circle")
                                            .font(.title3)
                                            .foregroundStyle(.orange)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("folderDownloadButton")
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(username)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Album queued", isPresented: Binding(
                get: { queuedNotice != nil },
                set: { if !$0 { queuedNotice = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(queuedNotice ?? "")
            }
            .task { await loadInfo() }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if let status {
            switch status.status {
            case .online:
                Label("Online", systemImage: "circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .away:
                Label("Away", systemImage: "moon.fill")
                    .font(.caption).foregroundStyle(.orange)
            case .offline:
                Label("Offline", systemImage: "circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("…").foregroundStyle(.secondary)
        }
    }

    private func loadInfo() async {
        async let s = try? appModel.userStats(for: username)
        async let t = try? appModel.userStatus(for: username)
        stats = await s
        status = await t
    }

    private func loadBrowse() async {
        browsing = true
        browseError = nil
        defer { browsing = false }
        do {
            folders = try await appModel.browseShares(of: username)
        } catch {
            browseError = error.localizedDescription
        }
    }
}

/// Files inside one browsed folder; download uses the joined full path.
struct FolderFilesView: View {
    let folder: SharedFolder
    let username: String
    let appModel: AppModel
    @State private var queuedNotice: String?

    var body: some View {
        ZStack {
            GlassBackground()
            List {
                ForEach(folder.files, id: \.path) { file in
                    FileRow(file: file) {
                        appModel.searchModel.download(
                            path: folder.path + "\\" + file.path,
                            size: file.size,
                            from: username
                        )
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(folder.path)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    let n = appModel.searchModel.downloadFolder(folder, from: username)
                    queuedNotice = "Queued \(n) track\(n == 1 ? "" : "s"). See Transfers."
                } label: {
                    Label("Download all", systemImage: "arrow.down.circle")
                }
                .disabled(folder.files.isEmpty)
                .accessibilityIdentifier("folderDownloadButton")
            }
        }
        .alert("Album queued", isPresented: Binding(
            get: { queuedNotice != nil },
            set: { if !$0 { queuedNotice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(queuedNotice ?? "")
        }
    }
}