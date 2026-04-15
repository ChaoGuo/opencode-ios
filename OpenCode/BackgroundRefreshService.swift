import Foundation
#if os(iOS)
import BackgroundTasks
import UIKit

/// Polls the opencode backend while the app is backgrounded and posts a local
/// notification when a new assistant message has appeared since the last
/// sighting. iOS decides the cadence (roughly every 15+ min, often rarer); this
/// service only asks and handles the wake-up.
final class BackgroundRefreshService {
    static let shared = BackgroundRefreshService()

    static let taskIdentifier = "com.smallwalk.OpenCode.refresh"
    /// Poll at most this many sessions per wake-up to stay within the ~30s budget.
    private let maxSessionsToCheck = 5
    /// Per-request timeout (seconds). BGTasks have a hard ~30s cap overall.
    private let requestTimeout: TimeInterval = 8

    private let cursors = MessageCursorStore.shared

    private init() {}

    // MARK: - Public API

    /// Call once from app launch, before the app finishes launching.
    func registerTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            self?.handle(task: task)
        }
    }

    /// Ask iOS to schedule the next refresh. Call when entering background.
    func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Common reasons: simulator doesn't support BGTasks; user disabled
            // Background App Refresh globally; already scheduled.
            print("[BGRefresh] submit error: \(error)")
        }
    }

    /// Seed cursors for sessions that don't have one yet, so the first refresh
    /// doesn't treat every historical message as "new". Called opportunistically
    /// from the view model once messages are loaded.
    func seedCursorIfNeeded(sessionID: String, envelopes: [MessageEnvelope]) {
        guard cursors.cursor(for: sessionID) == nil,
              let latest = latestAssistantMessageID(in: envelopes) else { return }
        cursors.setCursor(latest, for: sessionID)
    }

    /// Update the cursor as the user observes messages live. Keeps the
    /// background poller from re-notifying something the user already saw.
    func markSeen(sessionID: String, messageID: String) {
        cursors.setCursor(messageID, for: sessionID)
    }

    // MARK: - Task handling

    private func handle(task: BGAppRefreshTask) {
        // Chain the next refresh immediately — if iOS kills us mid-work we still
        // get rescheduled.
        scheduleNext()

        let work = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.pollForNewMessages()
        }

        task.expirationHandler = {
            work.cancel()
        }

        Task.detached {
            _ = await work.value
            task.setTaskCompleted(success: !Task.isCancelled)
        }
    }

    // MARK: - Polling

    private func pollForNewMessages() async {
        // Honor the user preference; the toggle only gates *posting* notifications.
        // We still run the fetch so cursors stay current, but skip if unauthorized.
        let authorized = await NotificationService.shared.isAuthorized()
        guard authorized, AppSettings.shared.notificationsEnabled else { return }

        let api = APIService.shared
        do {
            let sessions = try await api.getSessions()
            let candidates = sessions
                .sorted { ($0.time?.updated ?? $0.time?.created ?? 0) > ($1.time?.updated ?? $1.time?.created ?? 0) }
                .prefix(maxSessionsToCheck)

            await withTaskGroup(of: Void.self) { group in
                for session in candidates {
                    group.addTask { [weak self] in
                        await self?.checkSession(session)
                    }
                }
            }
        } catch {
            print("[BGRefresh] getSessions error: \(error)")
        }
    }

    private func checkSession(_ session: Session) async {
        if Task.isCancelled { return }
        do {
            let envelopes = try await APIService.shared.getMessages(sessionID: session.id)
            guard let latest = latestAssistantEnvelope(in: envelopes) else { return }

            let previousCursor = cursors.cursor(for: session.id)
            if previousCursor == latest.info.id { return }

            // First sighting for a never-seen session — establish the baseline
            // silently rather than announcing "new" on every historical message.
            if previousCursor == nil {
                cursors.setCursor(latest.info.id, for: session.id)
                return
            }

            let preview = previewText(from: latest.parts)
            await MainActor.run {
                NotificationService.shared.postNewMessage(
                    sessionTitle: session.displayTitle,
                    preview: preview.isEmpty ? "New message" : preview,
                    sessionID: session.id,
                    messageID: latest.info.id
                )
            }
            cursors.setCursor(latest.info.id, for: session.id)
        } catch {
            print("[BGRefresh] getMessages(\(session.id)) error: \(error)")
        }
    }

    // MARK: - Helpers

    private func latestAssistantEnvelope(in envelopes: [MessageEnvelope]) -> MessageEnvelope? {
        envelopes
            .filter { $0.info.role == .assistant && $0.info.time.completed != nil }
            .max { $0.info.time.created < $1.info.time.created }
    }

    private func latestAssistantMessageID(in envelopes: [MessageEnvelope]) -> String? {
        latestAssistantEnvelope(in: envelopes)?.info.id
    }

    private func previewText(from parts: [MessagePart]) -> String {
        let chunks = parts.compactMap { part -> String? in
            guard part.type == "text" else { return nil }
            return part.text
        }
        let joined = chunks.joined(separator: " ")
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 140 { return trimmed }
        return String(trimmed.prefix(140)) + "…"
    }
}
#endif
