import Foundation
import Observation
import SwiftData

@Model
final class PersistedMiraItem {
    @Attribute(.unique) var id: String
    var updatedAt: String
    var sortTimestamp: Date
    @Attribute(.externalStorage) var payload: Data

    init(id: String, updatedAt: String, sortTimestamp: Date, payload: Data) {
        self.id = id
        self.updatedAt = updatedAt
        self.sortTimestamp = sortTimestamp
        self.payload = payload
    }
}

/// Single source of truth for all MiraItems in memory.
/// Provides computed views by type, status, and tags.
@Observable
public final class ItemStore {
    private(set) public var items: [MiraItem] = []
    private var itemsById: [String: Int] = [:]  // id → index in items array
    @ObservationIgnored private var modelContainer: ModelContainer?
    @ObservationIgnored private var modelContext: ModelContext?
    private static let persistedItemLimit = 120

    public init() {
        configureSwiftData()
    }

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

    private static let groupByDayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "M月d日"
        return df
    }()

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
                key = Self.groupByDayFormatter.string(from: item.date)
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
        schedulePersistenceSave()
    }

    /// Batch upsert: apply all changes to a local copy, then assign once
    /// so @Observable fires a single update instead of one per item.
    public func batchUpsert(_ newItems: [MiraItem]) {
        guard !newItems.isEmpty else { return }
        var updated = items
        var index = itemsById
        for item in newItems {
            if let idx = index[item.id] {
                updated[idx] = item
            } else {
                index[item.id] = updated.count
                updated.append(item)
            }
        }
        items = updated
        itemsById = index
        schedulePersistenceSave()
    }

    public func remove(_ id: String) {
        if let idx = itemsById[id] {
            items.remove(at: idx)
            rebuildIndex()
            deletePersistedItem(id)
            schedulePersistenceSave()
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
        schedulePersistenceSave()
    }

    private func rebuildIndex() {
        itemsById = [:]
        for (i, item) in items.enumerated() {
            itemsById[item.id] = i
        }
    }

    // MARK: - Local Persistence

    private var pendingSave: DispatchWorkItem?
    private static let saveDebounceSec: TimeInterval = 2.0

    private var legacyCacheURL: URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true)
            .appending(path: "items_cache.json")
    }

    private func configureSwiftData() {
        do {
            let schema = Schema([PersistedMiraItem.self])
            let configuration = ModelConfiguration("MiraItems", schema: schema)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            modelContainer = container
            modelContext = ModelContext(container)
        } catch {
            modelContainer = nil
            modelContext = nil
            #if DEBUG
            print("[ItemStore] SwiftData unavailable: \(error)")
            #endif
        }
    }

    /// Schedule a debounced SwiftData write. Resets the timer on each call so
    /// rapid mutations coalesce into a single persistence pass after 2 s of quiet.
    private func schedulePersistenceSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.persistNow()
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDebounceSec, execute: work)
    }

    /// Write SwiftData immediately (e.g. when app is about to background).
    public func saveToCache() {
        pendingSave?.cancel()
        persistNow()
    }

    /// Synchronously load persisted items. Prefer loadFromCacheAsync at app
    /// startup; this remains for background refresh and compatibility.
    public func loadFromCache() {
        if loadFromSwiftData() { return }
        migrateLegacyJSONCache()
    }

    /// Load persisted items without blocking SwiftUI startup. SwiftData work
    /// uses a fresh background context because ModelContext is queue-bound.
    public func loadFromCacheAsync(completion: (() -> Void)? = nil) {
        guard let modelContainer else {
            loadLegacyJSONCacheAsync(completion: completion)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self, modelContainer] in
            let context = ModelContext(modelContainer)
            let decoded: [MiraItem]
            do {
                var descriptor = FetchDescriptor<PersistedMiraItem>(
                    sortBy: [SortDescriptor(\.sortTimestamp, order: .reverse)]
                )
                descriptor.fetchLimit = Self.persistedItemLimit
                let stored = try context.fetch(descriptor)
                decoded = stored.compactMap { (row: PersistedMiraItem) -> MiraItem? in
                    guard let item = try? JSONDecoder().decode(MiraItem.self, from: row.payload) else { return nil }
                    return Self.listSummary(item)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.loadLegacyJSONCacheAsync(completion: completion)
                }
                return
            }

            DispatchQueue.main.async {
                guard let self else {
                    completion?()
                    return
                }
                if decoded.isEmpty {
                    self.loadLegacyJSONCacheAsync(completion: completion)
                    return
                }
                self.items = decoded
                self.rebuildIndex()
                completion?()
            }
        }
    }

    private func loadFromSwiftData() -> Bool {
        guard let modelContext else { return false }
        do {
            var descriptor = FetchDescriptor<PersistedMiraItem>(
                sortBy: [SortDescriptor(\.sortTimestamp, order: .reverse)]
            )
            descriptor.fetchLimit = Self.persistedItemLimit
            let stored = try modelContext.fetch(descriptor)
            let decoded: [MiraItem] = stored.compactMap { (row: PersistedMiraItem) -> MiraItem? in
                guard let item = try? JSONDecoder().decode(MiraItem.self, from: row.payload) else { return nil }
                return Self.listSummary(item)
            }
            guard !decoded.isEmpty else { return false }
            items = decoded
            rebuildIndex()
            return true
        } catch {
            #if DEBUG
            print("[ItemStore] SwiftData read failed: \(error)")
            #endif
            return false
        }
    }

    private func migrateLegacyJSONCache() {
        guard let url = legacyCacheURL,
              let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode([MiraItem].self, from: data),
              !cached.isEmpty else { return }
        items = Array(cached.sorted { $0.date > $1.date }
            .prefix(Self.persistedItemLimit)
            .map(Self.listSummary))
        rebuildIndex()
        persistNow()
    }

    private func loadLegacyJSONCacheAsync(completion: (() -> Void)? = nil) {
        guard let url = legacyCacheURL else {
            completion?()
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let cached: [MiraItem]
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode([MiraItem].self, from: data),
               !decoded.isEmpty {
                cached = Array(decoded.sorted { $0.date > $1.date }
                    .prefix(Self.persistedItemLimit)
                    .map(Self.listSummary))
            } else {
                cached = []
            }
            DispatchQueue.main.async {
                guard let self else {
                    completion?()
                    return
                }
                if !cached.isEmpty {
                    self.items = cached
                    self.rebuildIndex()
                    self.schedulePersistenceSave()
                }
                completion?()
            }
        }
    }

    private func persistNow() {
        guard let modelContainer else { return }
        let itemsToPersist = Array(items.sorted { $0.date > $1.date }.prefix(Self.persistedItemLimit))
        persistSnapshotAsync(itemsToPersist, modelContainer: modelContainer)
    }

    private func persistSnapshotAsync(_ itemsToPersist: [MiraItem], modelContainer: ModelContainer) {
        DispatchQueue.global(qos: .utility).async {
            let modelContext = ModelContext(modelContainer)
            do {
                let stored = try modelContext.fetch(FetchDescriptor<PersistedMiraItem>())
                var storedById = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
                let encoder = JSONEncoder()

                let currentIds = Set(itemsToPersist.map(\.id))

                for item in itemsToPersist {
                    let data = try encoder.encode(item)
                    if let existing = storedById.removeValue(forKey: item.id) {
                        existing.updatedAt = item.updatedAt
                        existing.sortTimestamp = item.date
                        existing.payload = data
                    } else {
                        modelContext.insert(PersistedMiraItem(
                            id: item.id,
                            updatedAt: item.updatedAt,
                            sortTimestamp: item.date,
                            payload: data
                        ))
                    }
                }

                for stale in storedById.values where !currentIds.contains(stale.id) {
                    modelContext.delete(stale)
                }
                try modelContext.save()
            } catch {
                #if DEBUG
                print("[ItemStore] SwiftData write failed: \(error)")
                #endif
            }
        }
    }

    private static func listSummary(_ item: MiraItem) -> MiraItem {
        var summary = item
        if let lastDisplayMessage = item.messages.last(where: { $0.kind != .statusCard }) ?? item.messages.last {
            summary.messages = [lastDisplayMessage]
        } else {
            summary.messages = []
        }
        return summary
    }

    private func deletePersistedItem(_ id: String) {
        guard let modelContext else { return }
        do {
            let descriptor = FetchDescriptor<PersistedMiraItem>(
                predicate: #Predicate { $0.id == id }
            )
            for item in try modelContext.fetch(descriptor) {
                modelContext.delete(item)
            }
        } catch {
            #if DEBUG
            print("[ItemStore] SwiftData delete failed: \(error)")
            #endif
        }
    }
}
