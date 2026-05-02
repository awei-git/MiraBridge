import Foundation
import Observation

/// Polls Mira API first, then falls back to iCloud bridge files.
@Observable
public final class SyncEngine {
    public let config: BridgeConfig
    public let store: ItemStore
    public weak var commands: CommandWriter?

    public var heartbeat: MiraHeartbeat?
    public var lastManifest: MiraManifest?
    /// Agent is online if the API is reachable, or any local snapshot is recent.
    public var agentOnline: Bool {
        apiOnline || heartbeat?.isRecent == true || lastManifest?.isRecent == true
    }
    public var syncing: Bool = false
    public var heartbeatDebug: String = "waiting..."
    public var apiOnline: Bool = false

    private var timer: Timer?
    private var eventStreamTask: Task<Void, Never>?
    private var fastPollCount: Int = 0
    private static let fastPollMax = 10      // fast-poll up to 10 times (30s)
    private static let fastPollInterval: TimeInterval = 3
    private var manifestTimestamps: [String: String] = [:]  // id → updated_at
    private let decoder = JSONDecoder()
    private var metadataQuery: NSMetadataQuery?

    public init(config: BridgeConfig, store: ItemStore) {
        self.config = config
        self.store = store
    }

    // MARK: - Polling

    public func startPolling() {
        timer?.invalidate()
        config.startServerDiscovery()
        // Fast-poll for first 30s after app opens to get fresh heartbeat quickly
        fastPollCount = 0
        _scheduleNextPoll()
        _startHeartbeatMonitor()
        _startEventStream()
        // First refresh immediately
        Task { @MainActor [weak self] in self?.refresh() }
    }

    /// Watch heartbeat.json AND manifest.json via NSMetadataQuery — refresh
    /// the moment iCloud delivers a change to either file, instead of waiting
    /// for the next polling tick. Pre-2026-04-27: only heartbeat was watched,
    /// so item-list changes had to wait up to 60s for the timer.
    private func _startHeartbeatMonitor() {
        guard metadataQuery == nil else { return }
        var paths: [String] = []
        if let hb = config.heartbeatURL { paths.append(hb.path) }
        if let mf = config.manifestURL { paths.append(mf.path) }
        guard !paths.isEmpty else { return }
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "%K IN %@", NSMetadataItemPathKey, paths)
        q.searchScopes = [NSMetadataQueryUbiquitousDataScope, NSMetadataQueryUbiquitousDocumentsScope]
        NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate, object: q, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        q.start()
        metadataQuery = q
    }

    private func _scheduleNextPoll() {
        timer?.invalidate()
        let interval: TimeInterval
        if !agentOnline && fastPollCount < Self.fastPollMax {
            interval = Self.fastPollInterval
        } else {
            interval = store.hasActiveItems ? 20 : 60
        }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.agentOnline { self.fastPollCount += 1 }
                self.refresh()
            }
        }
    }

    public func stopPolling() {
        timer?.invalidate()
        timer = nil
        eventStreamTask?.cancel()
        eventStreamTask = nil
    }

    public func refresh(completion: (() -> Void)? = nil) {
        guard config.isSetup, !syncing else {
            if !config.isSetup { debugLog = "bridge not configured" }
            else if syncing { debugLog = "sync in progress" }
            completion?()
            return
        }
        syncing = true

        // All file I/O on background thread to avoid blocking UI
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion?() }
                return
            }
            let hb = self._loadHeartbeatBG()
            let (changes, manifestIds, manifest) = self._loadManifestAndDiffBG()
            let confirmedIds = self._loadLedgerBG()

            DispatchQueue.main.async {
                if let hb { self.heartbeat = hb }
                if let manifest { self.lastManifest = manifest }
                // Batch all upserts into a single observable update
                self.store.batchUpsert(changes)
                // Remove items not in manifest (stale cache entries)
                if !manifestIds.isEmpty {
                    let staleIds = self.store.items.map(\.id)
                        .filter { !manifestIds.contains($0) }
                    for id in staleIds {
                        self.store.remove(id)
                    }
                }
                if !confirmedIds.isEmpty {
                    self.commands?.confirmDelivery(confirmedIds)
                }
                self.commands?.flushPendingAPIQueue()
                self.syncing = false
                self._scheduleNextPoll()
                completion?()
            }
        }
    }

    // Background-safe versions (no @MainActor)
    private func _loadHeartbeatBG() -> MiraHeartbeat? {
        // Strategy: try LAN HTTP first (instant), fall back to iCloud file (may be stale)

        // 1. Try LAN server
        let serverBase = config.serverURL ?? BridgeConfig.defaultServerURL
        let apiURL = serverBase.appending(path: "api/heartbeat")
        var request = URLRequest(url: apiURL, timeoutInterval: 3)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let sem = DispatchSemaphore(value: 0)
        var lanHB: MiraHeartbeat?
        MiraPinnedURLSession.shared.dataTask(with: request) { [weak self] data, resp, err in
            defer { sem.signal() }
            var failure = err?.localizedDescription ?? "no response"
            if let http = resp as? HTTPURLResponse { failure = "HTTP \(http.statusCode)" }
            guard let data,
                  let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                DispatchQueue.main.async {
                    self?.heartbeatDebug = "LAN heartbeat failed: \(failure)"
                }
                return
            }
            guard let hb = try? self?.decoder.decode(MiraHeartbeat.self, from: data) else {
                DispatchQueue.main.async {
                    self?.heartbeatDebug = "LAN heartbeat decode failed"
                }
                return
            }
            lanHB = hb
        }.resume()
        sem.wait()

        if let hb = lanHB {
            let age = Int(Date().timeIntervalSince(hb.date))
            DispatchQueue.main.async {
                self.apiOnline = true
                self.heartbeatDebug = "LAN age=\(age)s (\(serverBase.host() ?? "?"))"
                self.debugLog = "LAN heartbeat OK"
            }
            return hb
        }

        // 2. Fall back to iCloud file
        guard let url = config.heartbeatURL else { return nil }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        guard let data = try? Data(contentsOf: url),
              let hb = try? decoder.decode(MiraHeartbeat.self, from: data) else {
            DispatchQueue.main.async {
                self.apiOnline = false
                self.heartbeatDebug = "LAN unreachable, iCloud read failed"
                self.debugLog = "LAN unreachable, iCloud read failed"
            }
            return nil
        }
        let age = Int(Date().timeIntervalSince(hb.date))
        DispatchQueue.main.async {
            self.heartbeatDebug = "iCloud fallback age=\(age)s"
            self.debugLog = "iCloud fallback age=\(age)s"
        }
        return hb
    }

    private func _loadManifestAndDiffBG() -> ([MiraItem], Set<String>, MiraManifest?) {
        let userId = config.profile?.id ?? "ang"
        let serverBase = config.serverURL ?? BridgeConfig.defaultServerURL

        // --- Preferred: API control-plane task snapshot ---
        if let snapshot = _fetchJSON(MiraTasksResponse.self, from: serverBase.appending(path: "api/\(userId)/tasks")) {
            var changed: [MiraItem] = []
            var currentIds = Set<String>()
            for item in snapshot.items {
                currentIds.insert(item.id)
                if manifestTimestamps[item.id] == item.updatedAt { continue }
                changed.append(item)
                manifestTimestamps[item.id] = item.updatedAt
            }
            let removedIds = Set(manifestTimestamps.keys).subtracting(currentIds)
            for id in removedIds { manifestTimestamps.removeValue(forKey: id) }
            let manifest = MiraManifest(
                updatedAt: snapshot.serverTime,
                items: snapshot.items.map {
                    ManifestEntry(id: $0.id, type: $0.type.rawValue, status: $0.status.rawValue, updatedAt: $0.updatedAt)
                },
                generation: snapshot.lastEventId
            )
            DispatchQueue.main.async {
                self.apiOnline = true
                self.debugLog = "API tasks snapshot (\(snapshot.items.count))"
            }
            return (changed, currentIds, manifest)
        }

        // --- Try LAN first: fetch manifest + changed items via HTTP ---
        if let manifest = _fetchJSON(MiraManifest.self, from: serverBase.appending(path: "api/\(userId)/manifest")) {
            var changed: [MiraItem] = []
            var currentIds = Set<String>()

            for entry in manifest.items {
                currentIds.insert(entry.id)
                if manifestTimestamps[entry.id] == entry.updatedAt { continue }

                // Fetch changed item via LAN. Only advance the seen timestamp
                // after the item has been fetched and decoded; otherwise a
                // transient item fetch failure can permanently hide the update.
                if let item = _fetchJSON(MiraItem.self, from: serverBase.appending(path: "api/\(userId)/items/\(entry.id)")) {
                    changed.append(item)
                    manifestTimestamps[entry.id] = entry.updatedAt
                }
            }
            let removedIds = Set(manifestTimestamps.keys).subtracting(currentIds)
            for id in removedIds { manifestTimestamps.removeValue(forKey: id) }
            return (changed, currentIds, manifest)
        }

        // --- Fallback: iCloud files ---
        guard let url = config.manifestURL else { return ([], [], nil) }
        let fm = FileManager.default
        if let userDir = config.bridgeURL?.appending(path: "users") {
            try? fm.startDownloadingUbiquitousItem(at: userDir)
        }
        if let itemsDir = config.itemsDir {
            try? fm.startDownloadingUbiquitousItem(at: itemsDir)
        }
        try? fm.startDownloadingUbiquitousItem(at: url)

        guard let data = try? Data(contentsOf: url),
              let manifest = try? decoder.decode(MiraManifest.self, from: data) else { return ([], [], nil) }

        var changed: [MiraItem] = []
        var currentIds = Set<String>()

        for entry in manifest.items {
            currentIds.insert(entry.id)
            if manifestTimestamps[entry.id] == entry.updatedAt { continue }

            guard let itemsDir = config.itemsDir else { continue }
            let fileURL = itemsDir.appending(path: "\(entry.id).json")
            try? fm.startDownloadingUbiquitousItem(at: fileURL)
            if let fileData = try? Data(contentsOf: fileURL),
               let item = try? decoder.decode(MiraItem.self, from: fileData) {
                changed.append(item)
                manifestTimestamps[entry.id] = entry.updatedAt
            }
        }

        let removedIds = Set(manifestTimestamps.keys).subtracting(currentIds)
        for id in removedIds { manifestTimestamps.removeValue(forKey: id) }
        return (changed, currentIds, manifest)
    }

    private func _loadLedgerBG() -> Set<String> {
        guard let url = config.ledgerURL else { return [] }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        guard let data = try? Data(contentsOf: url),
              let ledger = try? decoder.decode(CommandLedger.self, from: data) else { return [] }
        return Set(ledger.processed.keys)
    }

    public var debugLog: String = ""

    private func _startEventStream() {
        guard eventStreamTask == nil else { return }
        guard let userId = config.profile?.id else { return }
        let base = config.serverURL ?? BridgeConfig.defaultServerURL
        let url = base.appending(path: "api/\(userId)/events")
        eventStreamTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    var request = URLRequest(url: url, timeoutInterval: 65)
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await MiraPinnedURLSession.shared.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        try await Task.sleep(nanoseconds: 20_000_000_000)
                        continue
                    }
                    for try await line in bytes.lines {
                        if Task.isCancelled { return }
                        if line.hasPrefix("data:") {
                            await self?._refreshFromEventStream()
                        }
                    }
                } catch {
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                }
            }
        }
    }

    @MainActor
    private func _refreshFromEventStream() {
        refresh()
    }

    /// Synchronous HTTP fetch with 3s timeout, returns decoded object or nil
    private func _fetchJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let sem = DispatchSemaphore(value: 0)
        var result: T?
        MiraPinnedURLSession.shared.dataTask(with: request) { [weak self] data, resp, _ in
            defer { sem.signal() }
            guard let data,
                  let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
            let decoded = try? self?.decoder.decode(T.self, from: data)
            if decoded != nil {
                DispatchQueue.main.async {
                    self?.apiOnline = true
                }
            }
            result = decoded
        }.resume()
        sem.wait()
        return result
    }
}
