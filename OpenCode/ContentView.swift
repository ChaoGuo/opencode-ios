import SwiftUI

struct ContentView: View {
    @State private var vm = AppViewModel.shared
    @State private var selectedSessionID: String?
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @Binding var pendingSessionID: String?

    init(pendingSessionID: Binding<String?> = .constant(nil)) {
        self._pendingSessionID = pendingSessionID
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionListView(selectedSessionID: $selectedSessionID)
        } detail: {
            if let id = selectedSessionID {
                ChatView(sessionID: id)
                    .id(id) // re-create view when session changes
            } else {
                WelcomeDetailView()
            }
        }
        .sheet(isPresented: $vm.showSettings) {
            SettingsView()
        }
        .task {
            await vm.start()
        }
        .onChange(of: pendingSessionID) { _, newValue in
            guard let sid = newValue else { return }
            selectedSessionID = sid
            pendingSessionID = nil
        }
        .alert("Error", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }
}

// MARK: - Welcome detail (shown on iPad when no session selected)
struct WelcomeDetailView: View {
    @State private var vm = AppViewModel.shared

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("OpenCode")
                .font(.largeTitle.bold())

            Text("Select a session or create a new one to get started.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                Task {
                    if let session = await vm.createSession() {
                        // The session list will update via SSE or reload
                        _ = session
                    }
                }
            } label: {
                Label("New Chat", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}
