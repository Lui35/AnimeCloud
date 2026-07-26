import Foundation

@MainActor
final class AppModel: ObservableObject {
    static let live = AppModel(api: .live)

    let api: LegacyAPI
    let library = LibraryStore()
    let playbackProgress = PlaybackProgressStore()
    let discovery = GroundedDiscoveryService()

    @Published var featured: [Anime] = []
    @Published var schedule: [Anime] = []
    @Published var catalog: [Anime] = []
    @Published var news: [NewsItem] = []
    @Published var session: UserSession?
    @Published var isBootstrapping = false
    @Published var isCatalogLoading = false
    @Published var isCloudSyncing = false
    @Published var cloudSyncStatus = "Sign in to enable automatic sync"
    @Published var message: AppMessage?

    private let defaults = UserDefaults.standard
    private var didBootstrap = false
    private var automaticSyncTask: Task<Void, Never>?
    private var syncInProgress = false

    init(api: LegacyAPI) {
        self.api = api
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
        async let newsResult = try? api.news()
        let (newFeatured, newSchedule, newNews) = await (featuredResult, scheduleResult, newsResult)
        featured = newFeatured ?? []
        schedule = newSchedule ?? []
        news = newNews ?? []
        isBootstrapping = false
        if session != nil {
            Task { await synchronizeCloud(uploadIfDirty: true, showResult: false) }
        }
        if featured.isEmpty && schedule.isEmpty {
            message = AppMessage(title: "Clouds are quiet", detail: "The legacy Anime Cloud server did not return a catalog. Pull to try again.")
        }
    }

    func loadCatalog(force: Bool = false) async {
        guard catalog.isEmpty || force else { return }
        isCatalogLoading = true
        do {
            catalog = try await api.catalog(.getAllAnime, fields: visibilityFields)
            library.hydrate(with: catalog)
        }
        catch { message = AppMessage(error: error) }
        isCatalogLoading = false
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
        guard session != nil else { return }
        await synchronizeCloud(uploadIfDirty: true, showResult: false)
    }

    private func libraryDidChange() {
        guard let session else { return }
        defaults.set(true, forKey: dirtyKey(for: session))
        cloudSyncStatus = "Waiting to sync changes"
        automaticSyncTask?.cancel()
        automaticSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.synchronizeCloud(uploadIfDirty: true, showResult: false)
        }
    }

    private func synchronizeCloud(uploadIfDirty: Bool, showResult: Bool) async {
        guard let account = session, !syncInProgress else { return }
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
                guard session?.userID == account.userID else { return }
                try library.mergeBackup(remoteData, catalog: catalog + featured + schedule)
            } catch APIError.server(let code) where code == 404 {
                // No remote file is a valid first-sync state. It still must not
                // trigger an upload during this initial login.
            }

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
                let mergedData = try library.backupData()
                guard session?.userID == account.userID else { return }
                try await api.uploadBackup(data: mergedData, user: account)
                library.didUploadSuccessfully()
                defaults.set(false, forKey: dirtyKey(for: account))
            }

            cloudSyncStatus = "Synced just now"
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
    private func dirtyKey(for account: UserSession) -> String { "cloud.dirty.\(account.userID)" }

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
