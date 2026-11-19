import SwiftUI
import SoulseekCore

struct WishlistSheet: View {
    @Bindable var model: WishlistModel
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()
                List {
                    ForEach(model.items) { item in
                        Button {
                            onPick(item.query)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.query)
                                    .font(.subheadline)
                                Text(subtitle(item))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("wishRow")
                        .swipeActions {
                            Button(role: .destructive) {
                                model.remove(item.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .accessibilityIdentifier("wishDeleteButton")
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .overlay {
                    if model.items.isEmpty {
                        ContentUnavailableView(
                            "No saved searches",
                            systemImage: "bookmark",
                            description: Text("Save a search with the bookmark button; it re-runs automatically every ~12 minutes.")
                        )
                    }
                }
            }
            .navigationTitle("Wishlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Run all") { model.runAll() }
                        .disabled(model.items.isEmpty)
                        .accessibilityIdentifier("runAllWishesButton")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func subtitle(_ item: WishlistEngine.Item) -> String {
        guard let last = item.lastRun else { return "Not run yet" }
        let ago = Int(Date().timeIntervalSince(last) / 60)
        return "\(item.lastResultCount) files · \(ago < 1 ? "just now" : "\(ago)m ago")"
    }
}