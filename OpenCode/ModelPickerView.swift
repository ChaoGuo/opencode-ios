import SwiftUI

struct ModelPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var vm = AppViewModel.shared
    @State private var settings = AppSettings.shared
    @State private var searchText = ""
    @State private var customModelID = ""
    @State private var showCustomEntry = false

    private var recentModels: [AvailableModel] {
        settings.recentModelIDs.compactMap { id in
            vm.availableModels.first { $0.id == id }
        }
    }

    private var grouped: [(String, [AvailableModel])] {
        let filtered = searchText.isEmpty
            ? vm.availableModels
            : vm.availableModels.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.id.localizedCaseInsensitiveContains(searchText)
                || $0.providerName.localizedCaseInsensitiveContains(searchText)
            }
        let byProvider = Dictionary(grouping: filtered) { $0.providerName }
        return byProvider.sorted { $0.key < $1.key }
    }

    var body: some View {
        NavigationStack {
            List {
                if grouped.isEmpty && !searchText.isEmpty {
                    Section {
                        Button("Use \"\(searchText)\" as model ID") {
                            settings.selectedModelID = searchText
                            dismiss()
                        }
                    }
                }

                if searchText.isEmpty && !recentModels.isEmpty {
                    Section("Recent") {
                        ForEach(recentModels) { model in
                            modelRow(model)
                        }
                    }
                }

                ForEach(grouped, id: \.0) { provider, models in
                    Section(provider) {
                        ForEach(models) { model in
                            modelRow(model)
                        }
                    }
                }

                Section {
                    Button {
                        showCustomEntry = true
                    } label: {
                        Label("Enter model ID manually", systemImage: "keyboard")
                    }
                }
            }
            .navigationTitle("Select Model")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search models")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Custom Model ID", isPresented: $showCustomEntry) {
                TextField("model-id", text: $customModelID)
                    .autocorrectionDisabled()
                Button("Use") {
                    if !customModelID.isEmpty {
                        settings.selectedModelID = customModelID
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter the exact model ID you want to use.")
            }
            .overlay {
                if vm.availableModels.isEmpty {
                    ContentUnavailableView(
                        "No Models",
                        systemImage: "cpu",
                        description: Text("Configure your server in Settings to load available models.")
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ model: AvailableModel) -> some View {
        Button {
            settings.recordRecentModel(model.id)
            settings.selectedModelID = model.id
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .foregroundStyle(.primary)
                    Text(model.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if settings.selectedModelID == model.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}
