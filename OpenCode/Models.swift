import Foundation

// MARK: - Session
struct Session: Identifiable, Codable, Equatable {
    let id: String
    var title: String?
    var parentID: String?
    var time: SessionTime?

    struct SessionTime: Codable, Equatable {
        let created: Double
        var updated: Double?
    }

    var displayTitle: String {
        let t = title ?? ""
        return t.isEmpty ? "New Chat" : t
    }
}

// MARK: - Message (backend wraps in { info, parts })
struct MessageEnvelope: Codable {
    let info: MessageInfo
    var parts: [MessagePart]
}

struct MessageInfo: Identifiable, Codable, Equatable {
    let id: String
    let role: MessageRole
    let sessionID: String
    var time: MessageTime
    var parentID: String?
    var modelID: String?
    var providerID: String?
    var cost: Double?
    var tokens: TokenInfo?
    var error: AnyCodable?
    var finish: String?

    struct MessageTime: Codable, Equatable {
        let created: Double
        var completed: Double?
    }

    struct TokenInfo: Codable, Equatable {
        var input: Int = 0
        var output: Int = 0
        var reasoning: Int = 0
        var cache: CacheInfo?

        struct CacheInfo: Codable, Equatable {
            var read: Int = 0
            var write: Int = 0
        }
    }
}

enum MessageRole: String, Codable, Equatable {
    case user
    case assistant
}

// MARK: - MessagePart (flat struct matching actual API field names)
struct MessagePart: Codable, Equatable {
    let type: String
    var id: String? = nil

    // text part: field "text"
    // reasoning part: also field "text" (same field name!)
    var text: String? = nil

    // tool part
    var callID: String? = nil   // "callID" in API
    var tool: String? = nil     // tool name, "tool" in API
    var state: ToolState? = nil

    // source-url part
    var url: String? = nil
    var title: String? = nil

    // file part
    var mime: String? = nil
    var filename: String? = nil

    // Stable identity for SwiftUI ForEach. Falls back to type+content hash so the
    // same part never produces two different IDs across renders.
    var partID: String {
        if let id = id { return id }
        if let callID = callID { return callID }
        if let url = url { return url }
        return "\(type):\(text ?? "")\(filename ?? "")"
    }

    struct ToolState: Codable, Equatable {
        var status: String? = nil  // "running", "completed", "error"
        var input: AnyCodable? = nil
        var output: AnyCodable? = nil
    }

    enum CodingKeys: String, CodingKey {
        case type, id, text, callID, tool, state, url, title, mime, filename
    }
}

// MARK: - Providers API  ({ "providers": [...] })
struct ProvidersResponse: Codable {
    let providers: [Provider]
}

struct Provider: Codable, Identifiable {
    let id: String
    var name: String?
    var models: [String: ModelInfo]?
}

struct ModelInfo: Codable, Equatable, Identifiable {
    let id: String
    var name: String?
}

struct AvailableModel: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let providerID: String
    let providerName: String
}

// MARK: - SSE Envelope  { "type": "...", "properties": {...} }
struct SSEEnvelope: Codable {
    let type: String
    let properties: AnyCodable
}

// MARK: - SSE Event Property Types
struct SessionEventProperties: Codable {
    var info: Session?
    var id: String?  // fallback for session.deleted
}

struct MessageUpdatedProperties: Codable {
    let info: MessageInfo
}

struct MessageRemovedProperties: Codable {
    let sessionID: String
    let messageID: String
}

struct PartDeltaProperties: Codable {
    let sessionID: String
    let messageID: String
    let partID: String
    let field: String   // e.g. "text"
    let delta: String
}

struct PartUpdatedProperties: Codable {
    let part: PartWithContext
}

struct PartWithContext: Codable {
    let sessionID: String
    let messageID: String
    // All MessagePart fields flattened
    let type: String
    var id: String?
    var text: String?
    var callID: String?
    var tool: String?
    var state: MessagePart.ToolState?
    var url: String?
    var title: String?
    var mime: String?
    var filename: String?

    func toMessagePart() -> MessagePart {
        var p = MessagePart(type: type)
        p.id = id
        p.text = text
        p.callID = callID
        p.tool = tool
        p.state = state
        p.url = url
        p.title = title
        p.mime = mime
        p.filename = filename
        return p
    }
}

struct SessionIdleProperties: Codable {
    let sessionID: String
}

struct SessionStatusProperties: Codable {
    let sessionID: String
    let status: StatusValue

    struct StatusValue: Codable {
        let type: String  // "idle" or "busy"
    }
}

// MARK: - AnyCodable
struct AnyCodable: Codable, Equatable {
    let value: Any

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        guard let l = try? JSONEncoder().encode(lhs),
              let r = try? JSONEncoder().encode(rhs) else { return false }
        return l == r
    }

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Int.self) { value = v }
        else if let v = try? c.decode(Double.self) { value = v }
        else if let v = try? c.decode(Bool.self) { value = v }
        else if let v = try? c.decode(String.self) { value = v }
        else if let v = try? c.decode([AnyCodable].self) { value = v.map { $0.value } }
        else if let v = try? c.decode([String: AnyCodable].self) { value = v.mapValues { $0.value } }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as Int: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as Bool: try c.encode(v)
        case let v as String: try c.encode(v)
        case let v as [Any]: try c.encode(v.map { AnyCodable($0) })
        case let v as [String: Any]: try c.encode(v.mapValues { AnyCodable($0) })
        default: try c.encodeNil()
        }
    }

    var prettyJSON: String {
        if let data = try? JSONEncoder().encode(self),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: pretty, encoding: .utf8) {
            return str
        }
        return "\(value)"
    }
}
