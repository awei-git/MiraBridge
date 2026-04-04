import Foundation

// MARK: - Core Model

/// Unified content type for all Mira bridge communication.
/// Replaces TBMessage, TBThread, and MiraTask.
public struct MiraItem: Codable, Identifiable, Equatable {
    public let id: String
    public var type: ItemType
    public var title: String
    public var status: ItemStatus
    public var tags: [String]
    public var origin: ItemOrigin
    public var pinned: Bool
    public var quick: Bool
    public var parentId: String?
    public var createdAt: String
    public var updatedAt: String
    public var messages: [ItemMessage]
    public var error: ItemError?
    public var resultPath: String?

    enum CodingKeys: String, CodingKey {
        case id, type, title, status, tags, origin, pinned, quick
        case parentId = "parent_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case messages, error
        case resultPath = "result_path"
        // Legacy key used by older agent code for origin
        case sender
    }

    public init(id: String, type: ItemType, title: String, status: ItemStatus,
                tags: [String], origin: ItemOrigin, pinned: Bool, quick: Bool,
                parentId: String? = nil, createdAt: String, updatedAt: String,
                messages: [ItemMessage], error: ItemError? = nil, resultPath: String? = nil) {
        self.id = id; self.type = type; self.title = title; self.status = status
        self.tags = tags; self.origin = origin; self.pinned = pinned; self.quick = quick
        self.parentId = parentId; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.messages = messages; self.error = error; self.resultPath = resultPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = (try? c.decode(ItemType.self, forKey: .type)) ?? .feed
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        status = (try? c.decode(ItemStatus.self, forKey: .status)) ?? .done
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        origin = (try? c.decode(ItemOrigin.self, forKey: .origin))
            ?? ((try? c.decode(String.self, forKey: .sender)).map { $0 == "user" ? .user : .agent } ?? .agent)
        pinned = (try? c.decode(Bool.self, forKey: .pinned)) ?? false
        quick = (try? c.decode(Bool.self, forKey: .quick)) ?? false
        parentId = try? c.decodeIfPresent(String.self, forKey: .parentId)
        createdAt = (try? c.decode(String.self, forKey: .createdAt)) ?? ""
        updatedAt = (try? c.decode(String.self, forKey: .updatedAt)) ?? ""
        messages = (try? c.decode([ItemMessage].self, forKey: .messages)) ?? []
        error = try? c.decodeIfPresent(ItemError.self, forKey: .error)
        resultPath = try? c.decodeIfPresent(String.self, forKey: .resultPath)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(title, forKey: .title)
        try c.encode(status, forKey: .status)
        try c.encode(tags, forKey: .tags)
        try c.encode(origin, forKey: .origin)
        try c.encode(pinned, forKey: .pinned)
        try c.encode(quick, forKey: .quick)
        try c.encodeIfPresent(parentId, forKey: .parentId)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(messages, forKey: .messages)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(resultPath, forKey: .resultPath)
    }
}

public enum ItemType: String, Codable {
    case request, discussion, feed
}

public enum ItemStatus: String, Codable {
    case queued, working
    case needsInput = "needs-input"
    case done, failed, archived
}

public enum ItemOrigin: String, Codable {
    case user, agent
    // Decode unknown origins as agent
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = ItemOrigin(rawValue: value) ?? .agent
    }
}

// MARK: - Messages

public struct ItemMessage: Codable, Identifiable, Equatable {
    public let id: String
    public let sender: String
    public let content: String
    public let timestamp: String
    public var kind: MessageKind
    public var imagePath: String?  // relative to iCloud MtJoy/Mira-Artifacts/{user}/ container

    enum CodingKeys: String, CodingKey {
        case id, sender, content, timestamp, kind
        case imagePath = "image_path"
        // Legacy key from older agent code
        case role
    }

    public init(id: String, sender: String, content: String, timestamp: String,
                kind: MessageKind = .text, imagePath: String? = nil) {
        self.id = id; self.sender = sender; self.content = content
        self.timestamp = timestamp; self.kind = kind; self.imagePath = imagePath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString.prefix(8).lowercased()
        // Accept "sender" or fall back to "role" (legacy agent format)
        sender = (try? c.decode(String.self, forKey: .sender))
            ?? (try? c.decode(String.self, forKey: .role))
            ?? "agent"
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        timestamp = (try? c.decode(String.self, forKey: .timestamp)) ?? ISO8601DateFormatter.shared.string(from: Date())
        kind = (try? c.decode(MessageKind.self, forKey: .kind)) ?? .text
        imagePath = try? c.decodeIfPresent(String.self, forKey: .imagePath)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sender, forKey: .sender)
        try c.encode(content, forKey: .content)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(imagePath, forKey: .imagePath)
    }

    public var date: Date {
        ISO8601DateFormatter.flexibleDate(from: timestamp) ?? .distantPast
    }

    public var isAgent: Bool { sender == "agent" }
    public var isUser: Bool { !isAgent }

    /// Parse status card content if kind is statusCard
    public var statusCard: StatusCard? {
        guard kind == .statusCard else { return nil }
        guard let data = content.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = dict["text"] as? String else { return nil }
        return StatusCard(text: text, icon: dict["icon"] as? String ?? "gear")
    }
}

public enum MessageKind: String, Codable {
    case text
    case statusCard = "status_card"
    case error
    case recall

    // Decode unknown kinds as text
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = MessageKind(rawValue: value) ?? .text
    }
}

public struct StatusCard {
    public let text: String
    public let icon: String
}

// MARK: - Error

public struct ItemError: Codable, Equatable {
    public let code: String
    public let message: String
    public let retryable: Bool
    public let timestamp: String
}

// MARK: - Heartbeat

public struct MiraHeartbeat: Codable {
    public let timestamp: String
    public let status: String
    public var busy: Bool?
    public var activeCount: Int?

    enum CodingKeys: String, CodingKey {
        case timestamp, status, busy
        case activeCount = "active_count"
    }

    public var date: Date {
        ISO8601DateFormatter.flexibleDate(from: timestamp) ?? .distantPast
    }

    public var isRecent: Bool {
        Date().timeIntervalSince(date) < 600
    }

    public var isBusy: Bool { busy ?? false }
}

// MARK: - Manifest

public struct MiraManifest: Codable {
    public let updatedAt: String
    public let items: [ManifestEntry]

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case items
    }
}

public struct ManifestEntry: Codable {
    public let id: String
    public let type: String
    public let status: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, type, status
        case updatedAt = "updated_at"
    }
}

// MARK: - Commands (iOS → Agent)

public struct MiraCommand: Codable {
    public let id: String
    public let type: String
    public let timestamp: String
    public var sender: String
    public var title: String?
    public var content: String?
    public var itemId: String?
    public var parentId: String?
    public var tags: [String]?
    public var quick: Bool?
    public var pinned: Bool?
    public var query: String?

    enum CodingKeys: String, CodingKey {
        case id, type, timestamp, sender, title, content
        case itemId = "item_id"
        case parentId = "parent_id"
        case tags, quick, pinned, query
    }
}

// MARK: - Computed Properties

extension MiraItem {
    public var date: Date {
        ISO8601DateFormatter.flexibleDate(from: updatedAt) ?? .distantPast
    }

    public var createdDate: Date {
        ISO8601DateFormatter.flexibleDate(from: createdAt) ?? .distantPast
    }

    public var isActive: Bool {
        [.queued, .working, .needsInput].contains(status)
    }

    public var needsAttention: Bool {
        status == .needsInput && !messages.contains(where: { $0.sender == "user" })
    }

    public var lastMessage: ItemMessage? {
        messages.last
    }

    public var lastMessagePreview: String {
        guard let msg = lastMessage else { return "" }
        if msg.kind == .statusCard, let card = msg.statusCard {
            return card.text
        }
        return String(msg.content.prefix(100))
    }

    public var statusIcon: String {
        switch status {
        case .queued: return "clock"
        case .working: return "circle.dotted.circle"
        case .needsInput: return "exclamationmark.bubble"
        case .done: return "checkmark.circle"
        case .failed: return "xmark.circle"
        case .archived: return "archivebox"
        }
    }

    public var statusColor: String {
        switch status {
        case .queued: return "secondary"
        case .working: return "blue"
        case .needsInput: return "orange"
        case .done: return "green"
        case .failed: return "red"
        case .archived: return "secondary"
        }
    }

    public var typeIcon: String {
        switch type {
        case .request: return "arrow.up.circle"
        case .discussion: return "bubble.left.and.bubble.right"
        case .feed: return "doc.text"
        }
    }
}

// MARK: - Profile

public struct MiraProfile: Codable, Identifiable, Hashable {
    public let id: String
    public let displayName: String
    public let agentName: String
    public var avatar: String

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case agentName = "agent_name"
        case avatar
    }
}

public struct MiraProfiles: Codable {
    public let profiles: [MiraProfile]
}

// MARK: - Todo

public struct MiraTodo: Codable, Identifiable, Equatable {
    public let id: String
    public var title: String
    public var priority: String   // high, medium, low
    public var status: String     // pending, working, done
    public var tags: [String]
    public var createdAt: String
    public var updatedAt: String
    public var followups: [TodoFollowup]

    enum CodingKeys: String, CodingKey {
        case id, title, priority, status, tags
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case followups
    }

    public init(id: String, title: String, priority: String = "medium", status: String = "pending",
         tags: [String] = [], createdAt: String = "", updatedAt: String = "", followups: [TodoFollowup] = []) {
        self.id = id; self.title = title; self.priority = priority; self.status = status
        self.tags = tags; self.createdAt = createdAt; self.updatedAt = updatedAt; self.followups = followups
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        priority = try c.decodeIfPresent(String.self, forKey: .priority) ?? "medium"
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        followups = try c.decodeIfPresent([TodoFollowup].self, forKey: .followups) ?? []
    }

    public var date: Date {
        ISO8601DateFormatter.flexibleDate(from: updatedAt) ?? .distantPast
    }

    public var priorityOrder: Int {
        switch priority {
        case "high": return 0
        case "medium": return 1
        case "low": return 2
        default: return 1
        }
    }
}

public struct TodoFollowup: Codable, Equatable {
    public let content: String
    public let source: String    // "agent" or "user"
    public let timestamp: String

    public init(content: String, source: String, timestamp: String) {
        self.content = content; self.source = source; self.timestamp = timestamp
    }

    public var date: Date {
        ISO8601DateFormatter.flexibleDate(from: timestamp) ?? .distantPast
    }
}

// MARK: - Command Ledger (agent → app delivery confirmation)

public struct CommandLedger: Codable {
    public let processed: [String: String]  // command_id → processed_timestamp
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case processed
        case updatedAt = "updated_at"
    }
}

// MARK: - ISO8601 Shared Formatter

extension ISO8601DateFormatter {
    public static let shared: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Fallback without fractional seconds for older timestamps
    public static let noFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parse ISO8601 with or without fractional seconds
    public static func flexibleDate(from string: String) -> Date? {
        shared.date(from: string) ?? noFraction.date(from: string)
    }
}
