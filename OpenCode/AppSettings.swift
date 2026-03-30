import Foundation
import Observation

@Observable
final class AppSettings {
    static let shared = AppSettings()

    var baseURL: String = "" {
        didSet { UserDefaults.standard.set(baseURL, forKey: Keys.baseURL) }
    }
    var username: String = "" {
        didSet { UserDefaults.standard.set(username, forKey: Keys.username) }
    }
    var password: String = "" {
        didSet { UserDefaults.standard.set(password, forKey: Keys.password) }
    }
    var selectedModelID: String = "" {
        didSet { UserDefaults.standard.set(selectedModelID, forKey: Keys.model) }
    }
    var recentModelIDs: [String] = [] {
        didSet { UserDefaults.standard.set(recentModelIDs, forKey: Keys.recentModels) }
    }

    private enum Keys {
        static let baseURL = "opencode_baseUrl"
        static let username = "opencode_username"
        static let password = "opencode_password"
        static let model = "opencode_model"
        static let recentModels = "opencode_recentModels"
    }

    private init() {
        baseURL = UserDefaults.standard.string(forKey: Keys.baseURL) ?? "http://localhost:4096"
        username = UserDefaults.standard.string(forKey: Keys.username) ?? ""
        password = UserDefaults.standard.string(forKey: Keys.password) ?? ""
        let modelID = UserDefaults.standard.string(forKey: Keys.model) ?? ""
        selectedModelID = modelID
        var recent = UserDefaults.standard.stringArray(forKey: Keys.recentModels) ?? []
        // 确保当前选中的模型在 Recent 里
        if !modelID.isEmpty && !recent.contains(modelID) {
            recent.insert(modelID, at: 0)
        }
        recentModelIDs = recent
    }

    func recordRecentModel(_ id: String) {
        var recent = recentModelIDs.filter { $0 != id }
        recent.insert(id, at: 0)
        recentModelIDs = Array(recent.prefix(8))
    }

    var authHeader: String? {
        guard !username.isEmpty || !password.isEmpty else { return nil }
        let creds = "\(username):\(password)"
        guard let data = creds.data(using: .utf8) else { return nil }
        return "Basic \(data.base64EncodedString())"
    }
}
