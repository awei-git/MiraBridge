import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Writes command files to commands/ directory. Fire-and-forget.
@Observable
public final class CommandWriter {
    public static let dailyCollabItemId = "disc_daily_collab"
    public static let dailyCollabTags = ["daily-collab", "mira", "conversation"]

    public let config: BridgeConfig
    weak var store: ItemStore?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    /// Track pending commands for delivery confirmation
    public var pendingIds: Set<String> = []
    private let pendingAPIKey = "mira_pending_api_requests"

    public init(config: BridgeConfig, store: ItemStore? = nil) {
        self.config = config
        self.store = store
    }

    public var senderID: String {
        #if canImport(UIKit)
        let name = UIDevice.current.name.lowercased()
        #else
        let name = Host.current().localizedName?.lowercased() ?? "mac"
        #endif
        let clean = name.components(separatedBy: "'").first ?? name
        return clean.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_")
    }

    // MARK: - Commands

    public func createRequest(title: String, content: String, quick: Bool = false, tags: [String] = []) {
        let id = cmdId()
        let itemId = "req_\(id)"
        let ts = now()
        let command = MiraCommand(
            id: id, type: "new_request", timestamp: ts, sender: senderID,
            title: title, content: content, itemId: itemId,
            tags: tags.isEmpty ? nil : tags, quick: quick
        )
        // Optimistic: show immediately
        let item = MiraItem(
            id: itemId, type: .request, title: title, status: .queued,
            tags: tags, origin: .user, pinned: false, quick: quick, parentId: nil,
            createdAt: ts, updatedAt: ts,
            messages: [ItemMessage(id: id, sender: senderID, content: content, timestamp: ts, kind: .text)],
            error: nil, resultPath: nil
        )
        store?.upsert(item)
        submitTask(command, itemType: .request)
    }

    public func createDiscussion(title: String, content: String, tags: [String] = []) {
        createDiscussion(title: title, content: content, tags: tags, commandId: cmdId())
    }

    public func createDailyCollabThread() {
        createDiscussion(
            title: "Mira",
            content: "Start the single Mira discussion thread. Use this as the main collaboration surface.",
            tags: Self.dailyCollabTags,
            commandId: Self.dailyCollabItemId
        )
    }

    private func createDiscussion(title: String, content: String, tags: [String], commandId: String) {
        let id = commandId
        let itemId = id.hasPrefix("disc_") ? id : "disc_\(id)"
        let ts = now()
        let command = MiraCommand(
            id: id, type: "new_discussion", timestamp: ts, sender: senderID,
            title: title, content: content, itemId: itemId,
            tags: tags.isEmpty ? nil : tags
        )
        // Optimistic: show immediately
        let item = MiraItem(
            id: itemId, type: .discussion, title: title, status: .queued,
            tags: tags, origin: .user, pinned: false, quick: false, parentId: nil,
            createdAt: ts, updatedAt: ts,
            messages: [ItemMessage(id: id, sender: senderID, content: content, timestamp: ts, kind: .text)],
            error: nil, resultPath: nil
        )
        store?.upsert(item)
        submitTask(command, itemType: .discussion)
    }

    public func comment(parentId: String, content: String) {
        write(MiraCommand(
            id: cmdId(), type: "comment", timestamp: now(), sender: senderID,
            content: content, parentId: parentId
        ))
    }

    public func reply(to itemId: String, content: String) {
        let id = cmdId()
        let ts = now()
        let command = MiraCommand(
            id: id, type: "reply", timestamp: ts, sender: senderID,
            content: content, itemId: itemId
        )
        // Optimistic: show reply immediately in local UI
        store?.appendMessage(to: itemId, message: ItemMessage(
            id: id, sender: senderID, content: content, timestamp: ts, kind: .text
        ))
        submitReply(command)
    }

    public func todoFollowup(todoId: String, content: String) {
        write(MiraCommand(
            id: cmdId(), type: "todo_followup", timestamp: now(), sender: senderID,
            content: content, itemId: todoId
        ))
    }

    public func cancel(itemId: String) {
        let command = MiraCommand(
            id: cmdId(), type: "cancel", timestamp: now(), sender: senderID,
            itemId: itemId
        )
        sendOrQueue(path: "tasks/\(itemId)/cancel", payload: EmptyPayload(), fallback: command)
    }

    public func recall(query: String) {
        write(MiraCommand(
            id: cmdId(), type: "recall", timestamp: now(), sender: senderID,
            query: query
        ))
    }

    public func archive(itemId: String) {
        let command = MiraCommand(
            id: cmdId(), type: "archive", timestamp: now(), sender: senderID,
            itemId: itemId
        )
        sendOrQueue(path: "tasks/\(itemId)/archive", payload: EmptyPayload(), fallback: command)
    }

    public func pin(itemId: String, pinned: Bool) {
        let command = MiraCommand(
            id: cmdId(), type: "pin", timestamp: now(), sender: senderID,
            itemId: itemId, pinned: pinned
        )
        sendOrQueue(path: "tasks/\(itemId)/pin", payload: PinPayload(pinned: pinned), fallback: command)
    }

    public func tag(itemId: String, tags: [String]) {
        write(MiraCommand(
            id: cmdId(), type: "tag", timestamp: now(), sender: senderID,
            itemId: itemId, tags: tags
        ))
    }

    // MARK: - Delivery Confirmation

    public func confirmDelivery(_ confirmedIds: Set<String>) {
        pendingIds.subtract(confirmedIds)
    }

    public func flushPendingAPIQueue() {
        var queue = loadPendingAPIRequests()
        guard !queue.isEmpty else { return }
        let request = queue.removeFirst()
        postAPIData(path: request.path, body: request.body) { [weak self] ok in
            guard let self else { return }
            if ok {
                self.savePendingAPIRequests(queue)
                self.flushPendingAPIQueue()
            }
        }
    }

    // MARK: - Internal

    private struct TaskCreatePayload: Encodable {
        let title: String
        let content: String
        let quick: Bool
        let tags: [String]
        let clientRequestId: String
        let type: String

        enum CodingKeys: String, CodingKey {
            case title, content, quick, tags, type
            case clientRequestId = "client_request_id"
        }
    }

    private struct ReplyPayload: Encodable {
        let content: String
    }

    private struct PinPayload: Encodable {
        let pinned: Bool
    }

    private struct EmptyPayload: Encodable {}

    private struct PendingAPIRequest: Codable {
        let id: String
        let path: String
        let body: Data
        let createdAt: String
    }

    private func submitTask(_ command: MiraCommand, itemType: ItemType) {
        guard let title = command.title, let content = command.content else {
            write(command)
            return
        }
        let payload = TaskCreatePayload(
            title: title,
            content: content,
            quick: command.quick ?? false,
            tags: command.tags ?? [],
            clientRequestId: command.id,
            type: itemType.rawValue
        )
        sendOrQueue(path: "tasks", payload: payload, fallback: command)
    }

    private func submitReply(_ command: MiraCommand) {
        guard let itemId = command.itemId, let content = command.content else {
            write(command)
            return
        }
        sendOrQueue(path: "tasks/\(itemId)/reply", payload: ReplyPayload(content: content), fallback: command)
    }

    private func sendOrQueue<T: Encodable>(path: String, payload: T, fallback command: MiraCommand) {
        do {
            let body = try JSONEncoder().encode(payload)
            postAPIData(path: path, body: body) { [weak self] ok in
                guard let self else { return }
                if ok { return }
                if self.config.apiWriteFallbackToICloud {
                    self.write(command)
                } else {
                    self.enqueuePendingAPIRequest(path: path, body: body, id: command.id)
                }
            }
        } catch {
            write(command)
        }
    }

    private func postAPIData(path: String, body: Data, completion: @escaping (Bool) -> Void) {
        let userId = config.profile?.id ?? "ang"
        config.startServerDiscovery()
        let base = config.serverURL ?? BridgeConfig.defaultServerURL
        let url = base.appending(path: "api/\(userId)/\(path)")
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        MiraPinnedURLSession.shared.dataTask(with: request) { _, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            completion((200..<300).contains(code))
        }.resume()
    }

    private func enqueuePendingAPIRequest(path: String, body: Data, id: String) {
        var queue = loadPendingAPIRequests()
        if queue.contains(where: { $0.id == id }) { return }
        queue.append(PendingAPIRequest(id: id, path: path, body: body, createdAt: now()))
        savePendingAPIRequests(queue)
        DispatchQueue.main.async { [weak self] in
            self?.pendingIds.insert(id)
        }
    }

    private func loadPendingAPIRequests() -> [PendingAPIRequest] {
        guard let data = UserDefaults.standard.data(forKey: pendingAPIKey),
              let queue = try? JSONDecoder().decode([PendingAPIRequest].self, from: data) else {
            return []
        }
        return queue
    }

    private func savePendingAPIRequests(_ queue: [PendingAPIRequest]) {
        if queue.isEmpty {
            UserDefaults.standard.removeObject(forKey: pendingAPIKey)
            return
        }
        if let data = try? JSONEncoder().encode(queue) {
            UserDefaults.standard.set(data, forKey: pendingAPIKey)
        }
    }

    private func write(_ command: MiraCommand) {
        guard let dir = config.commandsDir else { return }
        let ts = Self.dateStamp()
        let filename = "cmd_\(ts)_\(command.id).json"
        let url = dir.appending(path: filename)
        do {
            let data = try encoder.encode(command)
            try data.write(to: url, options: .atomic)
            DispatchQueue.main.async { [weak self] in
                self?.pendingIds.insert(command.id)
            }
        } catch { }
    }

    private func cmdId() -> String {
        UUID().uuidString.prefix(8).lowercased()
    }

    private func now() -> String {
        ISO8601DateFormatter.shared.string(from: Date())
    }

    private static func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date())
    }
}
