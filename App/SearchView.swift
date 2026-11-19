import SwiftUI
import SoulseekProtocol

struct SearchView: View {
    @Bindable var model: SearchModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search Soulseek…", text: $model.queryText)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("searchField")
                    .onSubmit { model.search() }
                Button(model.isSearching ? "Stop" : "Search") {
                    if model.isSearching { model.stop() } else { model.search() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.queryText.trimmingCharacters(in: .whitespaces).isEmpty && !model.isSearching)
                .accessibilityIdentifier("searchButton")
            }
            .padding([.horizontal, .top])

            HStack {
                Menu {
                    Picker("Min bitrate", selection: $model.minBitrate) {
                        Text("Any bitrate").tag(0)
                        Text("128+").tag(128)
                        Text("192+").tag(192)
                        Text("256+").tag(256)
                        Text("320").tag(320)
                    }
                } label: {
                    Label(model.minBitrate == 0 ? "Bitrate" : "\(model.minBitrate)+", systemImage: "waveform")
                }
                Toggle("Slots", isOn: $model.freeSlotsOnly)
                    .toggleStyle(.button)
                Toggle("Lossless", isOn: $model.losslessOnly)
                    .toggleStyle(.button)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 6)

            Text(model.statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .accessibilityIdentifier("searchStatus")

            List {
                ForEach(model.groups) { group in
                    Section {
                        ForEach(group.files, id: \.path) { file in
                            FileRow(file: file)
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.folder.isEmpty ? "(root)" : group.folder)
                                .font(.caption).bold()
                                .lineLimit(2)
                            HStack(spacing: 4) {
                                Text(group.username)
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
        .navigationTitle("Search")
    }
}

struct FileRow: View {
    let file: FileEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(file.filename)
                .font(.subheadline)
                .lineLimit(2)
                .accessibilityIdentifier("resultFilename")
            HStack(spacing: 6) {
                Text(file.ext.uppercased())
                if let bitrate = file.bitrate, bitrate > 0 { Text("\(bitrate) kbps") }
                if let sampleRate = file.sampleRate { Text("\(sampleRate / 1000) kHz") }
                if let duration = file.duration { Text(durationText(duration)) }
                Text(sizeText(file.size))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
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