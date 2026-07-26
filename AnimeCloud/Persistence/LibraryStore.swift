import Foundation
import SQLite3

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var favorites: [Anime] = []
    @Published private(set) var libraryCategories: [String: LibraryCategory] = [:]
    @Published private(set) var seenEpisodeIDs: Set<String> = []
    @Published private(set) var recentAnime: [Anime] = []

    var onChange: (() -> Void)?

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var favoriteTombstones: Set<String> = []
    private var seenTombstones: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favorites = decode([Anime].self, key: "library.favorites") ?? []
        libraryCategories = decode([String: LibraryCategory].self, key: "library.categories") ?? [:]
        if libraryCategories.isEmpty, !favorites.isEmpty {
            libraryCategories = Dictionary(uniqueKeysWithValues: favorites.map { ($0.id, .favorites) })
        }
        seenEpisodeIDs = Set(decode([String].self, key: "library.seen") ?? [])
        recentAnime = decode([Anime].self, key: "library.recent") ?? []
        favoriteTombstones = Set(decode([String].self, key: "library.favoriteTombstones") ?? [])
        seenTombstones = Set(decode([String].self, key: "library.seenTombstones") ?? [])
    }

    func isFavorite(_ anime: Anime) -> Bool { category(for: anime) == .favorites }
    func isSaved(_ anime: Anime) -> Bool { category(for: anime) != nil }
    func category(for anime: Anime) -> LibraryCategory? { libraryCategories[anime.id] }
    func isSeen(_ episode: Episode) -> Bool { seenEpisodeIDs.contains(episode.id) }

    func toggleFavorite(_ anime: Anime) {
        setCategory(isFavorite(anime) ? nil : .favorites, for: anime)
    }

    func setCategory(_ category: LibraryCategory?, for anime: Anime) {
        favorites.removeAll { $0.id == anime.id }
        if let category {
            favorites.insert(anime, at: 0)
            libraryCategories[anime.id] = category
            favoriteTombstones.remove(anime.id)
        } else {
            libraryCategories.removeValue(forKey: anime.id)
            favoriteTombstones.insert(anime.id)
        }
        persistAndNotify()
    }

    func toggleSeen(_ episode: Episode) {
        if seenEpisodeIDs.contains(episode.id) {
            seenEpisodeIDs.remove(episode.id)
            seenTombstones.insert(episode.id)
        } else {
            seenEpisodeIDs.insert(episode.id)
            seenTombstones.remove(episode.id)
        }
        persistAndNotify()
    }

    func markSeen(_ episode: Episode) {
        guard !seenEpisodeIDs.contains(episode.id) else { return }
        seenEpisodeIDs.insert(episode.id)
        seenTombstones.remove(episode.id)
        persistAndNotify()
    }

    func recordOpened(_ anime: Anime) {
        recentAnime.removeAll { $0.id == anime.id }
        recentAnime.insert(anime, at: 0)
        recentAnime = Array(recentAnime.prefix(12))
        persistAndNotify()
    }

    var hasContent: Bool {
        !favorites.isEmpty || !seenEpisodeIDs.isEmpty || !recentAnime.isEmpty
    }

    func mergeBackup(_ data: Data, catalog: [Anime]) throws {
        guard data.starts(with: Data("SQLite format 3\0".utf8)) else {
            throw BackupError.invalidDatabase
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("animecloud-restore-\(UUID().uuidString).sqlite")
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            throw BackupError.invalidDatabase
        }
        defer { sqlite3_close(database) }

        let remoteFavorites = try favoriteRows(database: database)
            .filter { !favoriteTombstones.contains($0.id) }
        let remoteSeen = try values(query: "SELECT epID FROM Seen", database: database)
            .filter { !seenTombstones.contains($0) }
        let remoteRecent = try values(query: "SELECT animeID FROM lastSeenArray", database: database)

        let knownAnime = Dictionary(
            (favorites + recentAnime + catalog).map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        favorites = mergeAnimeIDs(remoteFavorites.map(\.id), into: favorites, knownAnime: knownAnime)
        for remote in remoteFavorites where libraryCategories[remote.id] == nil {
            libraryCategories[remote.id] = remote.category
        }
        recentAnime = Array(mergeAnimeIDs(remoteRecent, into: recentAnime, knownAnime: knownAnime).prefix(12))
        seenEpisodeIDs.formUnion(remoteSeen)
        persist()
    }

    func hydrate(with catalog: [Anime]) {
        let known = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        favorites = favorites.map { known[$0.id] ?? $0 }
        recentAnime = recentAnime.map { known[$0.id] ?? $0 }
        persist()
    }

    func didUploadSuccessfully() {
        favoriteTombstones.removeAll()
        seenTombstones.removeAll()
        persist()
    }

    func backupData() throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("animecloud-\(UUID().uuidString).sqlite")
        var database: OpaquePointer?

        guard sqlite3_open(url.path, &database) == SQLITE_OK, let handle = database else {
            throw BackupError.couldNotCreateDatabase
        }
        defer {
            if let database { sqlite3_close(database) }
            try? FileManager.default.removeItem(at: url)
        }

        let schema = """
        CREATE TABLE Favor (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, animeID VARCHAR NOT NULL, favType VARCHAR NOT NULL DEFAULT '0');
        CREATE TABLE Seen (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, epID VARCHAR NOT NULL, animeID VARCHAR NOT NULL DEFAULT '');
        CREATE TABLE lastSeenArray (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, animeID VARCHAR NOT NULL);
        """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
            throw BackupError.couldNotWriteDatabase
        }

        try insertFavorites(favorites, database: handle)
        try insert(Array(seenEpisodeIDs), into: "Seen", column: "epID", database: handle)
        try insert(recentAnime.map(\.id), into: "lastSeenArray", column: "animeID", database: handle)

        guard sqlite3_close(handle) == SQLITE_OK else {
            throw BackupError.couldNotWriteDatabase
        }
        database = nil
        return try Data(contentsOf: url)
    }

    private func insert(_ values: [String], into table: String, column: String, database: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO \(table) (\(column)) VALUES (?)", -1, &statement, nil) == SQLITE_OK else {
            throw BackupError.couldNotWriteDatabase
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        for value in values {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            let bindResult = value.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
            guard bindResult == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
                throw BackupError.couldNotWriteDatabase
            }
        }
    }

    private func insertFavorites(_ anime: [Anime], database: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO Favor (animeID, favType) VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK else {
            throw BackupError.couldNotWriteDatabase
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        for item in anime {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            let category = libraryCategories[item.id] ?? .favorites
            let animeResult = item.id.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
            let typeResult = category.rawValue.withCString { sqlite3_bind_text(statement, 2, $0, -1, transient) }
            guard animeResult == SQLITE_OK, typeResult == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
                throw BackupError.couldNotWriteDatabase
            }
        }
    }

    private func favoriteRows(database: OpaquePointer) throws -> [(id: String, category: LibraryCategory)] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT animeID, favType FROM Favor", -1, &statement, nil) == SQLITE_OK else {
            throw BackupError.invalidDatabase
        }
        defer { sqlite3_finalize(statement) }

        var result: [(String, LibraryCategory)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: idText)
            let rawType = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "0"
            result.append((id, LibraryCategory(rawValue: rawType) ?? .favorites))
        }
        return result
    }

    private func values(query: String, database: OpaquePointer) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            throw BackupError.invalidDatabase
        }
        defer { sqlite3_finalize(statement) }

        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                result.append(String(cString: text))
            }
        }
        return result
    }

    private func mergeAnimeIDs(_ remoteIDs: [String], into local: [Anime], knownAnime: [String: Anime]) -> [Anime] {
        var result = local
        var existing = Set(local.map(\.id))
        for id in remoteIDs where !existing.contains(id) {
            result.append(knownAnime[id] ?? Anime(id: id, name: "Anime #\(id)"))
            existing.insert(id)
        }
        return result
    }

    private func persistAndNotify() {
        persist()
        onChange?()
    }

    private func persist() {
        defaults.set(try? encoder.encode(favorites), forKey: "library.favorites")
        defaults.set(try? encoder.encode(libraryCategories), forKey: "library.categories")
        defaults.set(try? encoder.encode(Array(seenEpisodeIDs)), forKey: "library.seen")
        defaults.set(try? encoder.encode(recentAnime), forKey: "library.recent")
        defaults.set(try? encoder.encode(Array(favoriteTombstones)), forKey: "library.favoriteTombstones")
        defaults.set(try? encoder.encode(Array(seenTombstones)), forKey: "library.seenTombstones")
    }

    private func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? decoder.decode(type, from: $0) }
    }
}

private enum BackupError: LocalizedError {
    case couldNotCreateDatabase
    case couldNotWriteDatabase
    case invalidDatabase

    var errorDescription: String? {
        switch self {
        case .couldNotCreateDatabase: "Anime Cloud could not create a local sync database."
        case .couldNotWriteDatabase: "Anime Cloud could not write the sync database."
        case .invalidDatabase: "The cloud backup is not a valid Anime Cloud database."
        }
    }
}
