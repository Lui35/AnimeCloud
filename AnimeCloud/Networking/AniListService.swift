import AuthenticationServices
import Combine
import Foundation
import Security
import UIKit

enum AniListStatus: String, Codable, Sendable {
    case current = "CURRENT"
    case planning = "PLANNING"
    case completed = "COMPLETED"
    case paused = "PAUSED"
    case dropped = "DROPPED"
    case repeating = "REPEATING"

    var libraryCategory: LibraryCategory? {
        switch self {
        case .current, .repeating: .watchingNow
        case .planning, .paused: .watchLater
        case .completed: .watched
        case .dropped: nil
        }
    }
}

extension LibraryCategory {
    var aniListStatus: AniListStatus? {
        switch self {
        case .watchingNow: .current
        case .watchLater: .planning
        case .watched: .completed
        case .favorites: nil
        }
    }
}

struct AniListAccount: Codable, Hashable, Sendable {
    var id: Int
    var name: String
}

struct AniListMediaTitle: Codable, Hashable, Sendable {
    var romaji: String?
    var english: String?
    var native: String?

    var values: [String] { [romaji, english, native].compactMap { $0 } }
}

struct AniListFuzzyDate: Codable, Hashable, Sendable {
    var year: Int?
}

struct AniListMedia: Codable, Identifiable, Hashable, Sendable {
    var id: Int
    var title: AniListMediaTitle
    var startDate: AniListFuzzyDate?
}

struct AniListEntry: Codable, Hashable, Sendable {
    var id: Int
    var mediaId: Int
    var status: AniListStatus?
    var progress: Int?
    var media: AniListMedia
}

struct AniListClient: Sendable {
    private let session: URLSession
    private let endpoint = URL(string: "https://graphql.anilist.co")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func viewer(token: String) async throws -> AniListAccount {
        struct DataShape: Decodable { var Viewer: AniListAccount }
        let result: DataShape = try await request(
            query: "query { Viewer { id name } }",
            variables: [:],
            token: token
        )
        return result.Viewer
    }

    func mediaList(userID: Int, token: String) async throws -> [AniListEntry] {
        struct DataShape: Decodable {
            struct Collection: Decodable {
                struct List: Decodable { var entries: [AniListEntry] }
                var lists: [List]?
            }
            var MediaListCollection: Collection
        }
        let query = """
        query ($userId: Int!) {
          MediaListCollection(userId: $userId, type: ANIME) {
            lists {
              entries {
                id mediaId status progress
                media { id title { romaji english native } startDate { year } }
              }
            }
          }
        }
        """
        let result: DataShape = try await request(query: query, variables: ["userId": userID], token: token)
        var unique: [Int: AniListEntry] = [:]
        for entry in result.MediaListCollection.lists?.flatMap(\.entries) ?? [] {
            if let current = unique[entry.mediaId] {
                var merged = current
                if (entry.progress ?? 0) > (current.progress ?? 0) { merged.progress = entry.progress }
                if merged.status == nil { merged.status = entry.status }
                unique[entry.mediaId] = merged
            } else {
                unique[entry.mediaId] = entry
            }
        }
        return Array(unique.values)
    }

    func search(title: String, token: String) async throws -> [AniListMedia] {
        struct DataShape: Decodable {
            struct PageShape: Decodable { var media: [AniListMedia] }
            var Page: PageShape
        }
        let query = """
        query ($search: String!) {
          Page(page: 1, perPage: 8) {
            media(search: $search, type: ANIME) {
              id title { romaji english native } startDate { year }
            }
          }
        }
        """
        let result: DataShape = try await request(query: query, variables: ["search": title], token: token)
        return result.Page.media
    }

    func save(mediaID: Int, status: AniListStatus, progress: Int?, token: String) async throws {
        struct DataShape: Decodable {
            struct Saved: Decodable { var id: Int }
            var SaveMediaListEntry: Saved
        }
        let query = """
        mutation ($mediaId: Int!, $status: MediaListStatus, $progress: Int) {
          SaveMediaListEntry(mediaId: $mediaId, status: $status, progress: $progress) { id }
        }
        """
        var variables: [String: Any] = ["mediaId": mediaID, "status": status.rawValue]
        if let progress { variables["progress"] = progress }
        let _: DataShape = try await request(query: query, variables: variables, token: token)
    }

    private func request<T: Decodable>(query: String, variables: [String: Any], token: String) async throws -> T {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AniListError.invalidResponse }
        let envelope = try JSONDecoder().decode(GraphQLResponse<T>.self, from: data)
        if let error = envelope.errors?.first { throw AniListError.graphQL(error.message) }
        guard (200..<300).contains(http.statusCode), let value = envelope.data else {
            if http.statusCode == 401 { throw AniListError.expiredSession }
            throw AniListError.server(http.statusCode)
        }
        return value
    }
}

private struct GraphQLResponse<Value: Decodable>: Decodable {
    struct Failure: Decodable { var message: String }
    var data: Value?
    var errors: [Failure]?
}

@MainActor
final class AniListSyncManager: ObservableObject {
    @Published private(set) var account: AniListAccount?
    @Published private(set) var isSyncing = false
    @Published private(set) var status = "Not connected"
    @Published var clientID: String {
        didSet { defaults.set(clientID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.clientIDKey) }
    }

    private(set) var isApplyingRemote = false
    private let client: AniListClient
    private let defaults: UserDefaults
    private let authenticator = AniListAuthenticator()
    private var mappings: [String: Int]
    private var remoteProgress: [String: Int]

    private static let clientIDKey = "anilist.clientID"
    private static let accountKey = "anilist.account"
    private static let mappingsKey = "anilist.mappings"
    private static let progressKey = "anilist.remoteProgress"

    init(client: AniListClient = AniListClient(), defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        clientID = defaults.string(forKey: Self.clientIDKey) ?? ""
        account = defaults.data(forKey: Self.accountKey).flatMap { try? JSONDecoder().decode(AniListAccount.self, from: $0) }
        mappings = defaults.data(forKey: Self.mappingsKey).flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        remoteProgress = defaults.data(forKey: Self.progressKey).flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        if account != nil, AniListTokenStore.load() != nil { status = "Automatic sync is ready" }
        else { account = nil }
    }

    var isConnected: Bool { account != nil && AniListTokenStore.load() != nil }
    var callbackURL: String { "animecloud://anilist-auth" }

    func connect(library: LibraryStore, catalog: [Anime]) async throws {
        let trimmedID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Int(trimmedID) != nil else { throw AniListError.missingClientID }
        status = "Waiting for AniList approval…"
        let token = try await authenticator.authenticate(clientID: trimmedID)
        try AniListTokenStore.save(token)
        do {
            let viewer = try await client.viewer(token: token)
            setAccount(viewer)
            try await synchronize(library: library, catalog: catalog, uploadIfDirty: false)
        } catch {
            AniListTokenStore.delete()
            setAccount(nil)
            throw error
        }
    }

    func disconnect() {
        AniListTokenStore.delete()
        setAccount(nil)
        status = "Not connected"
    }

    func markDirty() {
        guard let account else { return }
        defaults.set(true, forKey: dirtyKey(account.id))
        status = "Waiting to sync changes"
    }

    func noteSyncFailure(_ error: Error) {
        status = error is CancellationError
            ? "Sync cancelled"
            : "Sync paused • will retry automatically"
    }

    func synchronize(library: LibraryStore, catalog: [Anime], uploadIfDirty: Bool) async throws {
        guard let token = AniListTokenStore.load(), !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        status = "Downloading AniList library…"
        let viewer = try await client.viewer(token: token)
        setAccount(viewer)
        let entries = try await client.mediaList(userID: viewer.id, token: token)
        let candidates = deduplicated(catalog + library.favorites + library.recentAnime)
        linkExactMatches(entries: entries, candidates: candidates)

        isApplyingRemote = true
        let imported = entries.compactMap { entry -> (Anime, LibraryCategory)? in
            guard let category = entry.status?.libraryCategory,
                  let animeID = mappings.first(where: { $0.value == entry.mediaId })?.key,
                  let anime = candidates.first(where: { $0.id == animeID }) else { return nil }
            if let progress = entry.progress { remoteProgress[animeID] = max(remoteProgress[animeID] ?? 0, progress) }
            return (anime, category)
        }
        library.mergeAniListCategories(imported)
        isApplyingRemote = false
        persistMappings()

        let baseline = baselineKey(viewer.id)
        guard defaults.bool(forKey: baseline) else {
            defaults.set(true, forKey: baseline)
            defaults.set(false, forKey: dirtyKey(viewer.id))
            status = "AniList restored • uploads begin after your next change"
            return
        }

        guard uploadIfDirty, defaults.bool(forKey: dirtyKey(viewer.id)) else {
            status = "Synced just now"
            return
        }

        status = "Uploading Anime Cloud progress…"
        let known = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let animeIDs = Set(library.libraryCategories.keys).union(library.watchedAnimeIDs)
        for animeID in animeIDs.sorted() {
            guard let anime = known[animeID] else { continue }
            let progress = library.highestWatchedEpisode(forAnimeID: animeID)
            let category = library.category(for: anime)
            guard let status = category?.aniListStatus ?? (progress == nil ? nil : .current) else { continue }
            guard let mediaID = try await mediaID(for: anime, token: token) else { continue }
            try await client.save(mediaID: mediaID, status: status, progress: progress, token: token)
        }
        defaults.set(false, forKey: dirtyKey(viewer.id))
        status = "Synced just now"
        persistMappings()
    }

    func applyRemoteProgress(to anime: Anime, episodes: [Episode], library: LibraryStore) {
        isApplyingRemote = true
        library.mergeAniListProgress(remoteProgress[anime.id] ?? 0, anime: anime, episodes: episodes)
        isApplyingRemote = false
    }

    private func mediaID(for anime: Anime, token: String) async throws -> Int? {
        if let mapped = mappings[anime.id] { return mapped }
        let results = try await client.search(title: anime.name, token: token)
        let localTitle = Self.normalizedTitle(anime.name)
        let localYear = Int(anime.year ?? "")
        let exact = results.filter { media in
            media.title.values.contains { Self.normalizedTitle($0) == localTitle }
                && (localYear == nil || media.startDate?.year == nil || media.startDate?.year == localYear)
        }
        guard exact.count == 1, let match = exact.first else { return nil }
        mappings[anime.id] = match.id
        return match.id
    }

    private func linkExactMatches(entries: [AniListEntry], candidates: [Anime]) {
        var remoteByTitle: [String: [AniListEntry]] = [:]
        for entry in entries {
            for title in entry.media.title.values {
                remoteByTitle[Self.normalizedTitle(title), default: []].append(entry)
            }
        }
        let localTitleCounts = Dictionary(
            grouping: candidates,
            by: { "\(Self.normalizedTitle($0.name))|\(Int($0.year ?? "")?.description ?? "")" }
        ).mapValues(\.count)
        for anime in candidates where mappings[anime.id] == nil {
            let localKey = "\(Self.normalizedTitle(anime.name))|\(Int(anime.year ?? "")?.description ?? "")"
            guard localTitleCounts[localKey] == 1 else { continue }
            let matches = remoteByTitle[Self.normalizedTitle(anime.name)] ?? []
            let year = Int(anime.year ?? "")
            let compatible = matches.filter { year == nil || $0.media.startDate?.year == nil || $0.media.startDate?.year == year }
            let uniqueIDs = Set(compatible.map(\.mediaId))
            if uniqueIDs.count == 1 { mappings[anime.id] = uniqueIDs.first }
        }
    }

    nonisolated static func normalizedTitle(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            .lowercased()
    }

    private func deduplicated(_ values: [Anime]) -> [Anime] {
        Array(Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values)
    }

    private func setAccount(_ newValue: AniListAccount?) {
        account = newValue
        if let newValue { defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.accountKey) }
        else { defaults.removeObject(forKey: Self.accountKey) }
    }

    private func persistMappings() {
        defaults.set(try? JSONEncoder().encode(mappings), forKey: Self.mappingsKey)
        defaults.set(try? JSONEncoder().encode(remoteProgress), forKey: Self.progressKey)
    }

    private func baselineKey(_ userID: Int) -> String { "anilist.baseline.\(userID)" }
    private func dirtyKey(_ userID: Int) -> String { "anilist.dirty.\(userID)" }
}

@MainActor
private final class AniListAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func authenticate(clientID: String) async throws -> String {
        var components = URLComponents(string: "https://anilist.co/api/v2/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "token")
        ]
        return try await withCheckedThrowingContinuation { continuation in
            let authentication = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: "animecloud") { [weak self] url, error in
                self?.session = nil
                if let error { continuation.resume(throwing: error); return }
                guard let fragment = url?.fragment,
                      let values = URLComponents(string: "?\(fragment)")?.queryItems,
                      let token = values.first(where: { $0.name == "access_token" })?.value,
                      !token.isEmpty else {
                    continuation.resume(throwing: AniListError.missingToken)
                    return
                }
                continuation.resume(returning: token)
            }
            authentication.presentationContextProvider = self
            authentication.prefersEphemeralWebBrowserSession = false
            session = authentication
            guard authentication.start() else {
                session = nil
                continuation.resume(throwing: AniListError.couldNotStartAuthentication)
                return
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

private enum AniListTokenStore {
    private static let service = "com.animecloud.reborn.anilist"
    private static let account = "oauth-token"

    static func save(_ token: String) throws {
        delete()
        let result = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: Data(token.utf8)
        ] as CFDictionary, nil)
        guard result == errSecSuccess else { throw AniListError.keychain(result) }
    }

    static func load() -> String? {
        var item: CFTypeRef?
        let result = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &item)
        guard result == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ] as CFDictionary)
    }
}

enum AniListError: LocalizedError {
    case missingClientID
    case missingToken
    case couldNotStartAuthentication
    case invalidResponse
    case expiredSession
    case server(Int)
    case graphQL(String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingClientID: "Enter the numeric client ID from your AniList developer application."
        case .missingToken: "AniList approved the connection but did not return an access token."
        case .couldNotStartAuthentication: "The AniList sign-in window could not be opened."
        case .invalidResponse: "AniList returned an invalid response."
        case .expiredSession: "Your AniList authorization expired. Disconnect and connect again."
        case .server(let code): "AniList returned server error \(code)."
        case .graphQL(let message): "AniList: \(message)"
        case .keychain: "The AniList authorization could not be saved securely on this device."
        }
    }
}
