import Foundation
import Observation
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

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
    var fileServiceURL: String = "" {
        didSet { UserDefaults.standard.set(fileServiceURL, forKey: Keys.fileServiceURL) }
    }
    var fileServiceUsername: String = "" {
        didSet { UserDefaults.standard.set(fileServiceUsername, forKey: Keys.fileServiceUsername) }
    }
    var fileServicePassword: String = "" {
        didSet { UserDefaults.standard.set(fileServicePassword, forKey: Keys.fileServicePassword) }
    }
    var notificationsEnabled: Bool = true {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: Keys.notifications) }
    }
    var appearance: AppearanceMode = .system {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    private enum Keys {
        static let baseURL = "opencode_baseUrl"
        static let username = "opencode_username"
        static let password = "opencode_password"
        static let model = "opencode_model"
        static let recentModels = "opencode_recentModels"
        static let fileServiceURL = "opencode_fileServiceURL"
        static let fileServiceUsername = "opencode_fileServiceUsername"
        static let fileServicePassword = "opencode_fileServicePassword"
        static let notifications = "opencode_notificationsEnabled"
        static let appearance = "opencode_appearance"
    }

    private init() {
        baseURL = UserDefaults.standard.string(forKey: Keys.baseURL) ?? "http://localhost:4096"
        username = UserDefaults.standard.string(forKey: Keys.username) ?? ""
        password = UserDefaults.standard.string(forKey: Keys.password) ?? ""
        let modelID = UserDefaults.standard.string(forKey: Keys.model) ?? ""
        fileServiceURL = UserDefaults.standard.string(forKey: Keys.fileServiceURL) ?? "http://localhost:4097"
        fileServiceUsername = UserDefaults.standard.string(forKey: Keys.fileServiceUsername) ?? ""
        fileServicePassword = UserDefaults.standard.string(forKey: Keys.fileServicePassword) ?? ""
        selectedModelID = modelID
        var recent = UserDefaults.standard.stringArray(forKey: Keys.recentModels) ?? []
        // 确保当前选中的模型在 Recent 里
        if !modelID.isEmpty && !recent.contains(modelID) {
            recent.insert(modelID, at: 0)
        }
        recentModelIDs = recent
        // Default ON; fall back to the stored flag if the user flipped it before.
        if UserDefaults.standard.object(forKey: Keys.notifications) != nil {
            notificationsEnabled = UserDefaults.standard.bool(forKey: Keys.notifications)
        }
        if let raw = UserDefaults.standard.string(forKey: Keys.appearance),
           let mode = AppearanceMode(rawValue: raw) {
            appearance = mode
        }
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

    var fileServiceAuthHeader: String? {
        guard !fileServiceUsername.isEmpty || !fileServicePassword.isEmpty else { return nil }
        let creds = "\(fileServiceUsername):\(fileServicePassword)"
        guard let data = creds.data(using: .utf8) else { return nil }
        return "Basic \(data.base64EncodedString())"
    }
}
