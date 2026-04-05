import Foundation
import Observation

/// Manages bridge folder selection, profile, bookmark persistence, and URL computation.
@Observable
public final class BridgeConfig {
    public var bridgeURL: URL?
    public var rootURL: URL?
    public var error: String?
    public var debugInfo: String?
    public var profile: MiraProfile?
    public var profiles: [MiraProfile] = []

    public var isSetup: Bool { bridgeURL != nil }
    public var isProfileSelected: Bool { profile != nil }
    public var agentName: String { profile?.agentName ?? "Mira" }

    /// LAN server URL for direct heartbeat (bypasses iCloud sync delay)
    public var serverURL: URL? {
        get { UserDefaults.standard.url(forKey: "mira_server_url") }
        set { UserDefaults.standard.set(newValue, forKey: "mira_server_url") }
    }
    /// Default: Mac Studio on local network (use IP — .local mDNS unreliable on iOS)
    public static let defaultServerURL = URL(string: "http://192.168.1.232:8384")!

    // Per-user computed URLs
    private var userDir: URL? {
        guard let base = bridgeURL, let p = profile else { return nil }
        return base.appending(path: "users/\(p.id)")
    }
    public var heartbeatURL: URL? { bridgeURL?.appending(path: "heartbeat.json") }
    public var manifestURL: URL? { userDir?.appending(path: "manifest.json") }
    public var itemsDir: URL? { userDir?.appending(path: "items") }
    public var commandsDir: URL? { userDir?.appending(path: "commands") }
    public var ledgerURL: URL? { userDir?.appending(path: "command_ledger.json") }
    public var todosURL: URL? { userDir?.appending(path: "todos.json") }
    public var artifactsURL: URL? {
        guard let root = rootURL, let p = profile else { return nil }
        return root.appending(path: "Mira-Artifacts/\(p.id)")
    }

    public init() {
        restoreBookmark()
        restoreProfile()
    }

    // MARK: - Folder

    public func setFolder(_ url: URL) {
        // Must access security-scoped resource first on iOS
        guard url.startAccessingSecurityScopedResource() else {
            self.error = "Cannot access: \(url.lastPathComponent). Try selecting the MtJoy folder in iCloud Drive."
            return
        }

        let fm = FileManager.default

        // Accept either MtJoy root or Mira-Bridge directly
        let actualRoot: URL
        let actualBridge: URL
        if url.lastPathComponent == "Mira-Bridge" {
            actualBridge = url
            actualRoot = url.deletingLastPathComponent()
        } else {
            // Assume MtJoy root selected
            actualRoot = url
            actualBridge = url.appending(path: "Mira-Bridge")
        }

        try? fm.startDownloadingUbiquitousItem(at: actualBridge)
        try? fm.startDownloadingUbiquitousItem(at: actualBridge.appending(path: "heartbeat.json"))
        try? fm.startDownloadingUbiquitousItem(at: actualBridge.appending(path: "profiles.json"))
        try? fm.startDownloadingUbiquitousItem(at: actualBridge.appending(path: "users"))
        // Also trigger artifacts download
        try? fm.startDownloadingUbiquitousItem(at: actualRoot.appending(path: "Mira-Artifacts"))

        do {
            let bookmark = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: "bridge_bookmark")
            bridgeURL = actualBridge
            rootURL = actualRoot
            error = nil
            debugInfo = "Selected: \(url.lastPathComponent) → bridge: \(actualBridge.lastPathComponent)"
            // Delay profile loading slightly to let iCloud download
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.loadProfiles()
                self?.ensureDirectories()
            }
        } catch {
            self.error = "Cannot save bookmark for \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: - Profile

    public func selectProfile(_ p: MiraProfile) {
        profile = p
        UserDefaults.standard.set(p.id, forKey: "selected_profile")
        ensureDirectories()
    }

    private static let defaultProfiles: [MiraProfile] = [
        MiraProfile(id: "ang", displayName: "Ang", agentName: "Mira", avatar: "person.circle.fill"),
        MiraProfile(id: "liquan", displayName: "Liquan", agentName: "Mika", avatar: "person.circle.fill"),
    ]

    public func loadProfiles() {
        guard let url = bridgeURL?.appending(path: "profiles.json") else {
            profiles = Self.defaultProfiles
            return
        }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(MiraProfiles.self, from: data)
            profiles = decoded.profiles.isEmpty ? Self.defaultProfiles : decoded.profiles
        } catch {
            profiles = Self.defaultProfiles
        }
    }

    private func restoreProfile() {
        guard let savedId = UserDefaults.standard.string(forKey: "selected_profile") else { return }
        // Will match after loadProfiles() is called
        if let p = profiles.first(where: { $0.id == savedId }) {
            profile = p
        } else {
            // Defer matching until profiles are loaded
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                if let p = self?.profiles.first(where: { $0.id == savedId }) {
                    self?.profile = p
                }
            }
        }
    }

    private func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: "bridge_bookmark") else { return }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale)
            guard url.startAccessingSecurityScopedResource() else { return }
            if isStale {
                let newData = try url.bookmarkData(
                    options: .minimalBookmark,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                UserDefaults.standard.set(newData, forKey: "bridge_bookmark")
            }
            if url.lastPathComponent == "Mira-Bridge" {
                bridgeURL = url
                rootURL = url.deletingLastPathComponent()
            } else {
                // Selected MtJoy root
                rootURL = url
                bridgeURL = url.appending(path: "Mira-Bridge")
            }
            // Trigger iCloud downloads
            let fm = FileManager.default
            if let b = bridgeURL {
                try? fm.startDownloadingUbiquitousItem(at: b)
                try? fm.startDownloadingUbiquitousItem(at: b.appending(path: "heartbeat.json"))
                try? fm.startDownloadingUbiquitousItem(at: b.appending(path: "profiles.json"))
                try? fm.startDownloadingUbiquitousItem(at: b.appending(path: "users"))
            }
            loadProfiles()
            ensureDirectories()
        } catch {
            // Stale bookmark — silently clear, user will re-select folder
            UserDefaults.standard.removeObject(forKey: "bridge_bookmark")
        }
    }

    private func ensureDirectories() {
        guard let dir = userDir else { return }
        let fm = FileManager.default
        for sub in ["items", "commands", "archive"] {
            let d = dir.appending(path: sub)
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
            try? fm.startDownloadingUbiquitousItem(at: d)
        }
        if let hb = heartbeatURL { try? fm.startDownloadingUbiquitousItem(at: hb) }
        if let mf = manifestURL { try? fm.startDownloadingUbiquitousItem(at: mf) }
    }
}
