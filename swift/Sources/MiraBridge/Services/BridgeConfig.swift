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
    private var discovery: MiraServerDiscovery?

    public var isSetup: Bool {
        bridgeURL != nil && rootURL != nil
    }
    public var isProfileSelected: Bool { profile != nil }
    public var agentName: String { profile?.agentName ?? "Mira" }

    /// LAN server URL for direct heartbeat (bypasses iCloud sync delay)
    public var serverURL: URL? {
        get { UserDefaults.standard.url(forKey: "mira_server_url") }
        set { UserDefaults.standard.set(newValue, forKey: "mira_server_url") }
    }
    /// During migration, failed API writes can still fall back to iCloud command files.
    /// Turn this off once API writes + the local pending queue are the primary path.
    public var apiWriteFallbackToICloud: Bool {
        get {
            if UserDefaults.standard.object(forKey: "mira_api_write_fallback_icloud") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "mira_api_write_fallback_icloud")
        }
        set { UserDefaults.standard.set(newValue, forKey: "mira_api_write_fallback_icloud") }
    }
    /// Default fallback: Mac local hostname. Bonjour discovery should replace
    /// this when the `_mira._tcp` service is visible on the LAN.
    public static let defaultServerURL = URL(string: "https://studio.local:8384")!

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
        profiles = Self.defaultProfiles
        restoreProfile()
        selectDefaultProfileIfNeeded()
        restoreBookmarkAsync()
    }

    public func startServerDiscovery() {
        if discovery == nil {
            discovery = MiraServerDiscovery { [weak self] url in
                guard let self else { return }
                if self.shouldAdoptDiscoveredServerURL(url) {
                    self.serverURL = url
                    self.debugInfo = "Discovered API: \(url.absoluteString)"
                }
            }
        }
        discovery?.start()
    }

    private func shouldAdoptDiscoveredServerURL(_ url: URL) -> Bool {
        guard let current = serverURL else { return true }
        if current == Self.defaultServerURL { return true }
        let host = current.host()?.lowercased() ?? ""
        if host == "mira.local" || host == "192.168.1.232" || current.scheme == "http" { return true }
        return false
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
                self?.loadProfilesAsync()
                self?.ensureDirectoriesAsync()
            }
        } catch {
            self.error = "Cannot save bookmark for \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: - Profile

    public func selectProfile(_ p: MiraProfile) {
        profile = p
        UserDefaults.standard.set(p.id, forKey: "selected_profile")
        ensureDirectoriesAsync()
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

    public func loadProfilesAsync() {
        guard let url = bridgeURL?.appending(path: "profiles.json") else {
            profiles = Self.defaultProfiles
            restoreProfile()
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            let decodedProfiles: [MiraProfile]
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(MiraProfiles.self, from: data),
               !decoded.profiles.isEmpty {
                decodedProfiles = decoded.profiles
            } else {
                decodedProfiles = Self.defaultProfiles
            }
            DispatchQueue.main.async {
                self?.profiles = decodedProfiles
                self?.restoreProfile()
            }
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

    private func selectDefaultProfileIfNeeded() {
        guard profile == nil else { return }
        let defaultProfile = profiles.first(where: { $0.id == "ang" }) ?? profiles.first
        guard let defaultProfile else { return }
        profile = defaultProfile
        UserDefaults.standard.set(defaultProfile.id, forKey: "selected_profile")
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
        } catch {
            // Stale bookmark — silently clear, user will re-select folder
            UserDefaults.standard.removeObject(forKey: "bridge_bookmark")
        }
    }

    private func restoreBookmarkAsync() {
        guard let data = UserDefaults.standard.data(forKey: "bridge_bookmark") else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                var isStale = false
                let url = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale)
                guard url.startAccessingSecurityScopedResource() else { return }

                let newBookmark: Data?
                if isStale {
                    newBookmark = try url.bookmarkData(
                        options: .minimalBookmark,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                } else {
                    newBookmark = nil
                }

                let actualRoot: URL
                let actualBridge: URL
                if url.lastPathComponent == "Mira-Bridge" {
                    actualBridge = url
                    actualRoot = url.deletingLastPathComponent()
                } else {
                    actualRoot = url
                    actualBridge = url.appending(path: "Mira-Bridge")
                }

                DispatchQueue.main.async {
                    if let newBookmark {
                        UserDefaults.standard.set(newBookmark, forKey: "bridge_bookmark")
                    }
                    self?.rootURL = actualRoot
                    self?.bridgeURL = actualBridge
                    self?.loadProfilesAsync()
                    self?.ensureDirectoriesAsync()
                }
            } catch {
                DispatchQueue.main.async {
                    UserDefaults.standard.removeObject(forKey: "bridge_bookmark")
                }
            }
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

    private func ensureDirectoriesAsync() {
        guard let bridgeURL, let dir = userDir else { return }
        let hb = heartbeatURL
        let mf = manifestURL
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            try? fm.startDownloadingUbiquitousItem(at: bridgeURL)
            try? fm.startDownloadingUbiquitousItem(at: bridgeURL.appending(path: "heartbeat.json"))
            try? fm.startDownloadingUbiquitousItem(at: bridgeURL.appending(path: "profiles.json"))
            try? fm.startDownloadingUbiquitousItem(at: bridgeURL.appending(path: "users"))
            for sub in ["items", "commands", "archive"] {
                let d = dir.appending(path: sub)
                try? fm.createDirectory(at: d, withIntermediateDirectories: true)
                try? fm.startDownloadingUbiquitousItem(at: d)
            }
            if let hb { try? fm.startDownloadingUbiquitousItem(at: hb) }
            if let mf { try? fm.startDownloadingUbiquitousItem(at: mf) }
        }
    }
}

private final class MiraServerDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private let onResolve: (URL) -> Void

    init(onResolve: @escaping (URL) -> Void) {
        self.onResolve = onResolve
        super.init()
        browser.delegate = self
    }

    func start() {
        browser.searchForServices(ofType: "_mira._tcp.", inDomain: "local.")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 3)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let rawHost = sender.hostName ?? ""
        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
        guard !host.isEmpty, sender.port > 0 else { return }
        guard let url = URL(string: "https://\(host):\(sender.port)") else { return }
        DispatchQueue.main.async { [onResolve] in onResolve(url) }
    }
}
