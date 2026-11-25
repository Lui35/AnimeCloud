import XCTest
import UIKit
@testable import AnimeCloud

final class AnimeCloudTests: XCTestCase {
    @MainActor
    func testResetAnimeWatchStatePersistsAndSurvivesStaleSync() throws {
        let suite = "AnimeCloudTests.rewatch.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = LibraryStore(defaults: defaults)
        let progress = PlaybackProgressStore(defaults: defaults)
        let anime = Anime(id: "show", name: "Series")
        let other = Anime(id: "other", name: "Other series")
        let first = Episode(id: "first", name: "Episode 1")
        let tracked = Episode(id: "tracked", name: "Episode 2")
        let unseen = Episode(id: "unseen", name: "Episode 3")
        let unrelated = Episode(id: "other1", name: "Episode 1")
        library.markSeen(first, anime: anime)
        library.markSeen(tracked, anime: anime)
        library.markSeen(unrelated, anime: other)
        library.setCategory(.watched, for: anime)
        progress.save(episodeID: first.id, position: 300, duration: 1200)
        progress.save(episodeID: tracked.id, position: 400, duration: 1200)
        progress.save(episodeID: unrelated.id, position: 500, duration: 1200)
        let staleBackup = try library.backupData()
        var notifications = 0
        library.onChange = { notifications += 1 }
        let cleared = library.resetWatched(for: anime, episodeIDs: [first.id, unseen.id])
        progress.clear(episodeIDs: cleared)
        XCTAssertEqual(cleared, [first.id, tracked.id, unseen.id])
        XCTAssertEqual(notifications, 1, "Bulk reset should schedule one sync")
        XCTAssertFalse(library.isSeen(first))
        XCTAssertFalse(library.isSeen(tracked))
        XCTAssertTrue(library.isSeen(unrelated))
        XCTAssertEqual(library.category(for: anime), .watchingNow)
        XCTAssertNil(progress.progress(for: first.id))
        XCTAssertNil(progress.progress(for: tracked.id))
        XCTAssertNotNil(progress.progress(for: unrelated.id))
        let restored = LibraryStore(defaults: defaults)
        XCTAssertEqual(restored.highestWatchedEpisode(forAnimeID: anime.id), 0, "AniList needs an explicit zero, not an omitted update")
        XCTAssertTrue(restored.watchedAnimeIDs.contains(anime.id))
        try restored.mergeBackup(staleBackup, catalog: [anime, other])
        restored.mergeAniListProgress(3, anime: anime, episodes: [first, tracked, unseen])
        XCTAssertFalse(restored.isSeen(first))
        XCTAssertFalse(restored.isSeen(tracked))
        XCTAssertFalse(restored.isSeen(unseen))
        restored.markSeen(first, anime: anime)
        XCTAssertEqual(restored.highestWatchedEpisode(forAnimeID: anime.id), 1)
        XCTAssertEqual(LibraryStore(defaults: defaults).highestWatchedEpisode(forAnimeID: anime.id), 1)
    }

    @MainActor
    func testRewatchKeepsFavoriteCategory() {
        let suite = "AnimeCloudTests.rewatchFavorite.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = LibraryStore(defaults: defaults)
        let anime = Anime(id: "favorite", name: "Favorite")
        library.setCategory(.favorites, for: anime)
        library.resetWatched(for: anime, episodeIDs: ["1"])
        XCTAssertEqual(library.category(for: anime), .favorites)
    }

    func testNonFillerDownloadSelectionSkipsActiveAndReadyButIncludesFailures() {
        let anime = Anime(id: "show", name: "Series")
        let episodes = [
            Episode(id: "canon", name: "Episode 1"),
            Episode(id: "filler", name: "Episode 2", filer: "1"),
            Episode(id: "failed", name: "Episode 3"),
            Episode(id: "ready", name: "Episode 4"),
            Episode(id: "active", name: "Episode 5"),
            Episode(id: "preparing", name: "Episode 6")
        ]
        let records = Dictionary(uniqueKeysWithValues: zip(episodes.dropFirst(2), [EpisodeDownload.Status.failed, .ready, .downloading, .preparing]).map {
            ($0.0.id, EpisodeDownload(anime: anime, episode: $0.0, catalogPosition: 0, finalCanonEpisode: nil, status: $0.1))
        })
        XCTAssertEqual(DownloadEpisodeSelection.eligibleIDs(in: episodes, records: records), ["canon", "filler", "failed"])
        XCTAssertEqual(DownloadEpisodeSelection.eligibleIDs(in: episodes, records: records, excludingFillers: true), ["canon", "failed"])
        XCTAssertEqual(DownloadEpisodeSelection.eligibleIDs(in: Array(episodes[1...3]), records: records, excludingFillers: true), ["failed"], "A range must not select episodes outside it")
        XCTAssertTrue(DownloadEpisodeSelection.eligibleIDs(in: [], records: records, excludingFillers: true).isEmpty)
    }

    func testDownloadProgressHandlesUnknownTotalsAndOverruns() {
        let progress = Progress(totalUnitCount: 100)
        progress.completedUnitCount = 37
        XCTAssertEqual(EpisodeDownloads.fraction(for: progress), 0.37)
        progress.completedUnitCount = 120
        XCTAssertEqual(EpisodeDownloads.fraction(for: progress), 1)
        progress.totalUnitCount = 0
        XCTAssertNil(EpisodeDownloads.fraction(for: progress))
        progress.totalUnitCount = -1
        XCTAssertNil(EpisodeDownloads.fraction(for: progress))
    }

    @MainActor
    func testRetryAllFailedOnlyRestartsFailuresAndPersistsNewTransfers() throws {
        let suite = "AnimeCloudTests.retryDownloads.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = URL.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let anime = Anime(id: "anime", name: "Series")
        let records = [EpisodeDownload.Status.failed, .failed, .ready, .preparing, .downloading].enumerated().map { index, status in
            EpisodeDownload(anime: anime, episode: Episode(id: String(index), name: "Episode \(index)"),
                            catalogPosition: index, finalCanonEpisode: nil, status: status,
                            failure: status == .failed ? "Connection lost" : nil)
        }
        let original = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        defaults.set(try JSONEncoder().encode(original), forKey: "downloads.episodes")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadRetryFixtureProtocol.self]
        let api = LegacyAPI(session: URLSession(configuration: configuration))
        let downloads = EpisodeDownloads(api: api, defaults: defaults, directory: directory)
        defer { for id in ["0", "1"] { try? downloads.remove(id) } }

        downloads.retryAllFailed()
        let firstRetryIDs = downloads.records.mapValues(\.transferID)
        for record in records {
            let current = try XCTUnwrap(downloads.records[record.id])
            if record.status == .failed {
                XCTAssertNotEqual(current.transferID, record.transferID)
                XCTAssertEqual(current.status, .preparing)
                XCTAssertNil(current.failure)
            } else {
                XCTAssertEqual(current.transferID, record.transferID)
                XCTAssertEqual(current.status, record.status)
            }
        }
        downloads.retryAllFailed()
        downloads.retry("0")
        XCTAssertEqual(downloads.records.mapValues(\.transferID), firstRetryIDs, "Repeated retry must not duplicate active transfers")
        let restored = EpisodeDownloads(api: api, defaults: defaults, directory: directory)
        XCTAssertEqual(restored.records.mapValues(\.transferID), firstRetryIDs)
    }

    @MainActor
    func testPlaybackKeepsDisplayAwakeAndRestoresIdleTimer() {
        let application = UIApplication.shared
        let original = application.isIdleTimerDisabled
        defer { application.isIdleTimerDisabled = original }
        let controller = PlaybackDisplaySleepController()

        application.isIdleTimerDisabled = false
        controller.update(isPlaybackActive: true, isAppActive: true)
        controller.update(isPlaybackActive: true, isAppActive: true)
        XCTAssertTrue(application.isIdleTimerDisabled)

        controller.update(isPlaybackActive: false, isAppActive: true)
        XCTAssertFalse(application.isIdleTimerDisabled, "Pausing or ending playback restores auto-lock")

        controller.update(isPlaybackActive: true, isAppActive: true)
        controller.update(isPlaybackActive: true, isAppActive: false)
        XCTAssertFalse(application.isIdleTimerDisabled, "Background playback allows display sleep")

        controller.update(isPlaybackActive: true, isAppActive: true)
        XCTAssertTrue(application.isIdleTimerDisabled, "Returning to active playback keeps the display awake")
        controller.update(isPlaybackActive: false, isAppActive: false)
        XCTAssertFalse(application.isIdleTimerDisabled)

        application.isIdleTimerDisabled = true
        controller.update(isPlaybackActive: true, isAppActive: true)
        controller.update(isPlaybackActive: false, isAppActive: false)
        XCTAssertTrue(application.isIdleTimerDisabled, "Preserve an existing keep-awake request")
    }

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

    func testFullscreenPlayerGestureZonesReserveCenterForExit() {
        XCTAssertEqual(PlayerGestureZone.at(90, width: 900), .volume)
        XCTAssertEqual(PlayerGestureZone.at(450, width: 900), .center)
        XCTAssertEqual(PlayerGestureZone.at(810, width: 900), .brightness)
        XCTAssertFalse(PlayerGestureZone.allowsLevelAdjustment(in: CGSize(width: 393, height: 852)))
        XCTAssertTrue(PlayerGestureZone.allowsLevelAdjustment(in: CGSize(width: 852, height: 393)))
        XCTAssertFalse(PlayerFullscreenGesture.isVertical(CGSize(width: 80, height: 15)))
    }

    func testPlayNextWindowUsesTwoMinutesByDefaultAndAllowsAnOverride() {
        XCTAssertFalse(NextEpisodeTiming.isNearEnd(position: 1_379, duration: 1_500))
        XCTAssertTrue(NextEpisodeTiming.isNearEnd(position: 1_380, duration: 1_500))
        XCTAssertFalse(NextEpisodeTiming.isNearEnd(position: 1_409, duration: 1_500, leadTime: 90))
        XCTAssertTrue(NextEpisodeTiming.isNearEnd(position: 1_410, duration: 1_500, leadTime: 90))
        XCTAssertTrue(NextEpisodeTiming.isNearEnd(position: 180, duration: 480, leadTime: 300))
        XCTAssertFalse(NextEpisodeTiming.isNearEnd(position: 0, duration: 30))
        XCTAssertTrue(NextEpisodeTiming.isNearEnd(position: 20, duration: 30))
        XCTAssertFalse(NextEpisodeTiming.isNearEnd(position: 120, duration: .infinity))
        XCTAssertFalse(NextEpisodeTiming.isNearEnd(position: .nan, duration: 1_500))
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
        XCTAssertEqual(LibraryStore(defaults: defaults).recentlyPlayedAnime.map(\.id), [anime.id])
        store.recordPlayback(of: episode, anime: anime, episodes: episodes, position: 50, duration: 100)
        XCTAssertEqual(store.category(for: anime), .watchingNow)
        XCTAssertFalse(store.isSeen(episode))
        XCTAssertEqual(LibraryStore(defaults: defaults).category(for: anime), .watchingNow)
        XCTAssertEqual(store.favorites.map(\.id), [anime.id])
        store.recordPlayback(of: episode, anime: anime, episodes: episodes, position: 60, duration: 100)
        XCTAssertEqual(changes, 1, "Periodic playback must not repeatedly reschedule cloud sync")
    }

    @MainActor
    func testContinueWatchingResumesUnwatchedProgressOrPicksTheNextEpisode() {
        let suite = "AnimeCloudTests.continueWatching.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = LibraryStore(defaults: defaults)
        let progress = PlaybackProgressStore(defaults: defaults)
        let episodes = (1...4).reversed().map { Episode(id: "episode-\($0)", name: "Episode \($0)") }
        let (fourth, third, second, first) = (episodes[0], episodes[1], episodes[2], episodes[3])

        XCTAssertEqual(progress.episodeToContinue(in: episodes, library: library), first)
        library.markSeen(second)
        progress.save(episodeID: second.id, position: 10, duration: 100)
        XCTAssertEqual(progress.episodeToContinue(in: episodes, library: library), third)
        progress.save(episodeID: fourth.id, position: 20, duration: 100)
        XCTAssertEqual(progress.episodeToContinue(in: episodes, library: library), fourth)
        library.markSeen(third)
        library.markSeen(fourth)
        XCTAssertEqual(progress.episodeToContinue(in: episodes, library: library), first)
        library.markSeen(first)
        XCTAssertNil(progress.episodeToContinue(in: episodes, library: library))
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

    func testNextEpisodeSkipsConsecutiveFillersAndCanOverride() {
        let episodes = [
            Episode(id: "5", name: "Episode 5"),
            Episode(id: "4", name: "Episode 4", filer: "1"),
            Episode(id: "3", name: "Episode 3", filer: "1"),
            Episode(id: "2", name: "Episode 2"),
            Episode(id: "1", name: "Episode 1")
        ]
        XCTAssertEqual(episodes.nextEpisode(after: episodes[4], skippingFillers: true)?.id, "2")
        XCTAssertEqual(episodes.nextEpisode(after: episodes[3], skippingFillers: true)?.id, "5")
        XCTAssertEqual(episodes.nextEpisode(after: episodes[3])?.id, "3")
        XCTAssertEqual(episodes.nextEpisode(after: episodes[2], skippingFillers: true)?.id, "5")
        XCTAssertNil(episodes.nextEpisode(after: episodes[0], skippingFillers: true))
        XCTAssertNil(episodes.nextEpisode(after: Episode(id: "missing", name: "Episode 0"), skippingFillers: true))
    }

    func testNextEpisodeWithOnlyFillerRemainingAndOfflineGaps() {
        let filler = Episode(id: "4", name: "Episode 4", filer: "1")
        let current = Episode(id: "1", name: "Episode 1")
        let offline = [filler, current]
        XCTAssertEqual(offline.nextEpisode(after: current, skippingFillers: true)?.id, filler.id)
        XCTAssertEqual(offline.nextEpisode(after: current)?.id, filler.id)
        let laterCanon = Episode(id: "8", name: "Episode 8")
        XCTAssertEqual([laterCanon, filler, current].nextEpisode(after: current, skippingFillers: true)?.id, laterCanon.id)
        XCTAssertNil([Episode]().nextEpisode(after: current, skippingFillers: true))
    }

    func testSkippingFillersFallsBackToImmediateNextWhenOnlyFillersRemain() {
        let current = Episode(id: "1", name: "Episode 1")
        let immediate = Episode(id: "2", name: "Episode 2", filer: "1")
        let last = Episode(id: "3", name: "Episode 3", filer: "1")
        let episodes = [last, immediate, current]
        XCTAssertEqual(episodes.nextEpisode(after: current, skippingFillers: true)?.id, immediate.id)
        XCTAssertEqual(episodes.nextEpisode(after: current)?.id, immediate.id)
        XCTAssertEqual(episodes.nextEpisode(after: immediate, skippingFillers: true)?.id, last.id)
        XCTAssertNil(episodes.nextEpisode(after: last, skippingFillers: true))
    }

    @MainActor
    func testEpisodeAdvanceShortTapFiresExactlyOnce() {
        let control = EpisodeAdvanceControl(holdDuration: 0.65)
        var events: [String] = []
        control.onTap = { events.append("tap") }
        control.onHold = { events.append("hold") }
        control.onPressChanged = { events.append($0 ? "down" : "up") }
        control.sendActions(for: .touchDown)
        control.sendActions(for: .touchUpInside)
        control.sendActions(for: .touchUpInside)
        XCTAssertEqual(events, ["down", "up", "tap"])
    }

    @MainActor
    func testEpisodeAdvanceHoldDoesNotAlsoTapOnRelease() async {
        let control = EpisodeAdvanceControl(holdDuration: 0.01)
        let held = expectation(description: "Hold recognized")
        var taps = 0
        var holds = 0
        control.onTap = { taps += 1 }
        control.onHold = { holds += 1; held.fulfill() }
        control.sendActions(for: .touchDown)
        await fulfillment(of: [held], timeout: 1)
        control.sendActions(for: .touchUpInside)
        XCTAssertEqual(holds, 1)
        XCTAssertEqual(taps, 0)
    }

    @MainActor
    func testEpisodeAdvanceDragCancellationFiresNeitherAction() async {
        let control = EpisodeAdvanceControl(holdDuration: 0.01)
        let action = expectation(description: "Cancelled press has no action")
        action.isInverted = true
        control.onTap = { action.fulfill() }
        control.onHold = { action.fulfill() }
        control.sendActions(for: .touchDown)
        control.sendActions(for: .touchDragExit)
        control.sendActions(for: .touchUpInside)
        await fulfillment(of: [action], timeout: 0.05)
    }

    func testCatalogCacheKeysIncludeCommandAndEveryField() async throws {
        let (session, cache) = catalogCacheFixture()
        let api = LegacyAPI(session: session, cache: cache)
        _ = try await api.catalog(.getAllAnime, fields: ["year": "2025", "hiddenMode": "0"])
        _ = try await api.catalog(.getAllAnime, fields: ["hiddenMode": "0", "year": "2025"])
        XCTAssertEqual(CatalogCacheFixtureProtocol.requests, 1)
        _ = try await api.catalog(.getAllAnime, fields: ["year": "2026", "hiddenMode": "0"])
        _ = try await api.catalog(.getMost, fields: ["year": "2025", "hiddenMode": "0"])
        XCTAssertEqual(CatalogCacheFixtureProtocol.requests, 3)
    }

    func testConcurrentCatalogRequestsShareOneFetch() async throws {
        let (session, cache) = catalogCacheFixture()
        CatalogCacheFixtureProtocol.delay = 0.05
        let api = LegacyAPI(session: session, cache: cache)
        async let first = api.catalog(.getAllAnime)
        async let second = api.catalog(.getAllAnime)
        let values = try await (first, second)
        XCTAssertEqual(values.0, values.1)
        XCTAssertEqual(CatalogCacheFixtureProtocol.requests, 1)
    }

    func testCatalogCacheSurvivesClientRecreationExpiresAndAllowsRefresh() async throws {
        let (session, cache) = catalogCacheFixture()
        let original = LegacyAPI(session: session, cache: cache, now: { Date(timeIntervalSince1970: 1_000) })
        _ = try await original.catalog(.getAllAnime)
        let restored = LegacyAPI(session: session, cache: cache, now: { Date(timeIntervalSince1970: 1_001) })
        _ = try await restored.catalog(.getAllAnime)
        XCTAssertEqual(CatalogCacheFixtureProtocol.requests, 1)
        let expired = LegacyAPI(session: session, cache: cache, now: { Date(timeIntervalSince1970: 1_301) })
        _ = try await expired.catalog(.getAllAnime)
        XCTAssertEqual(CatalogCacheFixtureProtocol.requests, 2)
        _ = try await expired.catalog(.getAllAnime, forceRefresh: true)
        XCTAssertEqual(CatalogCacheFixtureProtocol.requests, 3)
    }

    func testCatalogCacheRejectsHTTPAndMalformedResponses() async throws {
        let (session, cache) = catalogCacheFixture()
        let api = LegacyAPI(session: session, cache: cache)
        CatalogCacheFixtureProtocol.status = 500
        do {
            _ = try await api.catalog(.getAllAnime)
            XCTFail("HTTP errors must not be cached")
        } catch {}
        CatalogCacheFixtureProtocol.status = 200
        CatalogCacheFixtureProtocol.body = Data("invalid JSON".utf8)
        do {
            _ = try await api.catalog(.getAllAnime)
            XCTFail("Invalid JSON must not be cached")
        } catch {}
        CatalogCacheFixtureProtocol.body = CatalogCacheFixtureProtocol.catalogBody
        let values = try await api.catalog(.getAllAnime)
        let cached = try await api.catalog(.getAllAnime)
        XCTAssertEqual(values, cached)
        XCTAssertEqual(CatalogCacheFixtureProtocol.requests, 3)
    }

    func testCatalogCacheOfflineFallbackIsBoundedAndDoesNotHideCancellation() async throws {
        let (session, cache) = catalogCacheFixture()
        let original = LegacyAPI(session: session, cache: cache, now: { Date(timeIntervalSince1970: 1_000) })
        let expected = try await original.catalog(.getAllAnime)
        let offline = LegacyAPI(session: session, cache: cache, now: { Date(timeIntervalSince1970: 1_400) })
        CatalogCacheFixtureProtocol.failure = .notConnectedToInternet
        let values = try await offline.catalog(.getAllAnime)
        XCTAssertEqual(values, expected)
        let tooOld = LegacyAPI(session: session, cache: cache, now: { Date(timeIntervalSince1970: 1_000 + 8 * 24 * 60 * 60) })
        do {
            _ = try await tooOld.catalog(.getAllAnime)
            XCTFail("Expired offline data must not be used indefinitely")
        } catch let error as URLError { XCTAssertEqual(error.code, .notConnectedToInternet) }
        CatalogCacheFixtureProtocol.failure = .cancelled
        do {
            _ = try await offline.catalog(.getAllAnime)
            XCTFail("Cancellation must not return cached data")
        } catch let error as URLError { XCTAssertEqual(error.code, .cancelled) }
        CatalogCacheFixtureProtocol.failure = nil
        CatalogCacheFixtureProtocol.status = 500
        do {
            _ = try await offline.catalog(.getAllAnime)
            XCTFail("A server error must remain visible")
        } catch let error as APIError {
            guard case .server(500) = error else { return XCTFail("Expected HTTP 500") }
        }
    }

    func testPlaybackURLsAndAccountRequestsAreNeverCached() async throws {
        let (session, cache) = catalogCacheFixture()
        let api = LegacyAPI(session: session, cache: cache)
        CatalogCacheFixtureProtocol.body = Data(#"{"result":[{"url":"https://example.com/episode.mp4"}]}"#.utf8)
        _ = try await api.playback(epID: "1", quality: "720")
        _ = try await api.playback(epID: "1", quality: "720")
        CatalogCacheFixtureProtocol.body = Data(#"{"result":[]}"#.utf8)
        _ = try await api.comments(animeID: "1")
        _ = try await api.comments(animeID: "1")
        XCTAssertEqual(CatalogCacheFixtureProtocol.requests, 4)
        XCTAssertNil(LegacyCommand.userLogin.cacheLifetime)
        XCTAssertNil(LegacyCommand.saveBackup.cacheLifetime)
        XCTAssertNil(LegacyCommand.addComment.cacheLifetime)
    }

    private func catalogCacheFixture() -> (URLSession, URLCache) {
        CatalogCacheFixtureProtocol.requests = 0
        CatalogCacheFixtureProtocol.status = 200
        CatalogCacheFixtureProtocol.failure = nil
        CatalogCacheFixtureProtocol.delay = 0
        CatalogCacheFixtureProtocol.body = CatalogCacheFixtureProtocol.catalogBody
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.protocolClasses = [CatalogCacheFixtureProtocol.self]
        return (URLSession(configuration: configuration), URLCache(memoryCapacity: 1_024 * 1_024, diskCapacity: 0, diskPath: nil))
    }

    func testWatchOrderKeepsResearchedOrderAndMatchesAliasesWithoutSortingByYear() throws {
        let anchor = Anime(id: "second", name: "Sky Chronicle II", year: "2017")
        let first = Anime(id: "first", name: "Sky Chronicle", year: "2019")
        let plan = try GeminiWatchOrderService.parse(watchResearchFixture(), anime: anchor, mode: .firstWatch, catalog: [anchor, first])
        XCTAssertEqual(plan.steps.map(\.anime?.id), ["first", "second"])
        XCTAssertEqual(plan.sources.first?.url.absoluteString, "https://example.com/viewing-guide")
        XCTAssertFalse(plan.searchSuggestions.isEmpty)
        XCTAssertEqual(plan.mode, .firstWatch)
    }

    func testWatchOrderRejectsUngroundedAndIncompleteAnswers() throws {
        let anchor = Anime(id: "second", name: "Sky Chronicle II", year: "2017")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: watchResearchFixture()) as? [String: Any])
        object["steps"] = [["type": "model_output", "content": [["type": "text", "text": "{}"]]]]
        XCTAssertThrowsError(try GeminiWatchOrderService.parse(JSONSerialization.data(withJSONObject: object), anime: anchor, mode: .firstWatch, catalog: [anchor]))
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: watchResearchFixture()) as? [String: Any])
        object["status"] = "in_progress"
        XCTAssertThrowsError(try GeminiWatchOrderService.parse(JSONSerialization.data(withJSONObject: object), anime: anchor, mode: .firstWatch, catalog: [anchor]))
    }

    func testWatchOrderRejectsDuplicatePartsAndUnsafeSources() throws {
        let anchor = Anime(id: "second", name: "Sky Chronicle II", year: "2017")
        XCTAssertThrowsError(try GeminiWatchOrderService.parse(watchResearchFixture(duplicate: true), anime: anchor, mode: .firstWatch, catalog: [anchor]))
        XCTAssertThrowsError(try GeminiWatchOrderService.parse(watchResearchFixture(sourceURL: "javascript:alert(1)"), anime: anchor, mode: .firstWatch, catalog: [anchor]))
        XCTAssertFalse(WatchSource.isWebURL(URL(string: "file:///etc/passwd")!))
        XCTAssertFalse(WatchSource.isWebURL(URL(string: "https://user:secret@example.com")!))
        XCTAssertThrowsError(try GeminiWatchOrderService.parse(watchResearchFixture(), anime: Anime(id: "wrong", name: "Another franchise"), mode: .firstWatch, catalog: []))
    }

    func testWatchTitleMatchingKeepsAmbiguousOrDifferentAdaptationsUnmatched() {
        let step = WatchPlanStep(title: "Cloud Story", aliases: ["قصة الغيمة"], year: 2020, format: "TV", isOptional: false, reason: "Start here")
        let original = Anime(id: "original", name: "Cloud Story", year: "2020")
        let remake = Anime(id: "remake", name: "Cloud Story", year: "2025")
        XCTAssertEqual(step.matched(in: [original, remake])?.id, original.id)
        XCTAssertNil(step.matched(in: [remake]))
        XCTAssertNil(step.matched(in: [original, Anime(id: "duplicate", name: "Cloud Story", year: "2020")]))
        XCTAssertEqual(step.matched(in: [Anime(id: "arabic", name: "قصة الغيمة", year: "2020")])?.id, "arabic")
    }

    func testGeminiResearchRequestUsesSearchAndStructuredOutputWithoutLeakingKeyIntoPrompt() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WatchResearchFixtureProtocol.self]
        WatchResearchFixtureProtocol.responseBody = try watchResearchFixture()
        WatchResearchFixtureProtocol.status = 200
        let service = GeminiWatchOrderService(session: URLSession(configuration: configuration))
        let anchor = Anime(id: "second", name: "Sky Chronicle II", year: "2017")
        let plan = try await service.research(anime: anchor, related: [], mode: .chronological, catalog: [anchor], apiKey: "fixture-only-not-a-real-key")
        XCTAssertEqual(plan.mode, .chronological)
        let request = try XCTUnwrap(WatchResearchFixtureProtocol.requestBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, GeminiWatchOrderService.model)
        XCTAssertEqual(json["store"] as? Bool, false)
        XCTAssertEqual((json["tools"] as? [[String: String]])?.first?["type"], "google_search")
        XCTAssertEqual((json["response_format"] as? [String: Any])?["mime_type"] as? String, "application/json")
        XCTAssertFalse(String(decoding: request, as: UTF8.self).contains("fixture-only-not-a-real-key"))
        XCTAssertTrue(WatchResearchFixtureProtocol.keyHeaderWasPresent)
        XCTAssertNil(WatchResearchFixtureProtocol.url?.query)
    }

    func testGeminiResearchSurfacesQuotaInsteadOfInventingAPlan() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WatchResearchFixtureProtocol.self]
        WatchResearchFixtureProtocol.status = 429
        WatchResearchFixtureProtocol.responseBody = Data()
        defer { WatchResearchFixtureProtocol.status = 200 }
        let service = GeminiWatchOrderService(session: URLSession(configuration: configuration))
        do {
            _ = try await service.research(anime: Anime(id: "1", name: "Cloud Story"), related: [], mode: .firstWatch, catalog: [], apiKey: "fixture-only-not-a-real-key")
            XCTFail("Quota failure must not produce an invented local order")
        } catch let error as WatchOrderError {
            guard case .quota = error else { return XCTFail("Expected quota error") }
        }
    }

    @MainActor
    func testWatchPlanPersistenceAndProgressKeepMissingRequiredPartsInSequence() throws {
        let suiteName = "AnimeCloudTests.watchPlan.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let library = LibraryStore(defaults: defaults)
        let store = WatchPlanStore(defaults: defaults)
        let anchor = Anime(id: "second", name: "Sky Chronicle II", year: "2017")
        let first = Anime(id: "first", name: "Sky Chronicle", year: "2019")
        var plan = try GeminiWatchOrderService.parse(watchResearchFixture(), anime: anchor, mode: .firstWatch, catalog: [anchor, first])
        plan.steps.insert(WatchPlanStep(title: "Required film", aliases: [], year: 2018, format: "Movie", isOptional: false, reason: "Required story between parts"), at: 1)
        try store.save(plan)
        library.setCategory(.watched, for: first)
        XCTAssertEqual(store.nextStep(in: plan, library: library)?.title, "Required film", "Do not skip a missing required upload")
        let restored = WatchPlanStore(defaults: defaults)
        XCTAssertEqual(restored.plans.first?.steps.count, 3)
        XCTAssertEqual(restored.plans.first?.sources, plan.sources)
        try restored.update(plan.id) { $0.steps[1].completionOverride = true }
        XCTAssertEqual(restored.nextStep(in: restored.plans[0], library: library)?.anime?.id, anchor.id)
        XCTAssertNil(library.category(for: anchor), "Plan-only completion must not rewrite the library")
    }

    @MainActor
    func testWatchPlanOptionalPartsAndManualRewatchOverride() throws {
        let suiteName = "AnimeCloudTests.optionalPlan.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let library = LibraryStore(defaults: defaults)
        let store = WatchPlanStore(defaults: defaults)
        let anchor = Anime(id: "second", name: "Sky Chronicle II", year: "2017")
        var plan = try GeminiWatchOrderService.parse(watchResearchFixture(), anime: anchor, mode: .firstWatch, catalog: [anchor])
        plan.steps.insert(WatchPlanStep(title: "Side story", aliases: [], year: 2016, format: "OVA", isOptional: true, reason: "Optional"), at: 0)
        XCTAssertEqual(store.nextStep(in: plan, library: library)?.title, "Sky Chronicle")
        plan.includeOptional = true
        XCTAssertEqual(store.nextStep(in: plan, library: library)?.title, "Side story")
        library.setCategory(.watched, for: anchor)
        XCTAssertTrue(store.isComplete(plan.steps[2], library: library))
        plan.steps[2].completionOverride = false
        XCTAssertFalse(store.isComplete(plan.steps[2], library: library), "Explicit rewatch overrides past library completion")
    }

    @MainActor
    func testUpdatingResearchedPlanPreservesProgressAndEncodingFailureKeepsSavedData() throws {
        let suiteName = "AnimeCloudTests.updatePlan.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = WatchPlanStore(defaults: defaults)
        let anchor = Anime(id: "second", name: "Sky Chronicle II", year: "2017")
        var plan = try GeminiWatchOrderService.parse(watchResearchFixture(), anime: anchor, mode: .firstWatch, catalog: [anchor])
        plan.steps[0].completionOverride = true
        try store.save(plan)
        let regenerated = try GeminiWatchOrderService.parse(watchResearchFixture(), anime: anchor, mode: .firstWatch, catalog: [anchor])
        try store.save(regenerated)
        XCTAssertEqual(store.plans[0].steps[0].completionOverride, true)
        let invalid = WatchPlan(anchor: anchor, mode: .firstWatch, guide: "Invalid timestamp", cautions: [], steps: [], sources: [], searchSuggestions: "", researchedAt: Date(timeIntervalSince1970: .infinity))
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(store.plans.count, 1)
        XCTAssertEqual(store.plans[0].steps.count, 2)
    }

    private func watchResearchFixture(duplicate: Bool = false, sourceURL: String = "https://example.com/viewing-guide") throws -> Data {
        let first: [String: Any] = ["title": "Sky Chronicle", "aliases": [], "year": 2019, "format": "TV", "optional": false, "reason": "Start with the recommended introduction"]
        let second: [String: Any] = ["title": "Sky Chronicle II", "aliases": [], "year": 2017, "format": "TV", "optional": false, "reason": "Watch after the introduction despite the release dates"]
        let payload: [String: Any] = ["guide": "1. Sky Chronicle\n2. Sky Chronicle II", "cautions": ["Fixture guidance, not a live researched order"], "parts": duplicate ? [second, second] : [first, second]]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: ["status": "completed", "steps": [
            ["type": "google_search_call", "arguments": ["queries": ["viewing order"]]],
            ["type": "google_search_result", "result": [["search_suggestions": "<a href='https://www.google.com/search?q=viewing+order'>Search</a>"]]],
            ["type": "model_output", "content": [["type": "text", "text": text, "annotations": [["type": "url_citation", "title": "Viewing guide", "url": sourceURL, "start_index": 0, "end_index": 10]]]]]
        ]])
    }

    func testGeminiQuotaDistinguishesUnavailableDailyAndTemporaryLimits() throws {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!
        let response = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: nil)!
        let zero = Data(#"{"error":{"message":"Quota exceeded","details":[{"violations":[{"quotaValue":"0"}]}]}}"#.utf8)
        guard case .quotaUnavailable = GeminiWatchOrderService.quotaError(zero, response: response) else { return XCTFail("Zero quota is not a temporary rate limit") }
        let daily = Data(#"{"error":{"details":[{"violations":[{"quotaId":"GenerateRequestsPerDayPerProjectPerModel-FreeTier","quotaValue":"20"}]},{"retryDelay":"2s"}]}}"#.utf8)
        guard case .dailyQuota = GeminiWatchOrderService.quotaError(daily, response: response) else { return XCTFail("A daily cap must not suggest a two-second retry") }
        let temporary = Data(#"{"error":{"details":[{"retryDelay":"12.4s"}]}}"#.utf8)
        guard case .rateLimited(let seconds) = GeminiWatchOrderService.quotaError(temporary, response: response) else { return XCTFail("Expected a retry delay") }
        XCTAssertEqual(seconds, 13)
    }

    func testGeminiQuotaHandlesMissingDetailsAndUntrustedRetryDelays() {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!
        let response = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "10"])!
        guard case .rateLimited(let seconds) = GeminiWatchOrderService.quotaError(Data(), response: response) else { return XCTFail("Retry-After should work without a response body") }
        XCTAssertEqual(seconds, 10)
        let fallback = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "inf"])!
        guard case .quota = GeminiWatchOrderService.quotaError(Data(), response: fallback) else { return XCTFail("Invalid delays should use the generic diagnostic") }
        let zeroMessage = Data(#"{"error":{"message":"Quota exceeded for metric, limit: 0, model: gemini-3.8-flash"}}"#.utf8)
        guard case .quotaUnavailable = GeminiWatchOrderService.quotaError(zeroMessage, response: fallback) else { return XCTFail("Zero-limit messages should explain missing quota") }
    }

    @MainActor
    func testExportOrganizesEpisodesAndPreservesOriginals() async throws {
        let suite = "AnimeCloudTests.export.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = URL.temporaryDirectory.appending(path: suite)
        let output = directory.appending(path: "export")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let anime = Anime(id: "anime", name: "Series/Name")
        let records = [
            EpisodeDownload(anime: anime, episode: Episode(id: "1", name: "Episode 1"), catalogPosition: 0,
                            finalCanonEpisode: nil, status: .ready, relativePath: "1.mp4"),
            EpisodeDownload(anime: anime, episode: Episode(id: "2", name: "Episode 1"), catalogPosition: 1,
                            finalCanonEpisode: nil, status: .ready, relativePath: "2.mp4"),
            EpisodeDownload(anime: Anime(id: "other", name: "Series/Name"), episode: Episode(id: "3", name: "Episode 2"),
                            catalogPosition: 0, finalCanonEpisode: nil, status: .ready, relativePath: "3.mov")
        ]
        for record in records {
            try Data(record.id.utf8).write(to: directory.appending(path: record.relativePath!))
        }
        defaults.set(try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })),
                     forKey: "downloads.episodes")
        let downloads = EpisodeDownloads(api: .live, defaults: defaults, directory: directory)
        let folder = try await downloads.exportVideos(records.map(\.id), to: output)
        for (path, expected) in [
            ("Series-Name/Series-Name - Episode 1.mp4", "1"),
            ("Series-Name/Series-Name - Episode 1 (2).mp4", "2"),
            ("Series-Name (2)/Series-Name - Episode 2.mov", "3")
        ] {
            XCTAssertEqual(try Data(contentsOf: folder.appending(path: path)), Data(expected.utf8))
        }
        for record in records {
            XCTAssertNotNil(downloads.localURL(for: record.id))
        }
        XCTAssertEqual(downloads.records.count, 3)
        try downloads.remove("1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "Series-Name/Series-Name - Episode 1.mp4").path))
    }

    @MainActor
    func testExportRejectsMissingDownloadsAndCleansFailedBatch() async throws {
        let suite = "AnimeCloudTests.exportFailure.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = URL.temporaryDirectory.appending(path: suite)
        let output = directory.appending(path: "export")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = EpisodeDownload(anime: Anime(id: "anime", name: "Series"),
                                     episode: Episode(id: "hls", name: "Episode 1"), catalogPosition: 0,
                                     finalCanonEpisode: nil, status: .ready, relativePath: suite + ".movpkg", isHLS: true)
        // An invalid local package exercises the conversion failure without a network dependency.
        let package = URL.homeDirectory.appending(path: suite + ".movpkg")
        try Data([0]).write(to: package)
        defer { try? FileManager.default.removeItem(at: package) }
        defaults.set(try JSONEncoder().encode([record.id: record]), forKey: "downloads.episodes")
        let downloads = EpisodeDownloads(api: .live, defaults: defaults, directory: directory)
        do {
            _ = try await downloads.exportVideos(["missing"], to: output)
            XCTFail("Missing episodes must not be exported")
        } catch { XCTAssertTrue(error is DownloadError) }
        do {
            _ = try await downloads.exportVideos([record.id], to: output)
            XCTFail("An unsupported package must not be exported as a video")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertNotNil(downloads.localURL(for: record.id))
        }
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

    @MainActor
    func testClearingResumePositionsPreservesWatchedStatus() {
        let suite = "AnimeCloudTests.clearResume.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = LibraryStore(defaults: defaults)
        let progress = PlaybackProgressStore(defaults: defaults)
        let watched = Episode(id: "watched", name: "Episode 1")
        library.markSeen(watched)
        progress.save(episodeID: watched.id, position: 120, duration: 1_500)
        progress.save(episodeID: "another-series", position: 60, duration: 1_500)

        progress.clear(episodeIDs: [watched.id, "missing"])
        let restored = PlaybackProgressStore(defaults: defaults)
        XCTAssertNil(restored.progress(for: watched.id))
        XCTAssertEqual(restored.progress(for: "another-series")?.position, 60)

        restored.clearAll()
        XCTAssertTrue(PlaybackProgressStore(defaults: defaults).entries.isEmpty)
        XCTAssertTrue(LibraryStore(defaults: defaults).isSeen(watched))
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

private final class CatalogCacheFixtureProtocol: URLProtocol {
    static let catalogBody = Data(#"{"result":[{"id":"1","name":"Cloud Story"}]}"#.utf8)
    static var requests = 0
    static var status = 200
    static var body = catalogBody
    static var failure: URLError.Code?
    static var delay: TimeInterval = 0
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        Self.lock.unlock()
        let status = Self.status
        let body = Self.body
        let failure = Self.failure
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay) {
            if let failure {
                self.client?.urlProtocol(self, didFailWithError: URLError(failure))
                return
            }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private final class WatchResearchFixtureProtocol: URLProtocol {
    static var status = 200
    static var responseBody = Data()
    static var requestBody: Data?
    static var keyHeaderWasPresent = false
    static var url: URL?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.url = request.url
        Self.keyHeaderWasPresent = request.value(forHTTPHeaderField: "x-goog-api-key") != nil
        if let body = request.httpBody { Self.requestBody = body }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            Self.requestBody = body
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class DownloadRetryFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
