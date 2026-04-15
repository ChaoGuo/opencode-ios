import SwiftUI

struct SessionListView: View {
    @Binding var selectedSessionID: String?
    @State private var vm = AppViewModel.shared
    @State private var showingDeleteAlert = false
    @State private var sessionToDelete: String?

    var body: some View {
        List(selection: $selectedSessionID) {
            ForEach(vm.sessions) { session in
                NavigationLink(value: session.id) {
                    SessionRow(
                        session: session,
                        isGenerating: vm.generatingSessions.contains(session.id),
                        isPinned: vm.isPinned(session.id)
                    )
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        vm.togglePin(session.id)
                    } label: {
                        if vm.isPinned(session.id) {
                            Label("Unpin", systemImage: "pin.slash.fill")
                        } else {
                            Label("Pin", systemImage: "pin.fill")
                        }
                    }
                    .tint(.orange)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        sessionToDelete = session.id
                        showingDeleteAlert = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        let session = await vm.createSession()
                        if let session {
                            selectedSessionID = session.id
                        }
                    }
                } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(vm.sseConnected ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Button {
                        vm.showSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
        }
        .overlay {
            if vm.isLoadingInitial {
                ProgressView()
            } else if vm.sessions.isEmpty {
                EmptySessionsView()
            }
        }
        .refreshable {
            await vm.loadSessions()
        }
        .alert("Delete Chat?", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) {
                if let id = sessionToDelete {
                    if selectedSessionID == id { selectedSessionID = nil }
                    Task { await vm.deleteSession(id: id) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete this chat session.")
        }
    }
}

// MARK: - Session Row
struct SessionRow: View {
    let session: Session
    let isGenerating: Bool
    let isPinned: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                if isGenerating {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.accentColor)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(session.displayTitle)
                        .font(.body)
                        .lineLimit(1)
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                if let time = session.time {
                    Text(Date(timeIntervalSince1970: (time.updated ?? time.created) / 1000).formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Empty state
struct EmptySessionsView: View {
    @State private var vm = AppViewModel.shared

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Chats Yet")
                .font(.headline)
            Text("Tap the compose button to start a new chat.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
