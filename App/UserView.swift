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
    }
}