import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Writes command files to commands/ directory. Fire-and-forget.
@Observable
public final class CommandWriter {
    public let config: BridgeConfig
    weak var store: ItemStore?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    /// Track pending commands for delivery confirmation
    public var pendingIds: Set<String> = []

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
        let ts = now()
        write(MiraCommand(
            id: id, type: "new_request", timestamp: ts, sender: senderID,
            title: title, content: content, tags: tags.isEmpty ? nil : tags, quick: quick
        ))
        // Optimistic: show immediately
        store?.upsert(MiraItem(
            id: "req_\(id)", type: .request, title: title, status: .queued,
            tags: tags, origin: .user, pinned: false, quick: quick, parentId: nil,
            createdAt: ts, updatedAt: ts,
            messages: [ItemMessage(id: id, sender: senderID, content: content, timestamp: ts, kind: .text)],
            error: nil, resultPath: nil
        ))
    }

    public func createDiscussion(title: String, content: String, tags: [String] = []) {
        let id = cmdId()
        let ts = now()
        write(MiraCommand(
            id: id, type: "new_discussion", timestamp: ts, sender: senderID,
            title: title, content: content, tags: tags.isEmpty ? nil : tags
        ))
        // Optimistic: show immediately
        store?.upsert(MiraItem(
            id: "disc_\(id)", type: .discussion, title: title, status: .queued,
            tags: tags, origin: .user, pinned: false, quick: false, parentId: nil,
            createdAt: ts, updatedAt: ts,
            messages: [ItemMessage(id: id, sender: senderID, content: content, timestamp: ts, kind: .text)],
            error: nil, resultPath: nil
        ))
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
        write(MiraCommand(
            id: id, type: "reply", timestamp: ts, sender: senderID,
            content: content, itemId: itemId
        ))
        // Optimistic: show reply immediately in local UI
        store?.appendMessage(to: itemId, message: ItemMessage(
            id: id, sender: senderID, content: content, timestamp: ts, kind: .text
        ))
    }

    public func todoFollowup(todoId: String, content: String) {
        write(MiraCommand(
            id: cmdId(), type: "todo_followup", timestamp: now(), sender: senderID,
            content: content, itemId: todoId
        ))
    }

    public func cancel(itemId: String) {
        write(MiraCommand(
            id: cmdId(), type: "cancel", timestamp: now(), sender: senderID,
            itemId: itemId
        ))
    }

    public func recall(query: String) {
        write(MiraCommand(
            id: cmdId(), type: "recall", timestamp: now(), sender: senderID,
            query: query
        ))
    }

    public func archive(itemId: String) {
        write(MiraCommand(
            id: cmdId(), type: "archive", timestamp: now(), sender: senderID,
            itemId: itemId
        ))
    }

    public func pin(itemId: String, pinned: Bool) {
        write(MiraCommand(
            id: cmdId(), type: "pin", timestamp: now(), sender: senderID,
            itemId: itemId, pinned: pinned
        ))
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

    // MARK: - Internal

    private func write(_ command: MiraCommand) {
        guard let dir = config.commandsDir else { return }
        let ts = Self.dateStamp()
        let filename = "cmd_\(ts)_\(command.id).json"
        let url = dir.appending(path: filename)
        do {
            let data = try encoder.encode(command)
            try data.write(to: url, options: .atomic)
            pendingIds.insert(command.id)
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
