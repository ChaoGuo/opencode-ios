import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case httpError(Int)
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid server URL"
        case .httpError(let c): return "Server returned HTTP \(c)"
        case .decodingError(let m): return "Decode error: \(m)"
        }
    }
}

final class APIService {
    static let shared = APIService()
    private let settings = AppSettings.shared
    private let decoder = JSONDecoder()
    private let session: URLSession = URLSession.shared

    private init() {}

    private func makeRequest(_ path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard let url = URL(string: settings.baseURL + path) else {
            throw APIError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        if let auth = settings.authHeader {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    // MARK: - Sessions
    func getSessions() async throws -> [Session] {
        let req = try makeRequest("/session")
        let (data, _) = try await session.data(for: req)
        return try decoder.decode([Session].self, from: data)
    }

    func createSession() async throws -> Session {
        let req = try makeRequest("/session", method: "POST")
        let (data, _) = try await session.data(for: req)
        return try decoder.decode(Session.self, from: data)
    }

    func deleteSession(id: String) async throws {
        let req = try makeRequest("/session/\(id)", method: "DELETE")
        _ = try await session.data(for: req)
    }

    // MARK: - Messages
    /// Returns array of MessageEnvelope: [{ info, parts }]
    func getMessages(sessionID: String) async throws -> [MessageEnvelope] {
        let req = try makeRequest("/session/\(sessionID)/message")
        let (data, _) = try await session.data(for: req)
        do {
            return try decoder.decode([MessageEnvelope].self, from: data)
        } catch {
            print("Message decode error: \(error)")
            print("Raw: \(String(data: data, encoding: .utf8)?.prefix(500) ?? "")")
            throw error
        }
    }

    func sendMessage(sessionID: String, text: String, imageData: Data?,
                     providerID: String?, modelID: String?) async throws {
        struct TextPart: Encodable { let type = "text"; let text: String }
        struct FilePart: Encodable {
            let type = "file"; let mime: String; let filename: String; let url: String
        }
        struct ModelRef: Encodable { let providerID: String; let modelID: String }

        let modelRef: ModelRef? = {
            guard let p = providerID, let m = modelID, !p.isEmpty, !m.isEmpty
            else { return nil }
            return ModelRef(providerID: p, modelID: m)
        }()

        // 构造 parts（base64 编码在后台完成）
        let body: Data = try await Task.detached(priority: .userInitiated) {
            var partsData: [[String: String]] = []
            if let imgData = imageData {
                let b64 = imgData.base64EncodedString()
                print("[API] Image size: \(imgData.count / 1024)KB, base64: \(b64.count / 1024)KB")
                partsData.append(["type": "file", "mime": "image/jpeg",
                                   "filename": "image.jpg",
                                   "url": "data:image/jpeg;base64,\(b64)"])
            }
            if !text.isEmpty {
                partsData.append(["type": "text", "text": text])
            }
            var bodyDict: [String: Any] = ["parts": partsData]
            if let m = modelRef {
                bodyDict["model"] = ["providerID": m.providerID, "modelID": m.modelID]
            }
            let data = try JSONSerialization.data(withJSONObject: bodyDict)
            print("[API] Request body total: \(data.count / 1024)KB")
            return data
        }.value
        var req = try makeRequest("/session/\(sessionID)/prompt_async", method: "POST", body: body)
        // 图片请求给更长超时
        if imageData != nil { req.timeoutInterval = 120 }
        print("[API] Sending prompt_async...")
        let (_, resp) = try await session.data(for: req)
        let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? -1
        print("[API] prompt_async response: HTTP \(statusCode)")
    }

    func sendAudioMessage(sessionID: String, audioData: Data, filename: String,
                          providerID: String?, modelID: String?) async throws {
        struct FilePart: Encodable {
            let type = "file"
            let mime = "audio/m4a"
            let filename: String
            let url: String
        }
        struct Model: Encodable { let providerID: String; let modelID: String }
        struct Body: Encodable {
            let parts: [FilePart]
            let model: Model?
        }
        let dataURL = "data:audio/m4a;base64," + audioData.base64EncodedString()
        let model: Model? = {
            guard let p = providerID, let m = modelID, !p.isEmpty, !m.isEmpty
            else { return nil }
            return Model(providerID: p, modelID: m)
        }()
        let body = Body(parts: [FilePart(filename: filename, url: dataURL)], model: model)
        let req = try makeRequest("/session/\(sessionID)/prompt_async", method: "POST",
                                   body: try JSONEncoder().encode(body))
        _ = try await session.data(for: req)
    }

    func abortSession(id: String) async throws {
        let req = try makeRequest("/session/\(id)/abort", method: "POST")
        _ = try await session.data(for: req)
    }

    // MARK: - Providers
    // 优先用 /provider (完整列表)，失败则退回 /config/providers
    func getProviders() async throws -> [Provider] {
        if let providers = try? await getProvidersFull(), !providers.isEmpty {
            return providers
        }
        let req = try makeRequest("/config/providers")
        let (data, _) = try await session.data(for: req)
        let response = try decoder.decode(ProvidersResponse.self, from: data)
        return response.providers
    }

    private func getProvidersFull() async throws -> [Provider] {
        struct FullResponse: Decodable {
            let all: [Provider]
        }
        let req = try makeRequest("/provider")
        let (data, _) = try await session.data(for: req)
        let response = try decoder.decode(FullResponse.self, from: data)
        return response.all
    }

    // MARK: - Health
    func checkHealth() async -> Bool {
        guard let req = try? makeRequest("/global/health") else { return false }
        guard let (_, resp) = try? await session.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: - SSE request
    func makeSSERequest() throws -> URLRequest {
        var req = try makeRequest("/event")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 0
        return req
    }
}
