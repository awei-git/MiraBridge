import Foundation
import Observation

/// Single source of truth for all MiraItems in memory.
/// Provides computed views by type, status, and tags.
@Observable
public final class ItemStore {
    private(set) public var items: [MiraItem] = []
    private var itemsById: [String: Int] = [:]  // id → index in items array

    public init() {}

    // MARK: - Computed Views

    public var hasActiveItems: Bool {
        items.contains { $0.isActive }
    }

    public var needsAttention: [MiraItem] {
        items.filter(\.needsAttention).sorted { $0.date > $1.date }
    }

    public var activeRequests: [MiraItem] {
        items.filter { $0.isActive && $0.type == .request }
            .sorted { $0.date > $1.date }
    }

    public var feeds: [MiraItem] {
        items.filter { $0.type == .feed && $0.status != .archived }
            .sorted { $0.date > $1.date }
    }

    public var todayFeeds: [MiraItem] {
        let cal = Calendar.current
        return feeds.filter { cal.isDateInToday($0.createdDate) }
    }

    public var discussions: [MiraItem] {
        items.filter { $0.type == .discussion && $0.status != .archived }
            .sorted { $0.date > $1.date }
    }

    public var pinnedItems: [MiraItem] {
        items.filter(\.pinned).sorted { $0.date > $1.date }
    }

    public var doneItems: [MiraItem] {
        items.filter { $0.status == .done }
            .sorted { $0.date > $1.date }
    }

    /// All non-archived items, sorted by update time
    public var allVisible: [MiraItem] {
        items.filter { $0.status != .archived }
            .sorted { $0.date > $1.date }
    }

    /// Group items by day for display
    public var groupedByDay: [(key: String, items: [MiraItem])] {
        let cal = Calendar.current
        let visible = allVisible
        var groups: [String: [MiraItem]] = [:]

        for item in visible {
            let key: String
            if cal.isDateInToday(item.date) {
                key = "今天"
            } else if cal.isDateInYesterday(item.date) {
                key = "昨天"
            } else {
                let df = DateFormatter()
                df.dateFormat = "M月d日"
                key = df.string(from: item.date)
            }
            groups[key, default: []].append(item)
        }

        // Sort groups: today first, then yesterday, then by date descending
        let order = ["今天", "昨天"]
        func sortKey(_ key: String) -> Int { order.firstIndex(of: key) ?? 99 }
        func firstDate(_ items: [MiraItem]) -> Date { items.first?.date ?? .distantPast }

        let keys = groups.keys.sorted { (k1: String, k2: String) -> Bool in
            let s1 = sortKey(k1), s2 = sortKey(k2)
            if s1 != s2 { return s1 < s2 }
            return firstDate(groups[k1]!) > firstDate(groups[k2]!)
        }
        return keys.map { (key: $0, items: groups[$0]!) }
    }

    // MARK: - Filtering

    public func filtered(type: ItemType? = nil, tag: String? = nil, status: ItemStatus? = nil) -> [MiraItem] {
        items.filter { item in
            if item.status == .archived { return false }
            if let t = type, item.type != t { return false }
            if let s = status, item.status != s { return false }
            if let tag = tag, !item.tags.contains(tag) { return false }
            return true
        }.sorted { $0.date > $1.date }
    }

    public func search(_ query: String) -> [MiraItem] {
        let q = query.lowercased()
        return items.filter { item in
            item.title.lowercased().contains(q) ||
            item.tags.contains(where: { $0.lowercased().contains(q) }) ||
            item.messages.first?.content.lowercased().contains(q) == true
        }.sorted { $0.date > $1.date }
    }

    // MARK: - Mutations

    public func upsert(_ item: MiraItem) {
        if let idx = itemsById[item.id] {
            items[idx] = item
        } else {
            items.append(item)
            itemsById[item.id] = items.count - 1
        }
    }

    public func remove(_ id: String) {
        if let idx = itemsById[id] {
            items.remove(at: idx)
            rebuildIndex()
        }
    }

    public func item(for id: String) -> MiraItem? {
        guard let idx = itemsById[id] else { return nil }
        return items[idx]
    }

    public func appendMessage(to itemId: String, message: ItemMessage) {
        guard let idx = itemsById[itemId] else { return }
        items[idx].messages.append(message)
        items[idx].updatedAt = message.timestamp
    }

    private func rebuildIndex() {
        itemsById = [:]
        for (i, item) in items.enumerated() {
            itemsById[item.id] = i
        }
    }

    // MARK: - Local Cache

    private var cacheURL: URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true)
            .appending(path: "items_cache.json")
    }

    public func saveToCache() {
        guard let url = cacheURL else { return }
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: url, options: .atomic)
        } catch { }
    }

    public func loadFromCache() {
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode([MiraItem].self, from: data) else { return }
        items = cached
        rebuildIndex()
    }
}
