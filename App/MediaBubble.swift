import SwiftUI
import AVKit
import SoulseekProtocol

/// Renders a chat picture/video attachment (AD-16): placeholder while the
/// bytes transfer, then the inline image or video player.
struct MediaBubble: View {
    let card: MediaCard
    let isMine: Bool
    let sender: String
    let store: MediaStore
    let allowCellular: Bool

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
            if !isMine {
                Text(sender)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
        .onAppear { store.ensure(card, allowCellular: allowCellular) }
    }

    @ViewBuilder private var content: some View {
        switch store.state(for: card) {
        case .ready(let url):
            if card.kind == .image {
                if let img = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 240, maxHeight: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .accessibilityIdentifier("mediaImage")
                } else {
                    retry("Couldn't read the image.")
                }
            } else {
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(width: 240, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .accessibilityIdentifier("mediaVideo")
            }
        case .downloading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Downloading \(card.kind == .image ? "photo" : "video")…")
                    .font(.caption)
            }
            .padding(10)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            .accessibilityIdentifier("mediaDownloading")
        case .needsTap:
            Button { store.start(card) } label: {
                Label("Download \(card.kind == .image ? "photo" : "video") (\(byteText))",
                      systemImage: "arrow.down.circle")
                    .font(.caption)
            }
            .accessibilityIdentifier("mediaDownloadButton")
        case .failed(let reason):
            retry(reason)
        case .idle:
            ProgressView()
                .controlSize(.small)
                .padding(10)
        }
    }

    private func retry(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(reason)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Retry") { store.start(card) }
                .font(.caption)
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .accessibilityIdentifier("mediaFailed")
    }

    private var byteText: String {
        ByteCountFormatter.string(fromByteCount: Int64(card.size), countStyle: .file)
    }
}