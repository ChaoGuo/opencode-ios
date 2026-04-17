import SwiftUI
import AVFoundation
import PhotosUI

struct ChatView: View {
    let sessionID: String

    @State private var vm = AppViewModel.shared
    @State private var inputText = ""
    @State private var showModelPicker = false
    @FocusState private var inputFocused: Bool
    #if os(iOS)
    @State private var voiceRecorder = VoiceRecorderService.shared
    @State private var isRecording = false
    @State private var isVoiceMode = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    #endif

    private var session: Session? { vm.sessions.first { $0.id == sessionID } }
    private var envelopes: [MessageEnvelope] { vm.envelopes[sessionID] ?? [] }
    private var isGenerating: Bool { vm.generatingSessions.contains(sessionID) }
    private var isLoading: Bool { vm.loadingMessages[sessionID] == true }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if isLoading {
                        ProgressView()
                            .padding(.top, 60)
                    } else if envelopes.isEmpty && !isGenerating {
                        EmptyChatView(sessionID: sessionID)
                    } else {
                        ForEach(chatRows(envelopes)) { row in
                            switch row {
                            case .timeDivider(_, let text):
                                TimeDividerView(text: text)
                            case .message(let envelope):
                                MessageView(envelope: envelope)
                            }
                        }
                        if isGenerating {
                            HStack {
                                TypingIndicatorView()
                                    .padding(.horizontal)
                                    .padding(.vertical, 8)
                                Spacer()
                            }
                            .id("typing")
                        }
                        Color.clear
                            .frame(height: 8)
                            .id("bottom")
                    }
                }
                .padding(.top, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: envelopes.count) { scrollToBottom(proxy) }
            .onChange(of: isGenerating) { if isGenerating { scrollToBottom(proxy) } }
            .onChange(of: inputFocused) { if inputFocused { scrollToBottom(proxy) } }
            .task(id: sessionID) {
                await vm.loadMessages(for: sessionID)
                await settleBottom(proxy)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            inputBar
        }
        .navigationTitle(session?.displayTitle ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ModelBadge(showPicker: $showModelPicker)
            }
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerView()
        }
    }

    /// Single-shot scroll to bottom; used by onChange handlers where the
    /// content has already settled (new message appended, focus gained, etc.).
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo("bottom", anchor: .bottom)
    }

    /// Multi-frame retry after async `loadMessages` — LazyVStack measures
    /// items lazily and MarkdownUI / code blocks / tool-call cells can change
    /// their rendered height after first layout. We keep nudging the scroll
    /// to the bottom over ~500ms so each retry uses the progressively more
    /// accurate content size. This is the fix for sessions with many messages
    /// and heavy content where the initial scroll lands on a stale height
    /// estimate and leaves the viewport above the true bottom.
    private func settleBottom(_ proxy: ScrollViewProxy) async {
        for delayMs in [0, 50, 120, 220, 350, 500] {
            if delayMs > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            }
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            // 图片预览
            if let image = selectedImage {
                HStack {
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        Button {
                            selectedImage = nil
                            selectedPhotoItem = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white)
                                .background(Color.black.opacity(0.5).clipShape(Circle()))
                        }
                        .offset(x: 6, y: -6)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            #endif

        HStack(alignment: .bottom, spacing: 8) {
            #if os(iOS)
            // 切换语音/文字模式按钮
            if !isGenerating {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isVoiceMode.toggle()
                        if isVoiceMode { inputFocused = false }
                    }
                } label: {
                    Image(systemName: isVoiceMode ? "keyboard" : "mic")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 36, height: 36)
                }
            }

            if isVoiceMode && !isGenerating {
                holdToTalkButton
            } else {
                TextField("Message...", text: $inputText, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .focused($inputFocused)
            }
            #else
            TextField("Message...", text: $inputText, axis: .vertical)
                .lineLimit(1...6)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .focused($inputFocused)
            #endif

            if isGenerating {
                Button {
                    Task { await vm.abort(sessionID: sessionID) }
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.red)
                }
            } else {
                #if os(iOS)
                let hasContent = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedImage != nil
                if !isVoiceMode && hasContent {
                    Button { sendMessage() } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(Color.accentColor)
                    }
                } else if !isVoiceMode {
                    // 图片选择按钮
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Image(systemName: "photo")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.secondary)
                            .frame(width: 36, height: 36)
                    }
                    .onChange(of: selectedPhotoItem) { _, item in
                        Task {
                            if let data = try? await item?.loadTransferable(type: Data.self),
                               let img = UIImage(data: data) {
                                selectedImage = img
                            }
                        }
                    }
                }
                #else
                if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button { sendMessage() } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                #endif
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        } // end VStack
        .background(.regularMaterial)
    }

    #if os(iOS)
    private var holdToTalkButton: some View {
        Text(isRecording ? "松开发送" : "按住说话")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(isRecording ? .white : .primary)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(isRecording ? Color.red : Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .scaleEffect(isRecording ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isRecording)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isRecording {
                            isRecording = true
                            Task { await voiceRecorder.startRecording() }
                        }
                    }
                    .onEnded { _ in
                        if isRecording {
                            isRecording = false
                            if let url = voiceRecorder.stopRecording() {
                                let duration = voiceRecorder.recordingDuration
                                Task {
                                    try? await Task.sleep(for: .milliseconds(300))
                                    await vm.sendAudio(sessionID: sessionID, fileURL: url, duration: duration)
                                }
                            }
                        }
                    }
            )
    }
    #endif

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        #if os(iOS)
        let image = selectedImage
        guard !text.isEmpty || image != nil else { return }
        inputText = ""
        selectedImage = nil
        selectedPhotoItem = nil
        Task {
            await vm.sendMessage(sessionID: sessionID, text: text, image: image)
        }
        #else
        guard !text.isEmpty else { return }
        inputText = ""
        Task {
            await vm.sendMessage(sessionID: sessionID, text: text, image: nil)
        }
        #endif
    }

    // MARK: - Time divider logic

    private func chatRows(_ envelopes: [MessageEnvelope]) -> [ChatRow] {
        // iMessage-style: always show divider above first message, then again
        // whenever the gap to the previous message exceeds the threshold.
        let gapThresholdMs: Double = 10 * 60 * 1000
        var rows: [ChatRow] = []
        var prevTimeMs: Double? = nil
        for env in envelopes {
            let t = env.info.time.created
            let showDivider = prevTimeMs.map { t - $0 >= gapThresholdMs } ?? true
            if showDivider {
                rows.append(.timeDivider(id: env.info.id, text: ChatView.formatDividerTime(t)))
            }
            rows.append(.message(env))
            prevTimeMs = t
        }
        return rows
    }

    private static func formatDividerTime(_ ms: Double) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        let cal = Calendar.current
        let now = Date()
        let time = timeFormatter.string(from: date)
        if cal.isDateInToday(date) { return "今天 \(time)" }
        if cal.isDateInYesterday(date) { return "昨天 \(time)" }
        if let days = cal.dateComponents([.day], from: date, to: now).day, days < 7 {
            return "\(weekdayFormatter.string(from: date)) \(time)"
        }
        if cal.isDate(date, equalTo: now, toGranularity: .year) {
            return shortDateFormatter.string(from: date)
        }
        return fullDateFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()
    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()
    private static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月d日 HH:mm"
        return f
    }()
}

private enum ChatRow: Identifiable {
    case timeDivider(id: String, text: String)
    case message(MessageEnvelope)

    var id: String {
        switch self {
        case .timeDivider(let id, _): return "div:\(id)"
        case .message(let env): return env.info.id
        }
    }
}

private struct TimeDividerView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }
}

// MARK: - Model Badge
struct ModelBadge: View {
    @Binding var showPicker: Bool
    @State private var settings = AppSettings.shared
    @State private var vm = AppViewModel.shared

    private var modelName: String {
        let id = settings.selectedModelID
        if id.isEmpty { return "Model" }
        return vm.availableModels.first { $0.id == id }?.name ?? id
    }

    var body: some View {
        Button { showPicker = true } label: {
            HStack(spacing: 4) {
                Text(modelName)
                    .font(.caption)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(.secondarySystemBackground))
            .clipShape(Capsule())
        }
        .foregroundStyle(.primary)
    }
}

// MARK: - Suggestion Button (extracted to help type checker)
private struct SuggestionButton: View {
    let text: String
    let icon: String
    let sessionID: String
    @State private var vm = AppViewModel.shared

    var body: some View {
        Button {
            Task { await vm.sendMessage(sessionID: sessionID, text: text) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.accentColor)
                Text(text)
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .padding(12)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .foregroundStyle(.primary)
    }
}

// MARK: - Typing Indicator
struct TypingIndicatorView: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 7, height: 7)
                    .scaleEffect(animating ? 1.3 : 0.7)
                    .animation(
                        .easeInOut(duration: 0.45)
                        .repeatForever()
                        .delay(Double(i) * 0.15),
                        value: animating
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .onAppear { animating = true }
        .onDisappear { animating = false }
    }
}

// MARK: - Empty chat state
struct EmptyChatView: View {
    let sessionID: String
    @State private var vm = AppViewModel.shared

    private let suggestions = [
        ("Explain this codebase", "magnifyingglass"),
        ("Fix bugs in my code", "wrench.and.screwdriver"),
        ("Write unit tests", "checkmark.shield"),
        ("Refactor for clarity", "arrow.triangle.2.circlepath"),
    ]

    var body: some View {
        VStack(spacing: 32) {
            Spacer(minLength: 60)

            VStack(spacing: 10) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor.opacity(0.7))
                Text("How can I help?")
                    .font(.title2.bold())
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(suggestions, id: \.0) { item in
                    SuggestionButton(text: item.0, icon: item.1, sessionID: sessionID)
                }
            }
            .padding(.horizontal)

            Spacer()
        }
    }
}
