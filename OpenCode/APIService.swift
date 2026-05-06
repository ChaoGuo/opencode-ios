import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case httpError(Int, String? = nil)
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid server URL"
        case .httpError(let c, let detail):
            return detail ?? "Server returned HTTP \(c)"
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

    func renameSession(id: String, title: String) async throws -> Session {
        let body = try JSONEncoder().encode(["title": title])
        let req = try makeRequest("/session/\(id)", method: "PATCH", body: body)
        let (data, _) = try await session.data(for: req)
        return try decoder.decode(Session.self, from: data)
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

    func sendMessage(sessionID: String, text: String, imageURL: String?,
                     providerID: String?, modelID: String?) async throws {
        struct ModelRef: Encodable { let providerID: String; let modelID: String }

        let modelRef: ModelRef? = {
            guard let p = providerID, let m = modelID, !p.isEmpty, !m.isEmpty
            else { return nil }
            return ModelRef(providerID: p, modelID: m)
        }()

        // 构造 parts。
        // file service 公网 URL → 拼到文本末尾，避开下游 provider 不接受 URL 图片的问题（Kimi 等只吃 base64）。
        // base64 data: URL → 仍以 file part 走，opencode 对 data: 协议有特殊处理直传模型。
        let body: Data = try await Task.detached(priority: .userInitiated) {
            var partsData: [[String: String]] = []
            var combinedText = text
            if let imgURL = imageURL {
                if imgURL.hasPrefix("data:") {
                    partsData.append(["type": "file", "mime": "image/jpeg",
                                       "filename": "image.jpg",
                                       "url": imgURL])
                } else {
                    combinedText = combinedText.isEmpty ? imgURL : "\(combinedText)\n\(imgURL)"
                }
            }
            if !combinedText.isEmpty {
                partsData.append(["type": "text", "text": combinedText])
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
        // 带图片的请求给更长超时
        if imageURL != nil { req.timeoutInterval = 120 }
        print("[API] Sending prompt_async...")
        let (_, resp) = try await session.data(for: req)
        let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? -1
        print("[API] prompt_async response: HTTP \(statusCode)")
    }

    // MARK: - File Service
    /// 本地文件缓存目录，作为文件服务加载失败的后备（图片 + 语音）
    private static let fileCacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("opencode-files")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func cachedFileData(for urlString: String?) -> Data? {
        guard let urlString, let key = Self.cacheKey(from: urlString) else { return nil }
        let fileURL = fileCacheDir.appendingPathComponent(key)
        return try? Data(contentsOf: fileURL)
    }

    static func cacheFile(_ data: Data, urlString: String) {
        guard let key = Self.cacheKey(from: urlString) else { return }
        try? data.write(to: fileCacheDir.appendingPathComponent(key))
    }

    private static func cacheKey(from urlString: String) -> String? {
        guard let range = urlString.range(of: "/file/") else { return nil }
        return String(urlString[range.upperBound...])
    }

    func uploadImage(_ imageData: Data) async throws -> String {
        try await uploadFile(imageData, filename: "image.jpg", mime: "image/jpeg")
    }

    func uploadAudio(_ audioData: Data, filename: String) async throws -> String {
        try await uploadFile(audioData, filename: filename, mime: "audio/m4a")
    }

    func uploadFile(_ fileData: Data, filename: String, mime: String) async throws -> String {
        let baseURL = settings.fileServiceURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(baseURL)/file/upload") else {
            throw APIError.invalidURL
        }

        let boundary = UUID().uuidString
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let auth = settings.fileServiceAuthHeader {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, resp) = try await session.data(for: req)
        let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard statusCode == 200 else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(statusCode, bodyStr)
        }

        struct UploadResponse: Decodable {
            let id: String
            let url: String
            let filename: String
            let mime: String
            let size: Int
        }

        let uploadResp = try decoder.decode(UploadResponse.self, from: data)
        // 服务端可能返回绝对 URL（http(s)://...）或以 / 开头的相对路径，
        // 仅在相对路径时拼接 baseURL，避免出现 "http://host:portohttp://..." 这种损坏 URL。
        let returnedURL = uploadResp.url
        let fullURL: String
        if returnedURL.hasPrefix("http://") || returnedURL.hasPrefix("https://") {
            fullURL = returnedURL
        } else {
            let path = returnedURL.hasPrefix("/") ? returnedURL : "/\(returnedURL)"
            fullURL = "\(baseURL)\(path)"
        }
        // 保存到本地缓存作为后备
        Self.cacheFile(fileData, urlString: fullURL)
        print("[API] File uploaded (\(mime), \(fileData.count / 1024)KB) -> \(fullURL)")
        return fullURL
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
