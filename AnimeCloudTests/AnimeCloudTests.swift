import XCTest
@testable import AnimeCloud

final class AnimeCloudTests: XCTestCase {
    @MainActor
    func testLeavingDiscoverKeepsOneSharedCatalogRequest() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedCatalogFixtureProtocol.self]
        let suite = "AnimeCloudTests.catalog.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let started = expectation(description: "Catalog request started")
        started.assertForOverFulfill = true
        DelayedCatalogFixtureProtocol.requestStarted = started
        defer { DelayedCatalogFixtureProtocol.requestStarted = nil }
        let model = AppModel(api: LegacyAPI(session: URLSession(configuration: configuration)), defaults: defaults)

        let discover = Task { await model.loadCatalog() }
        await fulfillment(of: [started], timeout: 5)
        discover.cancel()
        await model.loadCatalog()
        await discover.value

        XCTAssertEqual(model.catalog.map(\.name), ["One Piece"])
        XCTAssertFalse(model.isCatalogLoading)
        XCTAssertNil(model.message)
    }

    func testDetailNavigationFollowsMeaningfulScrollDirection() {
        var visibility = ScrollAwareNavigationVisibility()

        visibility.update(offset: 0)
        visibility.update(offset: -5)
        XCTAssertTrue(visibility.isVisible, "Small scroll movement should not flicker the back button")

        visibility.update(offset: -20)
        XCTAssertFalse(visibility.isVisible)

        visibility.update(offset: -15)
        XCTAssertFalse(visibility.isVisible, "Small direction changes should not flicker the back button")
        visibility.update(offset: -8)
        XCTAssertTrue(visibility.isVisible, "Scrolling upward should restore navigation")

        visibility.update(offset: -30)
        XCTAssertFalse(visibility.isVisible)
        visibility.update(offset: -10)
        XCTAssertTrue(visibility.isVisible, "Navigation should always be visible near the top")
    }

    func testPlayerFullscreenGestureRequiresDeliberateVerticalSwipe() {
        XCTAssertEqual(
            PlayerFullscreenGesture.action(for: CGSize(width: 5, height: -90), isFullscreen: false),
            .enter
        )
        XCTAssertEqual(
            PlayerFullscreenGesture.action(for: CGSize(width: 5, height: 90), isFullscreen: true),
            .exit
        )
        XCTAssertNil(PlayerFullscreenGesture.action(for: CGSize(width: 0, height: 40), isFullscreen: false))
        XCTAssertNil(PlayerFullscreenGesture.action(for: CGSize(width: 90, height: -70), isFullscreen: false))
        XCTAssertNil(PlayerFullscreenGesture.action(for: CGSize(width: 0, height: 90), isFullscreen: false))
    }

    @MainActor
    func testSQLiteBackupRoundTripAndRemovalTombstone() throws {
        let sourceDefaults = UserDefaults(suiteName: "AnimeCloudTests.source.\(UUID())")!
        let restoredDefaults = UserDefaults(suiteName: "AnimeCloudTests.restored.\(UUID())")!
        let source = LibraryStore(defaults: sourceDefaults)
        let anime = Anime(id: "42", name: "Cloud Story", year: "2026")
        let watchingAnime = Anime(id: "43", name: "Current Story", year: "2026")
        let episode = Episode(id: "4201", name: "Episode 1")
        source.toggleFavorite(anime)
        source.setCategory(.watchingNow, for: watchingAnime)
        source.toggleSeen(episode)
        let backup = try source.backupData()

        let restored = LibraryStore(defaults: restoredDefaults)
        try restored.mergeBackup(backup, catalog: [anime])
        XCTAssertTrue(restored.isFavorite(anime))
        XCTAssertEqual(restored.category(for: watchingAnime), .watchingNow)
        XCTAssertTrue(restored.isSeen(episode))

        restored.toggleFavorite(anime)
        restored.markUnseen(episode)
        try restored.mergeBackup(backup, catalog: [anime])
        XCTAssertFalse(restored.isFavorite(anime), "A cloud pull must not resurrect an explicit local removal")
        XCTAssertFalse(restored.isSeen(episode), "A cloud pull must not resurrect an episode marked unwatched")
    }

    @MainActor
    func testHalfwayPlaybackAutomaticallyStartsWatchingAndPersists() {
        let suite = "AnimeCloudTests.autoWatching.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryStore(defaults: defaults)
        let anime = Anime(id: "new-series", name: "New series", status: "Completed")
        let episode = Episode(id: "first", name: "Episode 1")
        let episodes = [Episode(id: "last", name: "Episode 2"), episode]
        var changes = 0
        store.onChange = { changes += 1 }
        store.recordPlayback(of: episode, anime: anime, episodes: episodes, position: 49, duration: 100)
        XCTAssertNil(store.category(for: anime))
        store.recordPlayback(of: episode, anime: anime, episodes: episodes, position: 50, duration: 100)
        XCTAssertEqual(store.category(for: anime), .watchingNow)
        XCTAssertFalse(store.isSeen(episode))
        XCTAssertEqual(LibraryStore(defaults: defaults).category(for: anime), .watchingNow)
        XCTAssertEqual(store.favorites.map(\.id), [anime.id])
        store.recordPlayback(of: episode, anime: anime, episodes: episodes, position: 60, duration: 100)
        XCTAssertEqual(changes, 1, "Periodic playback must not repeatedly reschedule cloud sync")
    }

    @MainActor
    func testCompletingLastCanonEpisodeIgnoresTrailingFiller() {
        let suite = "AnimeCloudTests.autoCompleted.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryStore(defaults: defaults)
        let anime = Anime(id: "finished", name: "Finished series", status: "مكتمل")
        let filler = Episode(id: "filler", name: "Episode 3", filer: "1")
        let finale = Episode(id: "finale", name: "Episode 2")
        let first = Episode(id: "first", name: "Episode 1")
        let episodes = [filler, finale, first]
        store.setCategory(.watchLater, for: anime)
        store.completePlayback(of: first, anime: anime, episodes: episodes)
        XCTAssertEqual(store.category(for: anime), .watchingNow)
        store.recordPlayback(of: finale, anime: anime, episodes: episodes, position: 89, duration: 100)
        XCTAssertEqual(store.category(for: anime), .watchingNow)
        store.recordPlayback(of: finale, anime: anime, episodes: episodes, position: 90, duration: 100)
        XCTAssertEqual(store.category(for: anime), .watched)
        XCTAssertTrue(store.isSeen(finale))
        XCTAssertFalse(store.isSeen(filler))
        store.recordPlayback(of: first, anime: anime, episodes: episodes, position: 50, duration: 100)
        XCTAssertEqual(store.category(for: anime), .watched, "Rewatching must not undo completion")
        XCTAssertEqual(LibraryStore(defaults: defaults).category(for: anime), .watched)
    }

    @MainActor
    func testOngoingAndUnknownSeriesStayWatchingAfterLatestEpisode() {
        let suite = "AnimeCloudTests.ongoing.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryStore(defaults: defaults)
        for status in ["مستمر", "Ongoing", "", "Unknown"] {
            let anime = Anime(id: status, name: "Series", status: status)
            let latest = Episode(id: "latest-\(status)", name: "Episode 1")
            store.completePlayback(of: latest, anime: anime, episodes: [latest])
            XCTAssertEqual(store.category(for: anime), .watchingNow)
        }
        let anime = Anime(id: "all-filler", name: "Filler series", status: "Completed")
        let filler = Episode(id: "only-filler", name: "Episode 1", filer: "1")
        store.completePlayback(of: filler, anime: anime, episodes: [filler])
        XCTAssertEqual(store.category(for: anime), .watchingNow)
    }

    @MainActor
    func testInvalidPlaybackDoesNotChangeLibrary() {
        let suite = "AnimeCloudTests.invalidPlayback.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryStore(defaults: defaults)
        let anime = Anime(id: "invalid", name: "Series", status: "Completed")
        let episode = Episode(id: "invalid-episode", name: "Episode 1")
        for (position, duration) in [(Double.nan, 100.0), (100, Double.infinity), (100, 0), (-50, 100)] {
            store.recordPlayback(of: episode, anime: anime, episodes: [episode], position: position, duration: duration)
        }
        XCTAssertNil(store.category(for: anime))
        XCTAssertFalse(store.isSeen(episode))
    }

    @MainActor
    func testLoginAutomaticallyRestoresEveryListAndEpisodeHistory() async throws {
        let suite = "AnimeCloudTests.loginRestore.\(UUID())"
        let sourceSuite = "AnimeCloudTests.loginSource.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let sourceDefaults = UserDefaults(suiteName: sourceSuite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            sourceDefaults.removePersistentDomain(forName: sourceSuite)
            RestoreFixtureProtocol.backup = Data()
        }
        let source = LibraryStore(defaults: sourceDefaults)
        let catalog = LibraryCategory.allCases.map { Anime(id: $0.rawValue, name: $0.title, image: "https://example.com/\($0.rawValue).jpg", status: "Completed") }
        for (anime, category) in zip(catalog, LibraryCategory.allCases) { source.setCategory(category, for: anime) }
        let episode = Episode(id: "restored-episode", name: "Episode 1")
        source.markSeen(episode)
        RestoreFixtureProtocol.backup = try source.backupData()
        RestoreFixtureProtocol.catalog = catalog
        RestoreFixtureProtocol.uploadRequests = 0
        RestoreFixtureProtocol.downloadRequests = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RestoreFixtureProtocol.self]
        let model = AppModel(api: LegacyAPI(session: URLSession(configuration: configuration)), defaults: defaults)

        let loggedIn = await model.login(email: "restore@example.com", password: "test-only")

        XCTAssertTrue(loggedIn)
        XCTAssertEqual(RestoreFixtureProtocol.downloadRequests, 1)
        XCTAssertEqual(RestoreFixtureProtocol.uploadRequests, 0)
        for (anime, category) in zip(catalog, LibraryCategory.allCases) {
            XCTAssertEqual(model.library.category(for: anime), category)
            XCTAssertEqual(model.library.favorites.first { $0.id == anime.id }, anime)
        }
        XCTAssertTrue(model.library.isSeen(episode))
        XCTAssertTrue(defaults.bool(forKey: "cloud.baseline.restore-test"))
        model.logout()
    }

    @MainActor
    func testLoginWaitsForExistingCloudSyncBeforeRestoring() async throws {
        let suite = "AnimeCloudTests.concurrentLogin.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            RestoreFixtureProtocol.backup = Data()
            RestoreFixtureProtocol.downloadDelay = 0
        }
        let anime = Anime(id: "watching", name: "Watching series", status: "Ongoing")
        let source = LibraryStore(defaults: defaults)
        source.setCategory(.watchingNow, for: anime)
        RestoreFixtureProtocol.backup = try source.backupData()
        defaults.removePersistentDomain(forName: suite)
        RestoreFixtureProtocol.downloadRequests = 0
        RestoreFixtureProtocol.uploadRequests = 0
        RestoreFixtureProtocol.downloadDelay = 0.2
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RestoreFixtureProtocol.self]
        let model = AppModel(api: LegacyAPI(session: URLSession(configuration: configuration)), defaults: defaults)
        model.catalog = [anime]
        model.session = UserSession(userID: "previous-account", uniqID: "previous-token", username: "Previous", email: "previous@example.com")
        let previousSync = Task { await model.syncCloudInBackground() }
        while !model.isCloudSyncing { await Task.yield() }

        let loggedIn = await model.login(email: "restore@example.com", password: "test-only")
        await previousSync.value

        XCTAssertTrue(loggedIn)
        XCTAssertEqual(RestoreFixtureProtocol.downloadRequests, 2)
        XCTAssertEqual(RestoreFixtureProtocol.uploadRequests, 0)
        XCTAssertEqual(model.library.category(for: anime), .watchingNow)
        XCTAssertTrue(defaults.bool(forKey: "cloud.baseline.restore-test"))
        XCTAssertFalse(defaults.bool(forKey: "cloud.baseline.previous-account"))
        model.logout()
    }

    @MainActor
    func testFirstLoginNeverUploadsAnEmptyBackup() async {
        let suite = "AnimeCloudTests.emptyLogin.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        FirstSyncFixtureProtocol.uploadRequests = 0

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FirstSyncFixtureProtocol.self]
        let model = AppModel(api: LegacyAPI(session: URLSession(configuration: configuration)), defaults: defaults)

        let loggedIn = await model.login(email: "first@example.com", password: "test-only")

        XCTAssertTrue(loggedIn)
        XCTAssertEqual(FirstSyncFixtureProtocol.uploadRequests, 0)
        XCTAssertTrue(defaults.bool(forKey: "cloud.baseline.first-sync-test"))
        model.logout()
    }

    func testLoginAcceptsCurrentServerAccountIDShape() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LoginFixtureProtocol.self]
        let api = LegacyAPI(session: URLSession(configuration: configuration))

        let session = try await api.login(email: "viewer@example.com", password: "test-only")

        XCTAssertEqual(session.userID, "29776")
        XCTAssertEqual(session.uniqID, "session-token")
        XCTAssertEqual(session.username, "Cloud Viewer")
    }

    func testRelatedAnimeUsesCurrentAnimeAsRootAndExcludesItself() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelatedAnimeFixtureProtocol.self]
        let api = LegacyAPI(session: URLSession(configuration: configuration))

        let values = try await api.relatedAnime(animeID: "10", relatedID: "0")

        XCTAssertEqual(values.map(\.id), ["11"])
        XCTAssertEqual(LegacyAPI.relatedRootID(animeID: "10", relatedID: "0"), "10")
        XCTAssertEqual(LegacyAPI.relatedRootID(animeID: "10", relatedID: " 22 "), "22")
    }

    func testNewEpisodesDecodesResult2AndEpisodeName() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NewEpisodesFixtureProtocol.self]
        let api = LegacyAPI(session: URLSession(configuration: configuration))

        let values = try await api.newlyAddedEpisodes()

        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.id, "1")
        XCTAssertEqual(values.first?.latestEpisodeName, "الحلقة 1170")
    }

    func testEveryCommandHasAGateway() {
        XCTAssertEqual(LegacyCommand.allCases.count, 46)
        XCTAssertTrue(LegacyCommand.allCases.allSatisfy { $0.gateway.url.scheme == "https" })
    }

    func testAnime4KOffersOffAndEveryBundledPreset() {
        XCTAssertEqual(Anime4KPlaybackMode.allCases.count, 13)
        XCTAssertEqual(Anime4KPlaybackMode.fastModes.count, 6)
        XCTAssertEqual(Anime4KPlaybackMode.highQualityModes.count, 6)
        XCTAssertEqual(Anime4KPlaybackMode.benchmarkPriority.count, 12)
        XCTAssertNil(Anime4KPlaybackMode.off.preset)
        XCTAssertTrue(Anime4KPlaybackMode.allCases.dropFirst().allSatisfy { $0.preset != nil })
    }

    func testAnime4KBenchmarkRecommendsHighestPrioritySmoothMode() {
        let samples = [
            Anime4KBenchmarkSample(
                mode: .modeAAHQ,
                averageMilliseconds: 45,
                worstMilliseconds: 52,
                errorDescription: nil
            ),
            Anime4KBenchmarkSample(
                mode: .modeAHQ,
                averageMilliseconds: 22,
                worstMilliseconds: 27,
                errorDescription: nil
            ),
            Anime4KBenchmarkSample(
                mode: .modeAFast,
                averageMilliseconds: 8,
                worstMilliseconds: 10,
                errorDescription: nil
            )
        ]

        XCTAssertEqual(
            Anime4KBenchmarkReport.recommendation(from: samples),
            .modeAHQ
        )
    }

    func testAnime4KBenchmarkFallsBackToOffWithoutSmoothPreset() {
        let samples = [
            Anime4KBenchmarkSample(
                mode: .modeAFast,
                averageMilliseconds: 31,
                worstMilliseconds: 40,
                errorDescription: nil
            )
        ]

        XCTAssertEqual(
            Anime4KBenchmarkReport.recommendation(from: samples),
            .off
        )
    }

    func testAnimeSubtitle() {
        let anime = Anime(id: "1", name: "Cloud", status: "Ongoing", year: "2026")
        XCTAssertEqual(anime.subtitle, "2026 • Ongoing")
    }

    func testEpisodeFillerMarkersFromLegacyAPI() {
        XCTAssertTrue(Episode(id: "1", name: "Episode", filer: "فلر").isFiller)
        XCTAssertTrue(Episode(id: "2", name: "Episode", filer: "FILLER").isFiller)
        XCTAssertTrue(Episode(id: "3", name: "Episode", filer: "1").isFiller)
        XCTAssertFalse(Episode(id: "4", name: "Episode", filer: "").isFiller)
        XCTAssertFalse(Episode(id: "5", name: "Episode", filer: nil).isFiller)
        XCTAssertFalse(Episode(id: "6", name: "Episode", filer: "canon").isFiller)
    }

    func testEpisodeNumberSupportsLatinAndArabicDigits() {
        XCTAssertEqual(Episode(id: "1", name: "Episode 1170").episodeNumber, 1170)
        XCTAssertEqual(Episode(id: "2", name: "الحلقة ١٢").episodeNumber, 12)
        XCTAssertNil(Episode(id: "3", name: "Special").episodeNumber)
    }

    @MainActor
    func testWatchedEpisodeProgressIsAssociatedWithAnime() {
        let suiteName = "AnimeCloudTests.aniListProgress.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LibraryStore(defaults: defaults)
        let anime = Anime(id: "cloud", name: "Cloud Story")

        store.markSeen(Episode(id: "ep-2", name: "Episode 2"), anime: anime)
        store.markSeen(Episode(id: "ep-5", name: "Episode 5"), anime: anime)
        XCTAssertEqual(store.highestWatchedEpisode(forAnimeID: anime.id), 5)

        let restored = LibraryStore(defaults: defaults)
        XCTAssertEqual(restored.highestWatchedEpisode(forAnimeID: anime.id), 5)
    }

    func testAniListStatusAndConservativeTitleNormalization() {
        XCTAssertEqual(AniListStatus.current.libraryCategory, .watchingNow)
        XCTAssertEqual(AniListStatus.planning.libraryCategory, .watchLater)
        XCTAssertEqual(AniListStatus.completed.libraryCategory, .watched)
        XCTAssertNil(AniListStatus.dropped.libraryCategory)
        XCTAssertEqual(AniListSyncManager.normalizedTitle("Frieren: Beyond Journey’s End"), "frierenbeyondjourneysend")
    }

    func testNextEpisodeUsesNewestFirstServerOrder() {
        let episodes = [
            Episode(id: "3", name: "Episode 3"),
            Episode(id: "2", name: "Episode 2"),
            Episode(id: "1", name: "Episode 1")
        ]
        XCTAssertEqual(episodes.nextEpisode(after: episodes[2])?.id, "2")
        XCTAssertEqual(episodes.nextEpisode(after: episodes[1])?.id, "3")
        XCTAssertNil(episodes.nextEpisode(after: episodes[0]))
    }

    @MainActor
    func testRemovingRestoredDownloadKeepsResumeAndWatchedState() throws {
        let suite = "AnimeCloudTests.downloads.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let anime = Anime(id: "anime", name: "Series")
        let episode = Episode(id: "episode", name: "Episode 2")
        let record = EpisodeDownload(anime: anime, episode: episode, catalogPosition: 2,
                                     finalCanonEpisode: nil, status: .ready, relativePath: "episode.mp4")
        let file = directory.appending(path: "episode.mp4")
        try Data([0]).write(to: file)
        defaults.set(try JSONEncoder().encode([record.id: record]), forKey: "downloads.episodes")
        let progress = PlaybackProgressStore(defaults: defaults)
        progress.save(episodeID: episode.id, position: 754, duration: 1_500)
        LibraryStore(defaults: defaults).markSeen(episode, anime: anime)

        let downloads = EpisodeDownloads(api: .live, defaults: defaults, directory: directory)
        XCTAssertEqual(downloads.localURL(for: episode.id), file)
        try downloads.remove(episode.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(EpisodeDownloads(api: .live, defaults: defaults, directory: directory).records.isEmpty)
        XCTAssertEqual(PlaybackProgressStore(defaults: defaults).progress(for: episode.id)?.position, 754)
        XCTAssertTrue(LibraryStore(defaults: defaults).isSeen(episode))
    }

    @MainActor
    func testRemovingAnimeDownloadsOnlyRemovesItsEpisodes() throws {
        let suite = "AnimeCloudTests.animeDownloads.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let anime = Anime(id: "anime", name: "Series")
        let otherAnime = Anime(id: "other", name: "Other Series")
        var saved: [String: EpisodeDownload] = [:]
        for (id, series) in [("one", anime), ("two", anime), ("other", otherAnime)] {
            let episode = Episode(id: id, name: id)
            let path = "\(id).mp4"
            saved[id] = EpisodeDownload(anime: series, episode: episode, catalogPosition: 0,
                                        finalCanonEpisode: nil, status: .ready, relativePath: path)
            try Data([0]).write(to: directory.appending(path: path))
        }
        let failed = Episode(id: "failed", name: "Failed episode")
        saved[failed.id] = EpisodeDownload(anime: anime, episode: failed, catalogPosition: 0,
                                          finalCanonEpisode: nil, status: .failed)
        defaults.set(try JSONEncoder().encode(saved), forKey: "downloads.episodes")

        let downloads = EpisodeDownloads(api: .live, defaults: defaults, directory: directory)
        try downloads.removeAll(forAnimeID: anime.id)

        let restored = EpisodeDownloads(api: .live, defaults: defaults, directory: directory)
        XCTAssertEqual(Set(restored.records.keys), ["other"])
        XCTAssertNotNil(restored.localURL(for: "other"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "one.mp4").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "two.mp4").path))
    }

    @MainActor
    func testCloudUploadKeepsNewerWatchChangesPending() async throws {
        let suite = "AnimeCloudTests.uploadRevision.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            RestoreFixtureProtocol.beforeFirstUploadResponse = nil
            RestoreFixtureProtocol.backup = Data()
            defaults.removePersistentDomain(forName: suite)
        }
        RestoreFixtureProtocol.uploadRequests = 0
        RestoreFixtureProtocol.backup = try LibraryStore(defaults: defaults).backupData()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RestoreFixtureProtocol.self]
        let model = AppModel(api: LegacyAPI(session: URLSession(configuration: configuration)), defaults: defaults)
        let loggedIn = await model.login(email: "restore@example.com", password: "test-only")
        XCTAssertTrue(loggedIn)
        defer { model.logout() }

        let anime = Anime(id: "anime", name: "Series")
        let first = Episode(id: "first", name: "Episode 1")
        let second = Episode(id: "second", name: "Episode 2")
        model.library.markSeen(first, anime: anime)
        RestoreFixtureProtocol.beforeFirstUploadResponse = { respond in
            Task { @MainActor in
                model.library.markSeen(second, anime: anime)
                respond()
            }
        }

        await model.retryPendingWatchSync()
        XCTAssertTrue(model.hasPendingCloudChanges)
        XCTAssertTrue(model.library.isSeen(second))
        await model.retryPendingWatchSync()
        XCTAssertFalse(model.hasPendingCloudChanges)
        XCTAssertEqual(RestoreFixtureProtocol.uploadRequests, 2)
    }

    @MainActor
    func testPlaybackProgressPersistsAndClearsNearCompletion() {
        let suiteName = "AnimeCloudTests.progress.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PlaybackProgressStore(defaults: defaults)
        store.save(episodeID: "episode-1", position: 754, duration: 1_500)

        let restored = PlaybackProgressStore(defaults: defaults)
        XCTAssertEqual(restored.progress(for: "episode-1")?.position, 754)
        XCTAssertEqual(PlaybackTimeFormatter.string(754), "12:34")

        restored.save(episodeID: "episode-1", position: 1_430, duration: 1_500)
        XCTAssertNil(restored.progress(for: "episode-1"))
    }
}

private final class DelayedCatalogFixtureProtocol: URLProtocol {
    static var requestStarted: XCTestExpectation?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestStarted?.fulfill()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
            let response = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(#"{"result":[{"id":"1","name":"One Piece"}]}"#.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private final class LoginFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = #"{"result":[{"id":"29776","uniqid":"session-token","username":"Cloud Viewer","email":"viewer@example.com"},{"status":"true"}]}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class FirstSyncFixtureProtocol: URLProtocol {
    static var uploadRequests = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.httpMethod == "GET" {
            respond(status: 404, body: Data())
            return
        }

        let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.hasPrefix("application/x-www-form-urlencoded") {
            let body = #"{"result":[{"id":"first-sync-test","uniqid":"session-token","username":"First Sync","email":"first@example.com"},{"status":"true"}]}"#
            respond(status: 200, body: Data(body.utf8))
        } else {
            Self.uploadRequests += 1
            respond(status: 200, body: Data())
        }
    }

    private func respond(status: Int, body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RelatedAnimeFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = #"{"result":[{"id":"10","name":"Current"},{"id":"11","name":"Related season","year":"2026"}]}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class NewEpisodesFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = #"{"result2":[{"id":"1","name":"One Piece","image":"https://example.com/one-piece.jpg","status":"مستمر","year":"1999","epName":"الحلقة 1170"}],"result":[],"result3":[],"result4":[]}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class RestoreFixtureProtocol: URLProtocol {
    static var backup = Data()
    static var catalog: [Anime] = []
    static var uploadRequests = 0
    static var downloadRequests = 0
    static var downloadDelay: TimeInterval = 0
    static var beforeFirstUploadResponse: ((@escaping () -> Void) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var requestBody = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                requestBody.append(contentsOf: buffer.prefix(count))
            }
        }
        let body: Data
        if request.httpMethod == "GET" {
            Self.downloadRequests += 1
            body = Self.backup
        } else if (request.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("multipart/") {
            Self.uploadRequests += 1
            if Self.uploadRequests == 1, let beforeResponse = Self.beforeFirstUploadResponse {
                beforeResponse { self.respond(Data()) }
                return
            }
            body = Data()
        } else if String(data: requestBody, encoding: .utf8)?.contains("command=getAllAnime") == true {
            body = try! JSONEncoder().encode(["result": Self.catalog])
        } else {
            body = Data(#"{"result":[{"id":"restore-test","uniqid":"session-token","username":"Restore","email":"restore@example.com"},{"status":"true"}]}"#.utf8)
        }
        if request.httpMethod == "GET", Self.downloadDelay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.downloadDelay) { self.respond(body) }
        } else {
            respond(body)
        }
    }

    private func respond(_ body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
