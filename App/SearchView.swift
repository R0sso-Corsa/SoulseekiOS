import SwiftUI
import SoulseekProtocol

struct SearchView: View {
    @Bindable var model: SearchModel
    var appModel: AppModel? = nil
    @State private var selectedUser: String?
    @State private var showWishlist = false
    @State private var showCustomBitrate = false
    @State private var customBitrateText = ""

    var body: some View {
        ZStack {
            GlassBackground()
            VStack(spacing: 12) {
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        TextField("Search Soulseek…", text: $model.queryText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .glassEffect(.regular.interactive(), in: .capsule)
                            .frame(height: 44)
                            .accessibilityIdentifier("searchField")
                            .onSubmit { model.search() }
                        Button {
                            if model.isSearching { model.stop() } else { model.search() }
                        } label: {
                            Image(systemName: model.isSearching ? "stop.fill" : "magnifyingglass")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .glassEffect(.regular.tint(Color.orange.opacity(0.85)).interactive(), in: .capsule)
                                .frame(height: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.queryText.trimmingCharacters(in: .whitespaces).isEmpty && !model.isSearching)
                        .accessibilityIdentifier("searchButton")
                        .accessibilityLabel(model.isSearching ? "Stop" : "Search")
                    }
                }
                .padding(.horizontal)
                .padding(.top, 4)

                ScrollView(.horizontal, showsIndicators: false) {
                    GlassEffectContainer(spacing: 6) {
                        HStack(spacing: 6) {
                        Menu {
                            Picker("Min bitrate", selection: $model.minBitrate) {
                                Text("Any bitrate").tag(0)
                                Text("128+").tag(128)
                                Text("192+").tag(192)
                                Text("256+").tag(256)
                                Text("320").tag(320)
                            }
                            Divider()
                            Button("Custom…") {
                                customBitrateText = model.minBitrate > 0 ? String(model.minBitrate) : ""
                                showCustomBitrate = true
                            }
                        } label: {
                            GlassChipLabel(
                                title: model.minBitrate == 0 ? "Bitrate" : "\(model.minBitrate)+",
                                systemImage: "waveform",
                                selected: model.minBitrate > 0
                            )
                        }
                        .alert("Custom min bitrate", isPresented: $showCustomBitrate) {
                            TextField("kbps", text: $customBitrateText)
                                .keyboardType(.numberPad)
                            Button("Apply") {
                                model.minBitrate = max(0, Int(customBitrateText) ?? 0)
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Minimum bitrate in kbps — any value, e.g. 500 or 1000.")
                        }
                        Button { model.freeSlotsOnly.toggle() } label: {
                            GlassChipLabel(title: "Slots", systemImage: "checkmark.circle", selected: model.freeSlotsOnly)
                        }
                        .buttonStyle(.plain)
                        Button { model.losslessOnly.toggle() } label: {
                            GlassChipLabel(title: "Lossless", systemImage: "hifispeaker", selected: model.losslessOnly)
                        }
                        .buttonStyle(.plain)
                        Menu {
                            Picker("Min bit depth", selection: $model.minBitDepth) {
                                Text("Any depth").tag(0)
                                Text("16-bit+").tag(16)
                                Text("24-bit+").tag(24)
                                Text("32-bit+").tag(32)
                            }
                        } label: {
                            GlassChipLabel(
                                title: model.minBitDepth == 0 ? "Depth" : "\(model.minBitDepth)+",
                                systemImage: "slider.vertical.3",
                                selected: model.minBitDepth > 0
                            )
                        }
                        }
                    }
                    .padding(.horizontal)
                }

                HStack {
                    HStack(spacing: 6) {
                        if model.isSearching {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(model.statusText)
                            .font(.footnote)
                            .accessibilityIdentifier("searchStatus")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .glassEffect(.regular, in: .capsule)
                    Spacer()
                }
                .padding(.horizontal)

                List {
                    ForEach(model.groups) { group in
                        Section {
                            ForEach(group.files, id: \.path) { file in
                                FileRow(file: file) {
                                    model.download(file, from: group.username)
                                }
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.folder.isEmpty ? "(root)" : group.folder)
                                    .font(.caption).bold()
                                    .lineLimit(2)
                                HStack(spacing: 4) {
                                    Button {
                                        selectedUser = group.username
                                    } label: {
                                        Text(group.username).underline()
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("userButton")
                                    if group.freeSlots {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                    Text("\(group.avgSpeed / 1024) KB/s")
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.bottom, 64, for: .scrollContent)
                .overlay {
                    if model.groups.isEmpty && !model.isSearching {
                        ContentUnavailableView(
                            "No results",
                            systemImage: "magnifyingglass",
                            description: Text("Search for artists, albums, or labels.")
                        )
                    }
                }
            }
        }
        .navigationTitle("Search")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 14) {
                    Button {
                        appModel?.wishlistModel.add(model.queryText)
                    } label: {
                        Image(systemName: "bookmark.plus")
                    }
                    .disabled(model.queryText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("saveWishButton")
                    Button { showWishlist = true } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityIdentifier("wishlistButton")
                }
            }
        }
        .sheet(isPresented: $showWishlist) {
            if let appModel {
                WishlistSheet(model: appModel.wishlistModel) { query in
                    model.queryText = query
                    model.search()
                    showWishlist = false
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { selectedUser != nil },
            set: { if !$0 { selectedUser = nil } }
        )) {
            if let username = selectedUser, let appModel {
                UserView(appModel: appModel, username: username)
            }
        }
    }
}

struct FileRow: View {
    let file: FileEntry
    var onDownload: (() -> Void)? = nil

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.filename)
                    .font(.subheadline)
                    .lineLimit(2)
                    .accessibilityIdentifier("resultFilename")
                HStack(spacing: 6) {
                    Text(file.ext.uppercased())
                    if let bitrate = file.bitrate, bitrate > 0 { Text("\(bitrate) kbps") }
                    if let sampleRate = file.sampleRate { Text("\(sampleRate / 1000) kHz") }
                    if let bitness = file.bitness, bitness > 0 {
                        Text("\(bitness)-bit")
                            .accessibilityIdentifier("fileBitDepth")
                    }
                    if let duration = file.duration { Text(durationText(duration)) }
                    Text(sizeText(file.size))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let onDownload {
                Button(action: onDownload) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("downloadButton")
                .accessibilityLabel("Download \(file.filename)")
            }
        }
    }

    private func durationText(_ seconds: UInt32) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func sizeText(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1 ? String(format: "%.1f MB", mb) : String(format: "%.0f KB", Double(bytes) / 1024)
    }
}