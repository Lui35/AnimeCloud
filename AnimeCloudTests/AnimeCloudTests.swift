import XCTest
@testable import AnimeCloud

final class AnimeCloudTests: XCTestCase {
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
    func testFirstLoginNeverUploadsAnEmptyBackup() async {
        let userID = "first-sync-test"
        UserDefaults.standard.removeObject(forKey: "cloud.baseline.\(userID)")
        UserDefaults.standard.removeObject(forKey: "cloud.dirty.\(userID)")
        FirstSyncFixtureProtocol.uploadRequests = 0

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FirstSyncFixtureProtocol.self]
        let model = AppModel(api: LegacyAPI(session: URLSession(configuration: configuration)))

        let loggedIn = await model.login(email: "first@example.com", password: "test-only")

        XCTAssertTrue(loggedIn)
        XCTAssertEqual(FirstSyncFixtureProtocol.uploadRequests, 0)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "cloud.baseline.\(userID)"))
        UserDefaults.standard.removeObject(forKey: "cloud.baseline.\(userID)")
        UserDefaults.standard.removeObject(forKey: "cloud.dirty.\(userID)")
        UserDefaults.standard.removeObject(forKey: "account.session")
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
