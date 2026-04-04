import Foundation
import Observation

/// Polls iCloud bridge, diffs manifest, fetches changed items.
@Observable
public final class SyncEngine {
    public let config: BridgeConfig
    public let store: ItemStore
    public weak var commands: CommandWriter?

    public var heartbeat: MiraHeartbeat?
    public var agentOnline: Bool { heartbeat?.isRecent ?? false }
    public var syncing: Bool = false

    private var timer: Timer?
    private var manifestTimestamps: [String: String] = [:]  // id → updated_at
    private let decoder = JSONDecoder()

    public init(config: BridgeConfig, store: ItemStore) {
        self.config = config
        self.store = store
    }

    // MARK: - Polling

    public func startPolling() {
        timer?.invalidate()
        let interval: TimeInterval = store.hasActiveItems ? 20 : 60
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in self?.refresh() }
        }
        // First refresh async so UI renders immediately
        Task { @MainActor [weak self] in self?.refresh() }
    }

    public func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    public func refresh(completion: (() -> Void)? = nil) {
        guard config.isSetup, !syncing else {
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
            let (changes, manifestIds) = self._loadManifestAndDiffBG()
            let confirmedIds = self._loadLedgerBG()

            DispatchQueue.main.async {
                if let hb { self.heartbeat = hb }
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
                self.syncing = false

                let desiredInterval: TimeInterval = self.store.hasActiveItems ? 20 : 60
                if let t = self.timer, t.timeInterval != desiredInterval {
                    self.startPolling()
                }
                completion?()
            }
        }
    }

    // Background-safe versions (no @MainActor)
    private func _loadHeartbeatBG() -> MiraHeartbeat? {
        guard let url = config.heartbeatURL else { return nil }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(MiraHeartbeat.self, from: data)
    }

    private func _loadManifestAndDiffBG() -> ([MiraItem], Set<String>) {
        guard let url = config.manifestURL else { return ([], []) }
        let fm = FileManager.default
        if let userDir = config.bridgeURL?.appending(path: "users") {
            try? fm.startDownloadingUbiquitousItem(at: userDir)
        }
        if let itemsDir = config.itemsDir {
            try? fm.startDownloadingUbiquitousItem(at: itemsDir)
        }
        try? fm.startDownloadingUbiquitousItem(at: url)

        guard let data = try? Data(contentsOf: url),
              let manifest = try? decoder.decode(MiraManifest.self, from: data) else { return ([], []) }

        var changed: [MiraItem] = []
        var currentIds = Set<String>()

        for entry in manifest.items {
            currentIds.insert(entry.id)
            if manifestTimestamps[entry.id] == entry.updatedAt { continue }
            manifestTimestamps[entry.id] = entry.updatedAt

            guard let itemsDir = config.itemsDir else { continue }
            let fileURL = itemsDir.appending(path: "\(entry.id).json")
            try? fm.startDownloadingUbiquitousItem(at: fileURL)
            if let fileData = try? Data(contentsOf: fileURL),
               let item = try? decoder.decode(MiraItem.self, from: fileData) {
                changed.append(item)
            }
        }

        // Clean up stale manifest timestamps
        let removedIds = Set(manifestTimestamps.keys).subtracting(currentIds)
        for id in removedIds {
            manifestTimestamps.removeValue(forKey: id)
        }

        return (changed, currentIds)
    }

    private func _loadLedgerBG() -> Set<String> {
        guard let url = config.ledgerURL else { return [] }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        guard let data = try? Data(contentsOf: url),
              let ledger = try? decoder.decode(CommandLedger.self, from: data) else { return [] }
        return Set(ledger.processed.keys)
    }

    public var debugLog: String = ""
}
