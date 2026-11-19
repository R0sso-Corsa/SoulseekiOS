import SwiftUI
import SoulseekCore

struct TransfersView: View {
    @Bindable var model: TransfersModel
    let appModel: AppModel
    @State private var segment = 0
    @State private var showSharing = false

    var body: some View {
        ZStack {
            GlassBackground()
            VStack(spacing: 0) {
                Picker("Transfers", selection: $segment) {
                    Text("Downloads").tag(0)
                    Text("Uploads").tag(1)
                    Text("Library").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 6)

                if segment == 0 {
                    downloadsList
                } else if segment == 1 {
                    uploadsList
                } else {
                    LibraryView(model: appModel.libraryModel)
                }
            }
        }
        .navigationTitle("Transfers")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSharing = true } label: {
                    Image(systemName: "folder.badge.gearshape")
                }
                .accessibilityIdentifier("sharingButton")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear completed") {
                    if segment == 0 { model.clearCompleted() }
                    else { appModel.uploadsModel.clearCompleted() }
                }
                .accessibilityIdentifier("clearCompletedButton")
            }
        }
        .sheet(isPresented: $showSharing) {
            SharingSheet(appModel: appModel)
        }
    }

    private var downloadsList: some View {
        List {
            ForEach(model.transfers) { t in
                TransferRow(
                    transfer: t,
                    speed: model.speeds[t.id] ?? 0,
                    onRetry: { model.retry(t.id) },
                    onCancel: { model.cancel(t.id) },
                    onQueuePlace: { model.queuePlace(t.id) }
                )
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.bottom, 64, for: .scrollContent)
        .overlay {
            if model.transfers.isEmpty {
                ContentUnavailableView(
                    "No transfers",
                    systemImage: "arrow.down.circle",
                    description: Text("Download files from the Search tab.")
                )
            }
        }
    }

    private var uploadsList: some View {
        List {
            ForEach(appModel.uploadsModel.uploads) { u in
                UploadRow(upload: u) {
                    appModel.uploadsModel.cancel(u.id)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.bottom, 64, for: .scrollContent)
        .overlay {
            if appModel.uploadsModel.uploads.isEmpty {
                ContentUnavailableView(
                    "No uploads",
                    systemImage: "arrow.up.circle",
                    description: Text("Share folders (folder button) so others can download from you.")
                )
            }
        }
    }
}

struct UploadRow: View {
    let upload: UploadEngine.Upload
    let onCancel: () -> Void

    private var filename: String {
        let name = upload.filename
        if let i = name.lastIndex(where: { $0 == "\\" || $0 == "/" }) {
            return String(name[name.index(after: i)...])
        }
        return name
    }

    private var isActive: Bool {
        switch upload.state {
        case .queued, .connecting, .transferring: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(filename)
                .font(.subheadline)
                .lineLimit(2)
                .accessibilityIdentifier("uploadFilename")
            HStack {
                Text(upload.username)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                stateLabel
                    .accessibilityIdentifier("uploadState")
            }
            if case .transferring = upload.state {
                ProgressView(value: Double(upload.sent), total: Double(max(upload.size, 1)))
                    .tint(.teal)
                Text(String(format: "%.1f / %.1f MB", Double(upload.sent) / 1_048_576, Double(upload.size) / 1_048_576))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if isActive {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.glass)
                    .tint(.red)
                    .font(.caption)
                    .accessibilityIdentifier("uploadCancelButton")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch upload.state {
        case .queued:
            Text("Queued").font(.caption2).foregroundStyle(.secondary)
        case .connecting:
            Text("Connecting…").font(.caption2).foregroundStyle(.secondary)
        case .transferring:
            Text("Uploading").font(.caption2).foregroundStyle(.teal)
        case .completed:
            Label("Completed", systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green)
        case .failed(let reason):
            Text(reason).font(.caption2).foregroundStyle(.red).lineLimit(2)
        case .cancelled:
            Text("Cancelled").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct TransferRow: View {
    let transfer: TransferEngine.Transfer
    let speed: Double
    let onRetry: () -> Void
    let onCancel: () -> Void
    let onQueuePlace: () -> Void

    private var filename: String {
        let name = transfer.filename
        if let i = name.lastIndex(where: { $0 == "\\" || $0 == "/" }) {
            return String(name[name.index(after: i)...])
        }
        return name
    }

    private var isFailed: Bool {
        if case .failed = transfer.state { return true }
        return false
    }

    private var isActive: Bool {
        switch transfer.state {
        case .queued, .connecting, .waiting, .downloading: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(filename)
                .font(.subheadline)
                .lineLimit(2)
                .accessibilityIdentifier("transferFilename")
            HStack {
                Text(transfer.username)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                stateLabel
                    .accessibilityIdentifier("transferState")
            }
            if case .downloading = transfer.state {
                ProgressView(value: Double(transfer.received), total: Double(max(transfer.size, 1)))
                    .tint(.orange)
                HStack {
                    Text(String(format: "%.1f / %.1f MB", Double(transfer.received) / 1_048_576, Double(transfer.size) / 1_048_576))
                    Spacer()
                    Text(String(format: "%.0f KB/s", speed / 1024))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if transfer.state == .paused {
                ProgressView(value: Double(transfer.received), total: Double(max(transfer.size, 1)))
                    .tint(.secondary)
            }
            if isFailed || transfer.state == .cancelled || transfer.state == .paused || isActive {
                HStack(spacing: 12) {
                    if isFailed || transfer.state == .cancelled || transfer.state == .paused {
                        Button(transfer.state == .paused ? "Resume" : "Retry", action: onRetry)
                            .buttonStyle(.glass)
                            .accessibilityIdentifier("retryButton")
                    }
                    if isActive {
                        Button("Cancel", action: onCancel)
                            .buttonStyle(.glass)
                            .tint(.red)
                            .accessibilityIdentifier("cancelButton")
                        Button("Queue place", action: onQueuePlace)
                            .buttonStyle(.glass)
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch transfer.state {
        case .queued:
            Text("Queued").font(.caption2).foregroundStyle(.secondary)
        case .connecting:
            Text("Connecting…").font(.caption2).foregroundStyle(.secondary)
        case .waiting(let place):
            Text(place.map { "In queue #\($0)" } ?? "In queue")
                .font(.caption2).foregroundStyle(.secondary)
        case .downloading:
            Text("Downloading").font(.caption2).foregroundStyle(.orange)
        case .paused:
            Text("Paused").font(.caption2).foregroundStyle(.secondary)
        case .completed:
            Label("Completed", systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green)
        case .failed(let reason):
            Text(reason).font(.caption2).foregroundStyle(.red).lineLimit(2)
        case .cancelled:
            Text("Cancelled").font(.caption2).foregroundStyle(.secondary)
        }
    }
}