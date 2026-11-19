import SwiftUI
import SoulseekCore
import SoulseekProtocol

/// Chat tab: private messages + group chats (rooms). Groups are created by
/// joining a new name; music is shared as tappable download cards (AD-12).
struct ChatView: View {
    @Bindable var model: ChatModel
    let appModel: AppModel

    @State private var showNewPM = false
    @State private var showNewRoom = false
    @State private var showRooms = false
    @State private var showBuddies = false
    @State private var showManage = false
    @State private var showNewPrivateRoom = false
    @State private var privateRoomName = ""
    @State private var newPeer = ""
    @State private var newRoomName = ""
    @State private var navTarget: String?

    var body: some View {
        ZStack {
            GlassBackground()
            List {
                ForEach(model.conversations) { conv in
                    NavigationLink {
                        ConversationView(chatModel: model, appModel: appModel, id: conv.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: conv.kind == .room ? "person.3.fill" : "person.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(conv.name)
                                    .font(.subheadline)
                                Text(preview(conv))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .accessibilityIdentifier("conversationRow")
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.bottom, 64, for: .scrollContent)
            .overlay {
                if model.conversations.isEmpty {
                    ContentUnavailableView(
                        "No chats",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Start a private message or create a group with +.")
                    )
                }
            }
        }
        .navigationTitle("Chat")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showNewPM = true } label: {
                        Label("New message", systemImage: "person")
                    }
                    .accessibilityIdentifier("newPMOption")
                    Button { showNewRoom = true } label: {
                        Label("Create / join group", systemImage: "person.3")
                    }
                    .accessibilityIdentifier("newRoomOption")
                    Button { showNewPrivateRoom = true } label: {
                        Label("Create private group", systemImage: "lock")
                    }
                    .accessibilityIdentifier("newPrivateRoomOption")
                    Button { model.refreshRoomList(); showRooms = true } label: {
                        Label("Browse groups", systemImage: "list.bullet")
                    }
                    .accessibilityIdentifier("browseRoomsOption")
                    Button { showBuddies = true } label: {
                        Label("Buddies", systemImage: "person.2")
                    }
                    .accessibilityIdentifier("buddiesOption")
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("newChatButton")
            }
        }
        .alert("New message", isPresented: $showNewPM) {
            TextField("Username", text: $newPeer)
                .accessibilityIdentifier("peerField")
            Button("Cancel", role: .cancel) {}
            Button("Start") {
                let u = newPeer.trimmingCharacters(in: .whitespaces)
                if !u.isEmpty { navTarget = "pm:\(u)" }
                newPeer = ""
            }
        }
        .alert("Create or join a group", isPresented: $showNewRoom) {
            TextField("Group name (max 24 chars)", text: $newRoomName)
                .accessibilityIdentifier("roomNameField")
            Button("Cancel", role: .cancel) {}
            Button("Join / Create") {
                let n = newRoomName.trimmingCharacters(in: .whitespaces)
                if ChatEngine.isValidRoomName(n) {
                    model.joinRoom(n)
                    navTarget = "room:\(n)"
                }
                newRoomName = ""
            }
            .accessibilityIdentifier("createRoomButton")
        } message: {
            Text("A new name creates a new public group. For an invite-only group use + → Create private group. Share music with the ♪ button.")
        }
        .alert("Create a private group", isPresented: $showNewPrivateRoom) {
            TextField("Group name (max 24 chars)", text: $privateRoomName)
                .accessibilityIdentifier("privateRoomNameField")
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let n = privateRoomName.trimmingCharacters(in: .whitespaces)
                if ChatEngine.isValidRoomName(n) {
                    model.joinRoom(n, private: true)
                    navTarget = "room:\(n)"
                }
                privateRoomName = ""
            }
            .accessibilityIdentifier("createPrivateRoomButton")
        } message: {
            Text("Invite-only: you own the group and invite members from its Manage screen. Invited friends join automatically.")
        }
        .alert("Group error", isPresented: Binding(
            get: { model.roomError != nil },
            set: { if !$0 { model.clearRoomError() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.roomError ?? "")
        }
        .sheet(isPresented: $showRooms) {
            RoomBrowserSheet(model: model) { room in
                model.joinRoom(room)
                showRooms = false
                navTarget = "room:\(room)"
            }
        }
        .sheet(isPresented: $showBuddies) {
            BuddiesSheet(appModel: appModel)
        }
        .navigationDestination(isPresented: Binding(
            get: { navTarget != nil },
            set: { if !$0 { navTarget = nil } }
        )) {
            if let id = navTarget {
                ConversationView(chatModel: model, appModel: appModel, id: id)
            }
        }
    }

    private func preview(_ conv: ChatEngine.Conversation) -> String {
        guard let last = conv.messages.last else {
            return conv.kind == .room ? "\(conv.members.count) members" : "No messages yet"
        }
        if let card = last.card { return "♪ \(card.title)" }
        if last.isSystem { return last.text }
        return (last.isMine ? "You: " : "") + last.text
    }
}

struct ConversationView: View {
    let chatModel: ChatModel
    let appModel: AppModel
    let id: String

    @State private var draft = ""
    @State private var showSharePicker = false
    @State private var showTickerAlert = false
    @State private var tickerText = ""
    @State private var showManage = false
    @State private var hadConv = false

    private var conv: ChatEngine.Conversation? { chatModel.conversation(id) }
    private var isRoom: Bool { id.hasPrefix("room:") }
    private var isPrivateRoom: Bool { isRoom && conv?.isPrivate == true }
    private var name: String {
        conv?.name ?? String(id.dropFirst(isRoom ? 5 : 3))
    }

    var body: some View {
        ZStack {
            GlassBackground()
            VStack(spacing: 0) {
                if let conv, !conv.tickers.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(conv.tickers.sorted(by: { $0.key < $1.key }), id: \.key) { user, message in
                            Text("\(user): \(message)")
                                .font(.caption2)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                    .padding(.horizontal)
                    .padding(.top, 4)
                    .accessibilityIdentifier("tickerWall")
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(conv?.messages ?? []) { msg in
                                MessageBubble(message: msg) { card in
                                    appModel.searchModel.download(path: card.path, size: card.size, from: card.username)
                                }
                                .id(msg.id)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: conv?.messages.count) { _, _ in
                        if let last = conv?.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                composer
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: conv?.id) { _, newID in
            // Pop when the room disappears (left, disbanded, membership revoked)
            // — but not before the initial join reply arrives.
            if newID != nil {
                hadConv = true
            } else if hadConv {
                dismiss()
            }
        }
        .toolbar {
            if isRoom {
                if isPrivateRoom {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Manage") {
                            showManage = true
                        }
                        .accessibilityIdentifier("manageRoomButton")
                    }
                }
                // One menu for the rest — 4 separate toolbar buttons overflow
                // into "More" on phones and can hide Manage entirely.
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Ticker") {
                            tickerText = conv?.tickers[appModel.username] ?? ""
                            showTickerAlert = true
                        }
                        .accessibilityIdentifier("setTickerButton")
                        Button("Search room") {
                            let q = appModel.searchModel.queryText.trimmingCharacters(in: .whitespaces)
                            appModel.searchModel.searchInRoom(name, query: q.isEmpty ? "*" : q)
                            appModel.selectedTab = 0
                        }
                        .accessibilityIdentifier("searchRoomButton")
                        Button("Leave", role: .destructive) {
                            if isPrivateRoom {
                                chatModel.leavePrivateRoom(name)
                            } else {
                                chatModel.leaveRoom(name)
                            }
                            dismiss()
                        }
                        .accessibilityIdentifier("leaveRoomButton")
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("roomActionsMenu")
                }
            }
        }
        .sheet(isPresented: $showManage) {
            PrivateRoomSheet(chatModel: chatModel, appModel: appModel, room: name)
        }
        .sheet(isPresented: $showSharePicker) {
            SharePickerSheet(groups: appModel.searchModel.groups) { file, username in
                chatModel.share(MusicCard(username: username, path: file.path, size: file.size), to: id)
                showSharePicker = false
            }
        }
        .alert("Room ticker", isPresented: $showTickerAlert) {
            TextField("Your wall message", text: $tickerText)
                .accessibilityIdentifier("tickerField")
            Button("Set") {
                chatModel.setTicker(in: name, message: tickerText.trimmingCharacters(in: .whitespaces))
            }
            .accessibilityIdentifier("tickerSetButton")
            Button("Remove") { chatModel.setTicker(in: name, message: "") }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A short message pinned to the room wall for everyone to see.")
        }
    }

    @Environment(\.dismiss) private var dismiss

    private var composer: some View {
        HStack(spacing: 10) {
            Button { showSharePicker = true } label: {
                Image(systemName: "music.note")
                    .font(.title3)
                    .foregroundStyle(.orange)
            }
            .accessibilityIdentifier("shareMusicButton")
            TextField("Message", text: $draft)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassEffect(.regular.interactive(), in: .capsule)
                .accessibilityIdentifier("messageField")
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("sendButton")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if isRoom {
            chatModel.say(in: name, text: text)
        } else {
            chatModel.sendPM(to: name, text: text)
        }
        draft = ""
    }
}

struct MessageBubble: View {
    let message: ChatEngine.ChatMessage
    let onDownload: (MusicCard) -> Void

    var body: some View {
        if message.isSystem {
            Text(message.text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        } else if let card = message.card {
            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 2) {
                if !message.isMine {
                    Text(message.sender)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                MusicCardRow(card: card) { onDownload(card) }
            }
            .frame(maxWidth: .infinity, alignment: message.isMine ? .trailing : .leading)
        } else {
            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 2) {
                if !message.isMine {
                    Text(message.sender)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(message.text)
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassEffect(.regular.tint(message.isMine ? Color.orange.opacity(0.35) : .clear), in: .rect(cornerRadius: 16))
            }
            .frame(maxWidth: .infinity, alignment: message.isMine ? .trailing : .leading)
            .accessibilityIdentifier("messageBubble")
        }
    }
}

struct MusicCardRow: View {
    let card: MusicCard
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .font(.subheadline)
                    .lineLimit(2)
                    .accessibilityIdentifier("musicCard")
                Text("\(card.username) · \(String(format: "%.1f MB", Double(card.size) / 1_048_576))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onDownload) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("cardDownloadButton")
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

/// Pick a file from the current search results to share into the chat.
struct SharePickerSheet: View {
    let groups: [SearchModel.ResultGroup]
    let onSelect: (FileEntry, String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()
                List {
                    ForEach(groups) { group in
                        Section(group.username) {
                            ForEach(group.files.prefix(20), id: \.path) { file in
                                Button {
                                    onSelect(file, group.username)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.filename)
                                            .font(.subheadline)
                                            .lineLimit(1)
                                        Text("\(file.ext.uppercased()) · \(String(format: "%.1f MB", Double(file.size) / 1_048_576))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .accessibilityIdentifier("shareFileRow")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .overlay {
                    if groups.isEmpty {
                        ContentUnavailableView(
                            "Nothing to share yet",
                            systemImage: "magnifyingglass",
                            description: Text("Search for music first, then share results into the chat.")
                        )
                    }
                }
            }
            .navigationTitle("Share music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct RoomBrowserSheet: View {
    let model: ChatModel
    let onJoin: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private func matches(_ name: String) -> Bool {
        searchText.isEmpty || name.localizedCaseInsensitiveContains(searchText)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Search groups…", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("roomSearchField")
                }
                let myRooms = model.conversations.filter { $0.kind == .room && matches($0.name) }
                if !myRooms.isEmpty {
                    Section("Your groups") {
                        ForEach(myRooms) { conv in
                            Button { onJoin(conv.name) } label: {
                                HStack {
                                    Text(conv.name)
                                    if conv.isPrivate {
                                        Image(systemName: "lock.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("\(conv.members.count)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier("myGroupRow")
                        }
                    }
                }
                if let list = model.roomList {
                    let publicRooms = list.publicRooms
                        .filter { matches($0.name) }
                        .sorted { $0.userCount > $1.userCount }
                    if !publicRooms.isEmpty {
                        Section("Public groups") {
                            ForEach(publicRooms, id: \.name) { room in
                                Button { onJoin(room.name) } label: {
                                    HStack {
                                        Text(room.name)
                                        Spacer()
                                        Text("\(room.userCount)")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .accessibilityIdentifier("roomRow")
                            }
                        }
                    }
                    let myPrivate = list.ownedPrivateRooms.filter { matches($0.name) }
                    if !myPrivate.isEmpty {
                        Section("Your private groups") {
                            ForEach(myPrivate, id: \.name) { room in
                                Button { onJoin(room.name) } label: {
                                    HStack {
                                        Image(systemName: "lock.fill").font(.caption2)
                                        Text(room.name)
                                        Spacer()
                                        Text("\(room.userCount)").foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    let invited = list.privateRooms.filter { matches($0.name) }
                    if !invited.isEmpty {
                        Section("Private groups you're in") {
                            ForEach(invited, id: \.name) { room in
                                Button { onJoin(room.name) } label: {
                                    HStack {
                                        Image(systemName: "lock.fill").font(.caption2)
                                        Text(room.name)
                                        Spacer()
                                        Text("\(room.userCount)").foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    let operated = list.operatedRooms.filter { matches($0) }
                    if !operated.isEmpty {
                        Section("Groups you operate") {
                            ForEach(operated, id: \.self) { room in
                                Button { onJoin(room) } label: { Text(room) }
                            }
                        }
                    }
                } else {
                    ProgressView("Loading groups…")
                }
                Section {
                    Text("The server only lists groups with 5+ members. New groups are invisible here until people join — create a private group (+ → Create/join group → Private) and invite friends from its Manage screen.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Groups")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}