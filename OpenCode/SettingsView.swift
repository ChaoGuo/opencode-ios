import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = AppSettings.shared
    @State private var vm = AppViewModel.shared
    @State private var testingConnection = false
    @State private var connectionResult: Bool?

    // Local edit state
    @State private var baseURL = ""
    @State private var username = ""
    @State private var password = ""

    // Cleanup state
    @State private var cleanupDays = 10
    @State private var showingCleanupAlert = false
    @State private var cleanupInProgress = false
    @State private var cleanupResult: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Server URL") {
                        TextField("http://localhost:4096", text: $baseURL)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Server")
                } footer: {
                    Text("The URL of your OpenCode server. Make sure CORS is enabled if accessing from a different origin.")
                }

                Section("Authentication") {
                    LabeledContent("Username") {
                        TextField("optional", text: $username)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Password") {
                        SecureField("optional", text: $password)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Text("Test Connection")
                            Spacer()
                            if testingConnection {
                                ProgressView()
                            } else if let result = connectionResult {
                                Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(result ? .green : .red)
                            }
                        }
                    }
                    .disabled(testingConnection)
                } footer: {
                    if let result = connectionResult {
                        Text(result ? "Connection successful" : "Connection failed — check your server URL and credentials")
                            .foregroundStyle(result ? .green : .red)
                    }
                }

                #if os(iOS)
                Section {
                    Toggle("New message alerts", isOn: Binding(
                        get: { settings.notificationsEnabled },
                        set: { newValue in
                            settings.notificationsEnabled = newValue
                            if newValue {
                                Task {
                                    let granted = await NotificationService.shared.requestAuthorizationIfNeeded()
                                    if !granted {
                                        settings.notificationsEnabled = false
                                    }
                                }
                            }
                        }
                    ))
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Alert me when the assistant finishes replying while the app is in the background. iOS decides how often to wake the app — typically every 15+ minutes, not realtime.")
                }
                #endif

                Section {
                    Stepper(value: $cleanupDays, in: 1...365) {
                        Text("Older than \(cleanupDays) days")
                    }
                    Button(role: .destructive) {
                        showingCleanupAlert = true
                    } label: {
                        HStack {
                            Text("Clean up old chats")
                            Spacer()
                            if cleanupInProgress {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(cleanupInProgress)
                } header: {
                    Text("Cleanup")
                } footer: {
                    if let cleanupResult {
                        Text(cleanupResult).foregroundStyle(.secondary)
                    } else {
                        Text("Delete chats last updated more than N days ago. Pinned chats are kept.")
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: "1.0.0")
                    Link("OpenCode on GitHub", destination: URL(string: "https://github.com/opencode-ai/opencode")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { saveAndDismiss() }
                        .bold()
                }
            }
            .onAppear {
                baseURL = settings.baseURL
                username = settings.username
                password = settings.password
            }
            .alert("Clean up old chats?", isPresented: $showingCleanupAlert) {
                Button("Delete", role: .destructive) {
                    Task { await runCleanup() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                let count = vm.sessionsOlderThan(days: cleanupDays).count
                if count == 0 {
                    Text("No chats older than \(cleanupDays) days.")
                } else {
                    Text("This will permanently delete \(count) chat\(count == 1 ? "" : "s") older than \(cleanupDays) days. Pinned chats are kept.")
                }
            }
        }
    }

    private func runCleanup() async {
        cleanupInProgress = true
        cleanupResult = nil
        let deleted = await vm.cleanupSessions(olderThanDays: cleanupDays)
        cleanupInProgress = false
        cleanupResult = deleted == 0
            ? "No chats to delete."
            : "Deleted \(deleted) chat\(deleted == 1 ? "" : "s")."
    }

    private func saveAndDismiss() {
        settings.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.password = password
        vm.reconnect()
        dismiss()
    }

    private func testConnection() async {
        // Apply current values for testing
        let saved = settings.baseURL
        settings.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.username = username
        settings.password = password

        testingConnection = true
        connectionResult = nil
        connectionResult = await APIService.shared.checkHealth()
        testingConnection = false

        // Restore if not saved
        settings.baseURL = saved
    }
}
