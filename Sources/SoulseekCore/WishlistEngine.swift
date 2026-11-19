import Foundation
import SoulseekProtocol

/// Saved searches re-run on the server's WishlistInterval (104, usually 720s).
/// Items persist as JSON; results counts update after each run. Interactive
/// searches take priority — a cycle skips while the user is searching.
public actor WishlistEngine {
    public struct Item: Identifiable, Equatable, Sendable, Codable {
        public let id: UUID
        public var query: String
        public var addedAt: Date
        public var lastRun: Date?
        public var lastResultCount: Int

        public init(query: String) {
            self.id = UUID()
            self.query = query
            self.addedAt = Date()
            self.lastRun = nil
            self.lastResultCount = 0
        }
    }

    public private(set) var items: [Item] = []
    public private(set) var interval: UInt64
    public nonisolated let updates: AsyncStream<[Item]>
    private let updatesContinuation: AsyncStream<[Item]>.Continuation

    private let server: ServerConnection
    private let searchEngine: SearchEngine
    private let storeURL: URL
    private let searchTimeout: TimeInterval
    private var loopTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var running = false

    public init(server: ServerConnection, searchEngine: SearchEngine, storeURL: URL, interval: UInt64 = 720, searchTimeout: TimeInterval = 15) {
        self.server = server
        self.searchEngine = searchEngine
        self.storeURL = storeURL
        self.interval = interval
        self.searchTimeout = searchTimeout
        var cont: AsyncStream<[Item]>.Continuation?
        updates = AsyncStream { cont = $0 }
        updatesContinuation = cont!
        if let data = try? Data(contentsOf: storeURL),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
        loopTask = Task { await self.loop() }
        eventTask = Task { await self.consumeEvents() }
    }

    deinit {
        updatesContinuation.finish()
    }

    public func shutdown() async {
        loopTask?.cancel()
        loopTask = nil
        eventTask?.cancel()
        eventTask = nil
    }

    public func add(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !items.contains(where: { $0.query == q }) else { return }
        items.append(Item(query: q))
        save()
        publish()
    }

    public func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
        publish()
    }

    public func runNow(_ id: UUID) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        await run(item)
    }

    public func runAll() async {
        guard !running else { return }
        running = true
        defer { running = false }
        for item in items {
            if Task.isCancelled { return }
            await run(item)
        }
    }

    private func run(_ item: Item) async {
        // Interactive searches win; retry this item next cycle.
        if await searchEngine.state.isSearching { return }
        await searchEngine.search(item.query, timeout: searchTimeout, wishlist: true)
        let deadline = Date().addingTimeInterval(searchTimeout + 5)
        var state = await searchEngine.state
        while Date() < deadline && !state.finished {
            try? await Task.sleep(nanoseconds: 200_000_000)
            state = await searchEngine.state
        }
        let count = state.replies.reduce(0) { $0 + $1.files.count }
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            items[i].lastRun = Date()
            items[i].lastResultCount = count
        }
        save()
        publish()
    }

    private func loop() async {
        while !Task.isCancelled {
            let seconds = interval
            do {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            } catch { return }
            if Task.isCancelled { return }
            await runAll()
        }
    }

    private func consumeEvents() async {
        let stream = await server.makeEventStream()
        for await event in stream {
            if Task.isCancelled { return }
            if case .wishlistInterval(let seconds) = event, seconds > 0 {
                interval = seconds
                loopTask?.cancel()
                loopTask = Task { await self.loop() }
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }

    private func publish() {
        updatesContinuation.yield(items)
    }
}