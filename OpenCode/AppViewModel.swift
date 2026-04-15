import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

@Observable
@MainActor
final class AppViewModel {
    static let shared = AppViewModel()

    var sessions: [Session] = []
    // Key: sessionID, Value: array of (info, parts)
    var envelopes: [String: [MessageEnvelope]] = [:]
    var loadingMessages: [String: Bool] = [:]
    var generatingSessions: Set<String> = []
    var availableModels: [AvailableModel] = []
    var sseConnected = false
    var showSettings = false
    var isLoadingInitial = true
    var errorMessage: String?
    var pinnedSessionIDs: Set<String> = []

    private let api = APIService.shared
    private let sse = SSEService.shared
    private let decoder = JSONDecoder()
    private let pinnedDefaultsKey = "pinnedSessionIDs"

    private init() {
        if let stored = UserDefaults.standard.array(forKey: pinnedDefaultsKey) as? [String] {
            pinnedSessionIDs = Set(stored)
        }
        sse.onConnected = { [weak self] connected in
            self?.sseConnected = connected
        }
        sse.onEnvelope = { [weak self] data in
            self?.handleRawEnvelope(data)
        }
    }

    // MARK: - Lifecycle
    func start() async {
        isLoadingInitial = true
        sse.connect()
        async let s: () = loadSessions()
        async let m: () = loadModels()
        _ = await (s, m)
        isLoadingInitial = false
    }

    func reconnect() {
        sse.disconnect()
        Task { await start() }
    }

    // MARK: - Data Loading
    func loadSessions() async {
        do {
            let list = try await api.getSessions()
            sessions = list
            sortSessionsByRecency()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func recencyKey(_ s: Session) -> Double {
        s.time?.updated ?? s.time?.created ?? 0
    }

    func isPinned(_ sessionID: String) -> Bool {
        pinnedSessionIDs.contains(sessionID)
    }

    func togglePin(_ sessionID: String) {
        if pinnedSessionIDs.contains(sessionID) {
            pinnedSessionIDs.remove(sessionID)
        } else {
            pinnedSessionIDs.insert(sessionID)
        }
        UserDefaults.standard.set(Array(pinnedSessionIDs), forKey: pinnedDefaultsKey)
        sortSessionsByRecency()
    }

    private func sortSessionsByRecency() {
        sessions.sort {
            let p0 = pinnedSessionIDs.contains($0.id)
            let p1 = pinnedSessionIDs.contains($1.id)
            if p0 != p1 { return p0 }
            return recencyKey($0) > recencyKey($1)
        }
    }

    func loadModels() async {
        do {
            let providers = try await api.getProviders()
            var models: [AvailableModel] = []
            for provider in providers {
                let providerModels: [String: ModelInfo] = provider.models ?? [:]
                for (_, model) in providerModels {
                    models.append(AvailableModel(
                        id: model.id,
                        name: model.name ?? model.id,
                        providerID: provider.id,
                        providerName: provider.name ?? provider.id
                    ))
                }
            }
            availableModels = models.sorted { $0.name < $1.name }
        } catch {
            print("Failed to load models: \(error)")
        }
    }

    func loadMessages(for sessionID: String) async {
        guard loadingMessages[sessionID] != true else { return }
        loadingMessages[sessionID] = true
        do {
            let list = try await api.getMessages(sessionID: sessionID)
            envelopes[sessionID] = list
            markLatestAssistantSeen(sessionID: sessionID, list: list)
        } catch {
            if !isCancellation(error) {
                errorMessage = error.localizedDescription
            }
            print("loadMessages error: \(error)")
        }
        loadingMessages[sessionID] = false
    }

    /// Keep the background-refresh cursor in sync with what the user has
    /// actually seen, so we don't re-notify them about it later.
    private func markLatestAssistantSeen(sessionID: String, list: [MessageEnvelope]) {
        #if os(iOS)
        let latest = list
            .filter { $0.info.role == .assistant && $0.info.time.completed != nil }
            .max { $0.info.time.created < $1.info.time.created }
        if let id = latest?.info.id {
            BackgroundRefreshService.shared.markSeen(sessionID: sessionID, messageID: id)
        }
        #endif
    }

    // MARK: - Session Actions
    @discardableResult
    func createSession() async -> Session? {
        do {
            let session = try await api.createSession()
            sessions.insert(session, at: 0)
            return session
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func renameSession(id: String, newTitle: String) async {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let updated = try await api.renameSession(id: id, title: trimmed)
            upsertSession(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSession(id: String) async {
        do {
            try await api.deleteSession(id: id)
            sessions.removeAll { $0.id == id }
            envelopes.removeValue(forKey: id)
            if pinnedSessionIDs.remove(id) != nil {
                UserDefaults.standard.set(Array(pinnedSessionIDs), forKey: pinnedDefaultsKey)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Sessions older than the cutoff, excluding pinned ones.
    /// `time` is stored as milliseconds since epoch.
    func sessionsOlderThan(days: Int) -> [Session] {
        let cutoffMs = (Date().timeIntervalSince1970 - Double(days) * 86_400) * 1000
        return sessions.filter { s in
            guard !pinnedSessionIDs.contains(s.id) else { return false }
            let ts = s.time?.updated ?? s.time?.created ?? 0
            return ts > 0 && ts < cutoffMs
        }
    }

    /// Batch delete sessions older than N days (skipping pinned). Returns the
    /// number successfully deleted. Uses bounded concurrency to avoid hammering
    /// the server.
    func cleanupSessions(olderThanDays days: Int) async -> Int {
        let victims = sessionsOlderThan(days: days)
        guard !victims.isEmpty else { return 0 }

        let ids = victims.map(\.id)
        let api = self.api
        let maxConcurrency = 5
        var deleted = 0

        await withTaskGroup(of: String?.self) { group in
            var iterator = ids.makeIterator()
            func addNext() {
                guard let id = iterator.next() else { return }
                group.addTask {
                    do {
                        try await api.deleteSession(id: id)
                        return id
                    } catch {
                        return nil
                    }
                }
            }
            for _ in 0..<min(maxConcurrency, ids.count) { addNext() }
            while let result = await group.next() {
                if result != nil { deleted += 1 }
                addNext()
            }
        }

        // SSE session.deleted will also prune, but be defensive so UI updates
        // immediately even if the stream is lagging.
        let deletedIDs = Set(ids)
        sessions.removeAll { deletedIDs.contains($0.id) }
        for id in deletedIDs { envelopes.removeValue(forKey: id) }
        return deleted
    }

    // MARK: - Message Actions
    func sendMessage(sessionID: String, text: String, image: UIImage? = nil) async {
        generatingSessions.insert(sessionID)
        do {
            let selectedID = AppSettings.shared.selectedModelID
            let model = availableModels.first { $0.id == selectedID }
            let providerID = model?.providerID
            let modelID = model?.id
            // 图片压缩在后台线程执行，避免阻塞主线程
            let imageData: Data? = await Task.detached(priority: .userInitiated) {
                guard let img = image else { return nil }
                let maxDimension: CGFloat = 1024
                let scale = min(maxDimension / img.size.width, maxDimension / img.size.height, 1.0)
                let newSize = CGSize(width: img.size.width * scale, height: img.size.height * scale)
                let renderer = UIGraphicsImageRenderer(size: newSize)
                let resized = renderer.image { _ in img.draw(in: CGRect(origin: .zero, size: newSize)) }
                return resized.jpegData(compressionQuality: 0.75)
            }.value
            try await api.sendMessage(
                sessionID: sessionID,
                text: text,
                imageData: imageData,
                providerID: providerID,
                modelID: modelID
            )
        } catch {
            generatingSessions.remove(sessionID)
            if !isCancellation(error) {
                errorMessage = error.localizedDescription
            }
        }
    }

    func abort(sessionID: String) async {
        try? await api.abortSession(id: sessionID)
    }

    func sendAudio(sessionID: String, fileURL: URL, duration: TimeInterval) async {
        generatingSessions.insert(sessionID)
        do {
            let selectedID = AppSettings.shared.selectedModelID
            let model = availableModels.first { $0.id == selectedID }
            let providerID = model?.providerID
            let modelID = model?.id
            // 把时长编入文件名，方便显示：voice_5s_1234567890.m4a
            let seconds = max(1, Int(duration.rounded()))
            let filename = "voice_\(seconds)s_\(Int(Date().timeIntervalSince1970)).m4a"
            // 在后台线程读取文件
            let data = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: fileURL)
            }.value
            // 缓存到本地，用于播放
            #if os(iOS)
            AudioPlayerService.shared.cacheAudio(data: data, filename: filename)
            #endif
            try await api.sendAudioMessage(
                sessionID: sessionID,
                audioData: data,
                filename: filename,
                providerID: providerID,
                modelID: modelID
            )
        } catch {
            generatingSessions.remove(sessionID)
            if !isCancellation(error) {
                errorMessage = error.localizedDescription
            }
        }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    // MARK: - SSE handling
    private func handleRawEnvelope(_ data: Data) {
        guard let envelope = try? decoder.decode(SSEEnvelope.self, from: data) else { return }
        let type = envelope.type
        // Re-encode properties to get typed data
        guard let propsData = try? JSONEncoder().encode(envelope.properties) else { return }

        switch type {
        case "session.created", "session.updated":
            if let props = try? decoder.decode(SessionEventProperties.self, from: propsData),
               let session = props.info {
                upsertSession(session)
            }
        case "session.deleted":
            if let props = try? decoder.decode(SessionEventProperties.self, from: propsData) {
                let sid = props.info?.id ?? props.id
                if let sid { sessions.removeAll { $0.id == sid } }
            }
        case "message.updated":
            if let props = try? decoder.decode(MessageUpdatedProperties.self, from: propsData) {
                upsertMessageInfo(props.info)
            }
        case "message.removed":
            if let props = try? decoder.decode(MessageRemovedProperties.self, from: propsData) {
                envelopes[props.sessionID]?.removeAll { $0.info.id == props.messageID }
            }
        case "message.part.delta":
            if let props = try? decoder.decode(PartDeltaProperties.self, from: propsData) {
                applyPartDelta(props)
            }
        case "message.part.updated":
            if let props = try? decoder.decode(PartUpdatedProperties.self, from: propsData) {
                upsertPart(props.part)
            }
        case "session.idle":
            if let props = try? decoder.decode(SessionIdleProperties.self, from: propsData) {
                generatingSessions.remove(props.sessionID)
            }
        case "session.status":
            if let props = try? decoder.decode(SessionStatusProperties.self, from: propsData),
               props.status.type != "busy" {
                generatingSessions.remove(props.sessionID)
            }
        default:
            break
        }
    }

    private func upsertSession(_ session: Session) {
        if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[i] = session
        } else {
            sessions.append(session)
        }
        sortSessionsByRecency()
    }

    private func bumpSessionActivity(_ sessionID: String, to timestamp: Double) {
        guard let i = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var s = sessions[i]
        let current = s.time?.updated ?? s.time?.created ?? 0
        guard timestamp > current else { return }
        if s.time != nil {
            s.time?.updated = timestamp
        } else {
            s.time = Session.SessionTime(created: timestamp, updated: timestamp)
        }
        sessions[i] = s
        sortSessionsByRecency()
    }

    private func upsertMessageInfo(_ info: MessageInfo) {
        let sid = info.sessionID
        var list = envelopes[sid] ?? []
        if let i = list.firstIndex(where: { $0.info.id == info.id }) {
            let wasCompleted = list[i].info.time.completed != nil
            list[i] = MessageEnvelope(info: info, parts: list[i].parts)
            // Fallback: only fire when the message *just* transitioned to completed.
            // Avoids false positives from SSE backfill replaying old completed messages.
            if info.role == .assistant && info.time.completed != nil && !wasCompleted {
                generatingSessions.remove(sid)
            }
        } else {
            list.append(MessageEnvelope(info: info, parts: []))
        }
        envelopes[sid] = list
        bumpSessionActivity(sid, to: info.time.completed ?? info.time.created)
    }

    private func upsertPart(_ part: PartWithContext) {
        let sid = part.sessionID
        let mid = part.messageID
        guard var list = envelopes[sid],
              let msgIdx = list.firstIndex(where: { $0.info.id == mid }) else { return }

        var env = list[msgIdx]
        var mp = part.toMessagePart()
        if let pi = env.parts.firstIndex(where: { $0.partID == mp.partID }) {
            // SSE events may omit large fields (e.g. file data URLs, streaming text);
            // preserve existing values so delta-accumulated content isn't wiped
            if mp.url == nil { mp.url = env.parts[pi].url }
            if mp.text == nil { mp.text = env.parts[pi].text }
            env.parts[pi] = mp
        } else {
            env.parts.append(mp)
        }
        list[msgIdx] = env
        envelopes[sid] = list
    }

    private func applyPartDelta(_ delta: PartDeltaProperties) {
        let sid = delta.sessionID
        guard var list = envelopes[sid],
              let msgIdx = list.firstIndex(where: { $0.info.id == delta.messageID }) else { return }

        var env = list[msgIdx]
        // Server always emits message.part.updated before any delta for that part,
        // so the part must already exist. Drop deltas for unknown partIDs rather
        // than creating a placeholder with the wrong type (e.g. text instead of reasoning).
        guard let pi = env.parts.firstIndex(where: { $0.partID == delta.partID }) else { return }

        switch delta.field {
        case "text":
            env.parts[pi].text = (env.parts[pi].text ?? "") + delta.delta
        default:
            return
        }
        list[msgIdx] = env
        envelopes[sid] = list
    }
}
