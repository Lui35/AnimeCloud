import Foundation
import Network

@MainActor
final class AppModel: ObservableObject {
    static let live = AppModel(api: .live)

    let api: LegacyAPI
    let library: LibraryStore
    let playbackProgress: PlaybackProgressStore
    let downloads: EpisodeDownloads
    let discovery = GroundedDiscoveryService()
    let aniList = AniListSyncManager()

    @Published var featured: [Anime] = []
    @Published var schedule: [Anime] = []
    @Published var newlyAddedEpisodes: [Anime] = []
    @Published var catalog: [Anime] = []
    @Published var session: UserSession?
    @Published var isBootstrapping = false
    @Published var isCatalogLoading = false
    @Published var isCloudSyncing = false
    @Published var cloudSyncStatus = "Sign in to enable automatic sync"
    @Published var message: AppMessage?

    private let defaults: UserDefaults
    private var didBootstrap = false
    private var catalogLoadTask: Task<Void, Never>?
    private var automaticSyncTask: Task<Void, Never>?
    private var aniListAutomaticSyncTask: Task<Void, Never>?
    private var syncInProgress = false
    private var connectivity: NWPathMonitor?
    private var isOffline = false

    var hasPendingCloudChanges: Bool {
        session.map { defaults.bool(forKey: dirtyKey(for: $0)) } ?? false
    }

    init(api: LegacyAPI, defaults: UserDefaults = .standard) {
        self.api = api
        self.defaults = defaults
        library = LibraryStore(defaults: defaults)
        playbackProgress = PlaybackProgressStore(defaults: defaults)
        downloads = EpisodeDownloads(api: api, defaults: defaults)
        if let data = defaults.data(forKey: "account.session") {
            session = try? JSONDecoder().decode(UserSession.self, from: data)
        }
        if session != nil { cloudSyncStatus = "Automatic sync is ready" }
        library.onChange = { [weak self] in self?.libraryDidChange() }
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        isBootstrapping = true
        async let featuredResult = try? api.catalog(.getMost, fields: visibilityFields)
        async let scheduleResult = try? api.catalog(.getAnimeWithDays, fields: visibilityFields)
        async let newEpisodesResult = try? api.newlyAddedEpisodes()
        let (newFeatured, newSchedule, newEpisodes) = await (featuredResult, scheduleResult, newEpisodesResult)
        featured = newFeatured ?? []
        schedule = newSchedule ?? []
        newlyAddedEpisodes = newEpisodes ?? []
        isBootstrapping = false
        if session != nil {
            Task { await synchronizeCloud(uploadIfDirty: true, showResult: false) }
        }
        if aniList.isConnected {
            Task { await synchronizeAniList(uploadIfDirty: true, showResult: false) }
        }
        if !isOffline && featured.isEmpty && schedule.isEmpty && newlyAddedEpisodes.isEmpty {
            message = AppMessage(title: "Clouds are quiet", detail: "The legacy Anime Cloud server did not return a catalog. Pull to try again.")
        }
    }

    func monitorConnectivity() {
        guard connectivity == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let isOffline = path.status == .unsatisfied
            Task { @MainActor in
                guard let self else { return }
                let wasOffline = self.isOffline
                self.isOffline = isOffline
                if wasOffline && !isOffline { await self.retryPendingWatchSync() }
            }
        }
        connectivity = monitor
        monitor.start(queue: DispatchQueue(label: "AnimeCloud.Connectivity"))
    }

    func retryPendingWatchSync() async {
        guard !isOffline else { return }
        if hasPendingCloudChanges && !syncInProgress {
            await synchronizeCloud(uploadIfDirty: true, showResult: false)
        }
        if aniList.hasPendingChanges {
            await synchronizeAniList(uploadIfDirty: true, showResult: false)
        }
    }

    func loadCatalog(force: Bool = false) async {
        if let catalogLoadTask {
            await catalogLoadTask.value
            return
        }
        guard catalog.isEmpty || force else { return }
        isCatalogLoading = true
        // Discover and its assistant share the request across view lifetimes.
        let task = Task {
            defer {
                isCatalogLoading = false
                catalogLoadTask = nil
            }
            do {
                catalog = try await api.catalog(.getAllAnime, fields: visibilityFields)
                library.hydrate(with: catalog)
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                message = AppMessage(error: error)
            }
        }
        catalogLoadTask = task
        await task.value
    }

    func refresh() async {
        didBootstrap = false
        await bootstrap()
    }

    func login(email: String, password: String) async -> Bool {
        do {
            let account = try await api.login(email: email, password: password)
            let hadLocalContent = library.hasContent
            session = account
            defaults.set(try? JSONEncoder().encode(account), forKey: "account.session")

            // First login is download-and-merge only. Never upload before a cloud
            // baseline has been established for this account.
            await synchronizeCloud(uploadIfDirty: false, showResult: false)
            if hadLocalContent { defaults.set(true, forKey: dirtyKey(for: account)) }
            return true
        } catch {
            message = AppMessage(error: error)
            return false
        }
    }

    func logout() {
        automaticSyncTask?.cancel()
        session = nil
        defaults.removeObject(forKey: "account.session")
        cloudSyncStatus = "Sign in to enable automatic sync"
    }

    func syncBackup() async {
        guard session != nil else {
            message = AppMessage(title: "Sign in first", detail: "Cloud backup requires an Anime Cloud account.")
            return
        }
        await synchronizeCloud(uploadIfDirty: true, showResult: true)
    }

    func syncCloudInBackground() async {
        guard !isOffline else { return }
        if session != nil { await synchronizeCloud(uploadIfDirty: true, showResult: false) }
        if aniList.isConnected { await synchronizeAniList(uploadIfDirty: true, showResult: false) }
    }

    func connectAniList() async -> Bool {
        await loadCatalog()
        do {
            try await aniList.connect(library: library, catalog: knownAnime)
            message = AppMessage(
                title: "AniList connected",
                detail: "Your AniList library was downloaded first. Nothing was uploaded during this first connection. Future Anime Cloud changes will sync automatically."
            )
            return true
        } catch {
            message = AppMessage(error: error)
            return false
        }
    }

    func syncAniListNow() async {
        guard aniList.isConnected else {
            message = AppMessage(title: "Connect AniList first", detail: "Open the AniList setting and authorize your account.")
            return
        }
        await synchronizeAniList(uploadIfDirty: true, showResult: true)
    }

    func disconnectAniList() {
        aniListAutomaticSyncTask?.cancel()
        aniList.disconnect()
    }

    func applyAniListProgress(to anime: Anime, episodes: [Episode]) {
        guard aniList.isConnected else { return }
        aniList.applyRemoteProgress(to: anime, episodes: episodes, library: library)
    }

    private func libraryDidChange() {
        if let session {
            let key = revisionKey(for: session)
            defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
            defaults.set(true, forKey: dirtyKey(for: session))
            cloudSyncStatus = "Waiting to sync changes"
            automaticSyncTask?.cancel()
            automaticSyncTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.automaticSyncTask = nil
                guard !self.isOffline else { return }
                await self.synchronizeCloud(uploadIfDirty: true, showResult: false)
            }
        }

        if aniList.isConnected, !aniList.isApplyingRemote {
            aniList.markDirty()
            aniListAutomaticSyncTask?.cancel()
            aniListAutomaticSyncTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.aniListAutomaticSyncTask = nil
                guard !self.isOffline else { return }
                await self.synchronizeAniList(uploadIfDirty: true, showResult: false)
            }
        }
    }

    private func synchronizeAniList(uploadIfDirty: Bool, showResult: Bool) async {
        do {
            try await aniList.synchronize(library: library, catalog: knownAnime, uploadIfDirty: uploadIfDirty)
            if showResult {
                message = AppMessage(
                    title: "AniList synced",
                    detail: "AniList was downloaded before local statuses and watched-episode progress were uploaded."
                )
            }
        } catch {
            aniList.noteSyncFailure(error)
            if showResult { message = AppMessage(error: error) }
        }
    }

    private func synchronizeCloud(uploadIfDirty: Bool, showResult: Bool) async {
        guard let account = session else { return }
        if isOffline && !showResult && uploadIfDirty { return }
        // Login must still restore its account if a foreground sync is finishing.
        while syncInProgress {
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return }
            guard session == account else { return }
        }
        guard session == account else { return }
        syncInProgress = true
        isCloudSyncing = true
        defer {
            syncInProgress = false
            isCloudSyncing = false
        }

        let baselineKey = baselineKey(for: account)
        let hadBaseline = defaults.bool(forKey: baselineKey)
        let hadLocalContentBeforePull = library.hasContent

        do {
            cloudSyncStatus = "Downloading cloud library…"
            do {
                let remoteData = try await api.downloadBackup(user: account)
                guard session == account else { return }
                try library.mergeBackup(remoteData, catalog: catalog + featured + schedule)
                if library.favorites.contains(where: { $0.name == "Anime #\($0.id)" }),
                   let restoredCatalog = try? await api.catalog(.getAllAnime, fields: visibilityFields) {
                    guard session == account else { return }
                    catalog = restoredCatalog
                    library.hydrate(with: restoredCatalog)
                }
            } catch APIError.server(let code) where code == 404 {
                // No remote file is a valid first-sync state. It still must not
                // trigger an upload during this initial login.
            }

            guard session == account else { return }
            defaults.set(true, forKey: baselineKey)

            guard hadBaseline else {
                if hadLocalContentBeforePull {
                    defaults.set(true, forKey: dirtyKey(for: account))
                }
                cloudSyncStatus = "Cloud library restored • uploads begin after your next change"
                if showResult {
                    message = AppMessage(title: "Cloud library restored", detail: "Existing cloud data was merged safely. Nothing was uploaded during this first sync.")
                }
                return
            }

            let hasPendingChanges = defaults.bool(forKey: dirtyKey(for: account))
            if uploadIfDirty && hasPendingChanges {
                cloudSyncStatus = "Uploading merged library…"
                let revision = defaults.integer(forKey: revisionKey(for: account))
                let mergedData = try library.backupData()
                guard session?.userID == account.userID else { return }
                try await api.uploadBackup(data: mergedData, user: account)
                guard session == account else { return }
                if defaults.integer(forKey: revisionKey(for: account)) == revision {
                    library.didUploadSuccessfully()
                    defaults.set(false, forKey: dirtyKey(for: account))
                }
            }

            cloudSyncStatus = hasPendingCloudChanges ? "Waiting to sync changes" : "Synced just now"
            if showResult {
                let detail = hasPendingChanges
                    ? "Cloud data was downloaded and merged before the updated library was uploaded."
                    : "Your cloud library was downloaded and merged. There were no local changes to upload."
                message = AppMessage(title: "Library synced", detail: detail)
            }
        } catch {
            cloudSyncStatus = "Sync paused • will retry automatically"
            if showResult { message = AppMessage(error: error) }
        }
    }

    private func baselineKey(for account: UserSession) -> String { "cloud.baseline.\(account.userID)" }
    private func revisionKey(for account: UserSession) -> String { "cloud.revision.\(account.userID)" }
    private func dirtyKey(for account: UserSession) -> String { "cloud.dirty.\(account.userID)" }

    private var knownAnime: [Anime] {
        Array(Dictionary(
            (catalog + featured + schedule + newlyAddedEpisodes + library.favorites + library.recentAnime).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values)
    }

    var visibilityFields: [String: String] { ["cmode": "0", "hiddenMode": "0"] }
}

struct AppMessage: Identifiable {
    let id = UUID()
    var title: String
    var detail: String

    init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    init(error: Error) {
        title = "Something drifted off course"
        detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
