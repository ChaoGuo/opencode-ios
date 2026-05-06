import Foundation
import Observation

enum TranscriptState {
    case idle
    case streaming(String)
    case final(String)
    case failed(String)

    var displayText: String? {
        switch self {
        case .idle, .failed: return nil
        case .streaming(let t), .final(let t): return t
        }
    }
    var isInProgress: Bool {
        if case .streaming = self { return true }
        return false
    }
    var isFinished: Bool {
        if case .final = self { return true }
        return false
    }
    var failureMessage: String? {
        if case .failed(let m) = self { return m }
        return nil
    }
}

/// In-memory cache of voice-message transcripts, keyed by audio URL.
/// Resets on app relaunch by design (per-user decision).
@Observable
final class TranscriptStore {
    static let shared = TranscriptStore()
    private init() {}

    private var cache: [String: TranscriptState] = [:]

    func state(for audioURL: String) -> TranscriptState {
        cache[audioURL] ?? .idle
    }

    @MainActor
    func transcribe(audioURL: String) async {
        if case .streaming = cache[audioURL] { return }
        cache[audioURL] = .streaming("")
        do {
            let stream = try await STTService.shared.streamTranscribe(audioURL: audioURL)
            for try await ev in stream {
                switch ev.type {
                case "delta":
                    cache[audioURL] = .streaming(ev.text)
                case "final":
                    cache[audioURL] = .final(ev.text)
                case "error":
                    cache[audioURL] = .failed(ev.message.isEmpty ? "转写失败" : ev.message)
                    return
                case "done":
                    if case .streaming(let t) = cache[audioURL] {
                        cache[audioURL] = t.isEmpty ? .failed("未识别到语音") : .final(t)
                    }
                    return
                default:
                    break
                }
            }
            if case .streaming(let t) = cache[audioURL] {
                cache[audioURL] = t.isEmpty ? .failed("连接中断") : .final(t)
            }
        } catch {
            cache[audioURL] = .failed(error.localizedDescription)
        }
    }
}

final class STTService {
    static let shared = STTService()
    private init() {}

    private let settings = AppSettings.shared
    private let session = URLSession.shared
    private let decoder = JSONDecoder()

    struct STTEvent: Decodable {
        let type: String
        let text: String
        let message: String
    }

    enum STTError: LocalizedError {
        case noServiceConfigured
        case invalidURL
        case audioFetchFailed(Int)
        case streamFailed(Int, String)

        var errorDescription: String? {
            switch self {
            case .noServiceConfigured: return "未配置语音转文字服务"
            case .invalidURL: return "Invalid URL"
            case .audioFetchFailed(let c): return "下载音频失败 (HTTP \(c))"
            case .streamFailed(let c, let m): return m.isEmpty ? "STT 服务返回 HTTP \(c)" : m
            }
        }
    }

    func streamTranscribe(audioURL: String) async throws -> AsyncThrowingStream<STTEvent, Error> {
        let sttBase = settings.sttServiceURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !sttBase.isEmpty else { throw STTError.noServiceConfigured }
        guard let endpoint = URL(string: "\(sttBase)/transcribe/stream") else {
            throw STTError.invalidURL
        }

        // 优先用本地缓存，没有再下载
        let audioData: Data
        if let cached = APIService.cachedFileData(for: audioURL) {
            audioData = cached
        } else {
            audioData = try await fetchAudioBytes(audioURL: audioURL)
        }
        let filename = URL(string: audioURL)?.lastPathComponent ?? "voice.m4a"

        let boundary = UUID().uuidString
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let auth = settings.fileServiceAuthHeader {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (bytes, response) = try await session.bytes(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw STTError.streamFailed(status, "")
        }

        let dec = decoder
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard let data = payload.data(using: .utf8) else { continue }
                        if let event = try? dec.decode(STTEvent.self, from: data) {
                            continuation.yield(event)
                            if event.type == "done" || event.type == "error" { break }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func fetchAudioBytes(audioURL: String) async throws -> Data {
        guard let url = URL(string: audioURL) else { throw STTError.invalidURL }
        var req = URLRequest(url: url)
        if let auth = settings.fileServiceAuthHeader {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw STTError.audioFetchFailed(status) }
        APIService.cacheFile(data, urlString: audioURL)
        return data
    }
}
