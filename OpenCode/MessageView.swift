import SwiftUI
import UIKit
import MarkdownUI

// MARK: - MessageView

// Server-push convention: a user-role message carrying a text part with this exact
// content is rendered assistant-style. Backend sets `ignored: true` on that part so
// it never enters LLM context.
private let systemPushMarker = "[[__OPENCODE_SYSTEM_PUSH__]]"

private extension MessageEnvelope {
    var isSystemPush: Bool {
        info.role == .user && parts.contains { $0.type == "text" && $0.text == systemPushMarker }
    }

    var withoutMarker: MessageEnvelope {
        MessageEnvelope(
            info: info,
            parts: parts.filter { !($0.type == "text" && $0.text == systemPushMarker) }
        )
    }
}

struct MessageView: View {
    let envelope: MessageEnvelope

    var body: some View {
        Group {
            if envelope.isSystemPush {
                AssistantMessageView(envelope: envelope.withoutMarker)
            } else if envelope.info.role == .user {
                UserMessageView(envelope: envelope)
            } else {
                AssistantMessageView(envelope: envelope)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

// MARK: - User message
struct UserMessageView: View {
    let envelope: MessageEnvelope

    private var rawText: String {
        envelope.parts.compactMap { p -> String? in
            p.type == "text" ? p.text : nil
        }.joined(separator: "\n")
    }

    /// 从用户消息文本里抽出由 file service 上传产生的图片 URL，剩余部分作为正文。
    /// 走文本而非 file part 是为了避开下游 provider（Kimi 等）不接受 URL 图片的限制。
    private var splitText: (imageURLs: [String], text: String) {
        let prefix = AppSettings.shared.fileServiceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return ([], rawText) }
        var images: [String] = []
        var lines: [String] = []
        for line in rawText.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix), trimmed.contains("/file/") {
                images.append(trimmed)
            } else {
                lines.append(line)
            }
        }
        return (images, lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var audioPart: MessagePart? {
        envelope.parts.first { $0.type == "file" && $0.mime?.hasPrefix("audio/") == true }
    }

    /// 老消息里以 file part 形式存储的图片，保留兼容渲染。
    private var legacyImageParts: [MessagePart] {
        envelope.parts.filter { $0.type == "file" && $0.mime?.hasPrefix("image/") == true }
    }

    var body: some View {
        let split = splitText
        HStack(alignment: .top) {
            Spacer(minLength: 60)
            if let audio = audioPart {
                #if os(iOS)
                AudioBubbleView(part: audio)
                #endif
            } else {
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(legacyImageParts, id: \.partID) { part in
                        DataImageView(urlString: part.url)
                            .frame(maxWidth: 220, maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    ForEach(split.imageURLs, id: \.self) { url in
                        DataImageView(urlString: url)
                            .frame(maxWidth: 220, maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    if !split.text.isEmpty {
                        Text(split.text)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

// MARK: - Assistant message
struct AssistantMessageView: View {
    let envelope: MessageEnvelope
    @State private var reasoningExpanded = true
    @State private var showCopied = false

    var body: some View {
        let isStreaming = envelope.info.time.completed == nil
        HStack(alignment: .top, spacing: 10) {
            // Avatar
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: "brain")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(envelope.parts, id: \.partID) { part in
                    PartView(part: part, isStreaming: isStreaming, reasoningExpanded: $reasoningExpanded)
                }

                if let info = envelope.info as MessageInfo?,
                   info.modelID != nil || (info.tokens?.output ?? 0) > 0 {
                    MessageFooterView(info: info, showCopied: $showCopied, envelope: envelope)
                }
            }

            Spacer(minLength: 16)
        }
    }
}

// MARK: - Part dispatcher
struct PartView: View {
    let part: MessagePart
    let isStreaming: Bool
    @Binding var reasoningExpanded: Bool

    var body: some View {
        partContent
    }

    @ViewBuilder
    private var partContent: some View {
        switch part.type {
        case "text":
            if let text = part.text, !text.isEmpty {
                if isStreaming {
                    StreamingMarkdownView(text: text)
                } else {
                    MarkdownTextView(text: text)
                }
            }
        case "reasoning":
            // reasoning parts use the "text" field too
            if let text = part.text, !text.isEmpty {
                ReasoningView(reasoning: text, isExpanded: $reasoningExpanded)
            }
        case "tool":
            ToolPartView(part: part)
        case "source-url":
            if let url = part.url {
                SourceURLView(url: url, title: part.title)
            }
        case "file":
            FilePartView(part: part)
        default:
            EmptyView()
        }
    }
}

// MARK: - Markdown text
struct MarkdownTextView: View {
    let text: String

    var body: some View {
        Markdown(text)
            .textSelection(.enabled)
            .markdownTheme(.chat)
            .markdownBlockStyle(\.codeBlock) { config in
                CodeBlockView(language: config.language, code: config.content)
            }
    }
}

// Streaming renderer. MarkdownUI re-parses the whole AST on every delta and
// blocks the main thread for long replies, so we use Foundation's native
// AttributedString markdown parser (inline-only, preserves whitespace) plus a
// fenced-code-block splitter that reuses CodeBlockView. Tradeoff: block-level
// constructs (headings, lists, tables) stay as literal text until the message
// completes and switches to MarkdownUI — those are the only things that pop.
struct StreamingMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(StreamingMarkdown.split(text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let content):
                    StreamingInlineText(raw: content)
                case .code(let lang, let content):
                    CodeBlockView(language: lang, code: content)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StreamingInlineText: View {
    let raw: String

    var body: some View {
        // Pathologically long streaming text: skip the parse, fall back to
        // plain Text. 50k chars is well past any realistic inline segment.
        if raw.count > 50_000 {
            Text(raw)
                .font(.system(size: 16))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        } else {
            Text(StreamingMarkdown.parseInline(raw))
                .font(.system(size: 16))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

enum StreamingMarkdownSegment {
    case text(String)
    case code(language: String?, content: String)
}

enum StreamingMarkdown {
    static func parseInline(_ raw: String) -> AttributedString {
        let balanced = balanceTrailingInline(raw)
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let attr = try? AttributedString(markdown: balanced, options: options) {
            return attr
        }
        return AttributedString(raw)
    }

    // Splits on ``` fences so in-progress code blocks render with the same
    // framed CodeBlockView as the completed state — no raw backticks on screen.
    // A trailing unclosed fence is treated as a still-streaming code segment.
    static func split(_ text: String) -> [StreamingMarkdownSegment] {
        var segments: [StreamingMarkdownSegment] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        var textBuf: [String] = []

        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if !textBuf.isEmpty {
                    segments.append(.text(textBuf.joined(separator: "\n")))
                    textBuf.removeAll()
                }
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                i += 1
                var codeLines: [String] = []
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces) == "```" {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                segments.append(.code(
                    language: lang.isEmpty ? nil : lang,
                    content: codeLines.joined(separator: "\n")
                ))
            } else {
                textBuf.append(lines[i])
                i += 1
            }
        }
        if !textBuf.isEmpty {
            segments.append(.text(textBuf.joined(separator: "\n")))
        }
        return segments
    }

    // Appends a matching closer for an unclosed trailing ** or ` so the word
    // being typed renders bold / monospace immediately instead of flickering
    // as the delimiter characters arrive. Best-effort: assumes the unmatched
    // opener is at the end, which is the overwhelming common case.
    static func balanceTrailingInline(_ text: String) -> String {
        let doubleStar = text.components(separatedBy: "**").count - 1
        let backtick = text.filter { $0 == "`" }.count

        let needsStar = doubleStar % 2 == 1
        let needsTick = backtick % 2 == 1

        if !needsStar && !needsTick { return text }

        // Markdown requires the closer to sit against non-whitespace, so insert
        // it before any trailing whitespace rather than at endIndex.
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)].isWhitespace {
            end = text.index(before: end)
        }

        var closer = ""
        if needsTick { closer += "`" }
        if needsStar { closer += "**" }

        var result = text
        result.insert(contentsOf: closer, at: end)
        return result
    }
}

private extension Theme {
    static let chat = Theme()
        .text {
            ForegroundColor(.primary)
            FontSize(16)
        }
        .heading1 { config in
            config.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 12, bottom: 6)
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(.em(1.2))
                }
        }
        .heading2 { config in
            config.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 10, bottom: 6)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.1))
                }
        }
        .heading3 { config in
            config.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 8, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.0))
                }
        }
        .paragraph { config in
            config.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.25))
                .markdownMargin(top: 0, bottom: 10)
        }
        .blockquote { config in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.4))
                    .relativeFrame(width: .em(0.2))
                config.label
                    .markdownTextStyle { ForegroundColor(.secondary) }
                    .relativePadding(.horizontal, length: .em(1))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .listItem { config in
            config.label
                .markdownMargin(top: .em(0.2))
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.9))
            BackgroundColor(Color(.secondarySystemBackground))
        }
        .strong {
            FontWeight(.semibold)
        }
        .emphasis {
            FontStyle(.italic)
        }
        .link {
            ForegroundColor(.accentColor)
        }
}

// MARK: - Code Block
struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(.tertiarySystemBackground))

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.trimmingCharacters(in: .newlines))
                    .font(.system(.caption, design: .monospaced))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator), lineWidth: 0.5))
    }
}

// MARK: - Reasoning
struct ReasoningView: View {
    let reasoning: String
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.caption)
                    Text("Reasoning")
                        .font(.caption.bold())
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(Color.orange)
            }

            if isExpanded {
                Divider()
                Text(reasoning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .textSelection(.enabled)
            }
        }
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.3), lineWidth: 0.5))
    }
}

// MARK: - Tool Part
struct ToolPartView: View {
    let part: MessagePart
    @State private var expanded = false

    private var status: String { part.state?.status ?? "running" }

    private var stateIcon: String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "error": return "xmark.circle.fill"
        default: return "arrow.clockwise"
        }
    }

    private var stateColor: Color {
        switch status {
        case "completed": return .green
        case "error": return .red
        default: return .blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    if status == "running" {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Image(systemName: stateIcon)
                            .foregroundStyle(stateColor)
                    }
                    Text(part.tool ?? "Tool")
                        .font(.caption.bold())
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(.primary)
            }

            if expanded, let state = part.state {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    if let input = state.input {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Input").font(.caption2.bold()).foregroundStyle(.secondary)
                            Text(input.prettyJSON)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    if let output = state.output {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Output").font(.caption2.bold()).foregroundStyle(.secondary)
                            Text(output.prettyJSON)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(12)
            }
        }
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(stateColor.opacity(0.3), lineWidth: 0.5))
    }
}

// MARK: - Data URL Image (supports data: and http: URLs)
struct DataImageView: View {
    let urlString: String?
    @State private var uiImage: UIImage? = nil
    @State private var loaded = false
    @State private var showPreview = false

    var body: some View {
        Group {
            if let img = uiImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
            } else if loaded {
                Image(systemName: "photo").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if uiImage != nil { showPreview = true }
        }
        .fullScreenCover(isPresented: $showPreview) {
            ImagePreviewView(uiImage: uiImage) {
                showPreview = false
            }
        }
        .task(id: urlString) {
            guard !loaded else { return }
            guard let urlString else { loaded = true; return }

            if urlString.hasPrefix("data:") {
                let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                    guard let commaIdx = urlString.firstIndex(of: ",") else { return nil }
                    let b64 = String(urlString[urlString.index(after: commaIdx)...])
                    guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return nil }
                    return UIImage(data: data)
                }.value
                uiImage = img
                loaded = true
                return
            }

            if urlString.hasPrefix("http"), let url = URL(string: urlString) {
                let data: Data? = await Task.detached(priority: .userInitiated) { () -> Data? in
                    do {
                        let (data, _) = try await URLSession.shared.data(from: url)
                        print("[DataImageView] http load success: \(url.absoluteString.prefix(80))...")
                        return data
                    } catch {
                        NSLog("[DataImageView] http load failed for \(url.absoluteString.prefix(80)): \(error)")
                        return nil
                    }
                }.value
                if Task.isCancelled { return }
                if let data {
                    uiImage = UIImage(data: data)
                } else if let cached = APIService.cachedImageData(for: urlString) {
                    uiImage = UIImage(data: cached)
                    print("[DataImageView] fallback cache hit")
                } else {
                    print("[DataImageView] fallback cache miss")
                }
                loaded = true
                return
            }

            loaded = true
        }
    }
}

// MARK: - Image Preview (fullscreen zoom/pan)
struct ImagePreviewView: View {
    let uiImage: UIImage?
    let onDismiss: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            imageView
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = max(1.0, min(lastScale * value, 6.0))
                        }
                        .onEnded { _ in
                            lastScale = scale
                            if scale <= 1.0 {
                                withAnimation(.spring()) {
                                    offset = .zero
                                    lastOffset = .zero
                                }
                            }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            if scale > 1.0 {
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                        }
                        .onEnded { _ in
                            lastOffset = offset
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring()) {
                        if scale > 1.0 {
                            scale = 1.0; lastScale = 1.0
                            offset = .zero; lastOffset = .zero
                        } else {
                            scale = 2.5; lastScale = 2.5
                        }
                    }
                }
                .onTapGesture { onDismiss() }

            VStack {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white, .black.opacity(0.4))
                    }
                    .padding()
                }
                Spacer()
            }
        }
        .statusBarHidden()
    }

    @ViewBuilder
    private var imageView: some View {
        if let img = uiImage {
            Image(uiImage: img).resizable().scaledToFit()
        }
    }
}

// MARK: - File Part
struct FilePartView: View {
    let part: MessagePart

    var body: some View {
        if part.mime?.hasPrefix("audio/") == true {
            #if os(iOS)
            AudioBubbleView(part: part)
            #endif
        } else if part.mime?.hasPrefix("image/") == true {
            DataImageView(urlString: part.url)
                .frame(maxHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            fileIcon
        }
    }

    private var fileIcon: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill")
            Text(part.filename ?? part.url ?? "File")
                .font(.caption).lineLimit(1)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Audio Bubble
#if os(iOS)
struct AudioBubbleView: View {
    let part: MessagePart
    @State private var audioPlayer = AudioPlayerService.shared

    // 从文件名解析时长，格式：voice_5s_timestamp.m4a
    private var duration: Int {
        guard let filename = part.filename else { return 0 }
        let name = (filename as NSString).deletingPathExtension
        let parts = name.components(separatedBy: "_")
        for p in parts {
            if p.hasSuffix("s"), let seconds = Int(p.dropLast()) {
                return seconds
            }
        }
        return 0
    }

    private var filename: String { part.filename ?? "" }
    private var isPlaying: Bool { audioPlayer.playingFilename == filename && audioPlayer.isPlaying }

    // 气泡宽度随时长缩放，最小120pt，最大220pt
    private var bubbleWidth: CGFloat {
        let base: CGFloat = 120
        let perSecond: CGFloat = 8
        return min(base + CGFloat(duration) * perSecond, 220)
    }

    // 波形条数随时长缩放
    private var barCount: Int { max(4, min(duration + 3, 16)) }

    var body: some View {
        Button {
            if let dataURL = part.url {
                audioPlayer.play(dataURL: dataURL, filename: filename)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 20)

                // 波形条
                HStack(spacing: 2) {
                    ForEach(0..<barCount, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .frame(width: 3, height: barHeight(index: i))
                            .opacity(isPlaying ? 1.0 : 0.7)
                    }
                }
                .animation(isPlaying ? .easeInOut(duration: 0.4).repeatForever() : .default, value: isPlaying)

                Spacer(minLength: 0)

                Text(duration > 0 ? "\(duration)\"" : "")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(width: bubbleWidth)
            .background(Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    private func barHeight(index: Int) -> CGFloat {
        // 中间高两侧低，模拟波形
        let heights: [CGFloat] = [10, 16, 22, 18, 26, 20, 14, 24, 18, 12, 22, 16, 20, 14, 18, 10]
        return heights[index % heights.count]
    }
}
#endif

// MARK: - Source URL
struct SourceURLView: View {
    let url: String
    let title: String?

    var body: some View {
        if let link = URL(string: url) {
            Link(destination: link) {
                HStack(spacing: 6) {
                    Image(systemName: "link").font(.caption)
                    Text(title ?? url).font(.caption).lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(Color.accentColor)
            }
        }
    }
}

// MARK: - Message Footer
struct MessageFooterView: View {
    let info: MessageInfo
    @Binding var showCopied: Bool
    let envelope: MessageEnvelope

    private var fullText: String {
        envelope.parts.compactMap { p -> String? in
            (p.type == "text" || p.type == "reasoning") ? p.text : nil
        }.joined(separator: "\n\n")
    }

    var body: some View {
        HStack(spacing: 10) {
            if let modelID = info.modelID {
                Text(modelID.split(separator: "/").last.map(String.init) ?? modelID)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let cost = info.cost, cost > 0 {
                Text(String(format: "$%.4f", cost))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let tokens = info.tokens {
                let total = tokens.input + tokens.output
                if total > 0 {
                    Text("\(total) tokens")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Button {
                UIPasteboard.general.string = fullText
                showCopied = true
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    showCopied = false
                }
            } label: {
                Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
