import Foundation

enum LegacyCommand: String, CaseIterable, Sendable {
    // Catalog
    case getGenres, getYears, getSeason, getAges, getMost
    case getByYear, getBySeason, getByGenres, getByRank
    case getByContinue, getByFinished, getAllAnime, getByAge, getAllMovies
    case getFavorite, getRelatedAnime, getAnimeWithDays, getNewEpAndAnime
    case getAnimeDetails, getAnimeMoreDetails, getVideoURL
    case getNews, getNewsDetails, updateNewsCount
    case updateAnimeVisiterCount, updateAppVisiterCount, saveUsersToken

    // Account and community
    case userLogin, userSignup, activateUserAccount, recoverPassword
    case changeUsername, changeUserPassword, getSubscribeDays
    case validateRecipte, getAnimeComments, getComments, getCommentsRuls
    case addComment, updateComment, deleteComment, reportComment
    case addlike, addDisLike, uploadProfilePicture, saveBackup

    var gateway: Gateway {
        switch self {
        case .userLogin, .userSignup, .activateUserAccount, .recoverPassword,
             .changeUsername, .changeUserPassword, .getSubscribeDays,
             .validateRecipte, .getAnimeComments, .getComments, .getCommentsRuls,
             .addComment, .updateComment, .deleteComment, .reportComment,
             .addlike, .addDisLike, .uploadProfilePicture, .saveBackup:
            return .account
        default:
            return .catalog
        }
    }
}

enum Gateway: Sendable {
    case catalog, account

    var url: URL {
        switch self {
        case .catalog: URL(string: "https://khkhkhkh.com/animecp/animeapi65/")!
        case .account: URL(string: "https://animecloudapp.com/aanimeApp65/")!
        }
    }
}

enum APIError: LocalizedError {
    case badResponse
    case server(Int)
    case decoding(Error)
    case message(String)
    case emptyPlayback

    var errorDescription: String? {
        switch self {
        case .badResponse: "The server returned an invalid response."
        case .server(let code): "The server returned HTTP \(code)."
        case .decoding: "Anime Cloud returned data in an unexpected format."
        case .message(let text): text
        case .emptyPlayback: "No playable source is available for this episode."
        }
    }
}

actor LegacyAPI {
    static let live = LegacyAPI()

    private let session: URLSession
    private let decoder: JSONDecoder
    private let playbackDecryptor = RNCryptorPlaybackDecryptor(password: "anime5w&f4H&434*")

    init(session: URLSession = .shared) {
        self.session = session
        self.decoder = JSONDecoder()
    }

    func catalog(_ command: LegacyCommand, fields: [String: String] = [:]) async throws -> [Anime] {
        try await decode(APIEnvelope<[Anime]>.self, command: command, fields: fields).result
    }

    func namedValues(_ command: LegacyCommand) async throws -> [NamedValue] {
        try await decode(APIEnvelope<[NamedValue]>.self, command: command).result
    }

    func animeDetail(id: String) async throws -> AnimeDetail {
        async let primary = decode(DetailEnvelope.self, command: .getAnimeDetails, fields: ["animeID": id])
        async let more = decode(APIEnvelope<[AnimeMoreDetails]>.self, command: .getAnimeMoreDetails, fields: ["animeID": id])
        let (detail, extra) = try await (primary, more)
        return AnimeDetail(
            summary: detail.mainResult?.first,
            more: extra.result.first,
            episodes: detail.result,
            settings: detail.SettingsResult
        )
    }

    func news() async throws -> [NewsItem] {
        try await decode(APIEnvelope<[NewsItem]>.self, command: .getNews).result
    }

    func comments(animeID: String, offset: Int = 0, order: String = "0") async throws -> [AnimeComment] {
        try await decode(
            APIEnvelope<[AnimeComment]>.self,
            command: .getAnimeComments,
            fields: ["animeID": animeID, "offset": String(offset), "orderBy": order]
        ).result
    }

    func episodeComments(epID: String, offset: Int = 0, order: String = "0") async throws -> [AnimeComment] {
        try await decode(
            APIEnvelope<[AnimeComment]>.self,
            command: .getComments,
            fields: ["epID": epID, "offset": String(offset), "orderBy": order]
        ).result
    }

    func login(email: String, password: String) async throws -> UserSession {
        let data = try await request(.userLogin, fields: ["email": email, "password": password])
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = object["result"] as? [[String: Any]],
            let row = rows.first(where: { string($0["userid"]) != nil || string($0["id"]) != nil })
        else { throw APIError.badResponse }

        let status = rows.compactMap { string($0["status"]) }.first
        if let status, !["Done", "true", "1", "YES"].contains(status) {
            let message = rows.compactMap { string($0["message"]) }.first
            throw APIError.message(message ?? "Login was not accepted.")
        }
        guard let userID = string(row["userid"]) ?? string(row["id"]),
              let uniqID = string(row["uniqid"]) else {
            throw APIError.message("The login response did not contain an account identifier.")
        }
        return UserSession(
            userID: userID,
            uniqID: uniqID,
            username: string(row["username"]) ?? email,
            email: string(row["email"]) ?? email,
            profilePicture: string(row["profilePicture"]),
            subscribe: string(row["subscribe"])
        )
    }

    func playback(epID: String, quality: String) async throws -> PlaybackSource {
        let data = try await request(.getVideoURL, fields: ["epID": epID, "quality": quality])
        guard !data.isEmpty else { throw APIError.emptyPlayback }

        if let direct = try? decoder.decode(PlaybackEnvelope.self, from: data),
           let first = direct.result.first,
           let url = URL(string: first.url) {
            return PlaybackSource(url: url, note: first.note)
        }

        let decrypted = try playbackDecryptor.decryptServerPayload(data)
        let payload = try decoder.decode(PlaybackEnvelope.self, from: decrypted)
        guard let first = payload.result.first, let url = URL(string: first.url) else {
            throw APIError.emptyPlayback
        }
        return PlaybackSource(url: url, note: first.note)
    }

    func perform(_ command: LegacyCommand, fields: [String: String] = [:]) async throws {
        _ = try await request(command, fields: fields)
    }

    func signup(username: String, email: String, password: String, token: String = "") async throws {
        try await perform(.userSignup, fields: ["username": username, "email": email, "password": password, "token": token])
    }

    func recoverPassword(email: String) async throws {
        try await perform(.recoverPassword, fields: ["email": email])
    }

    func postComment(anime: Anime, episode: Episode, content: String, user: UserSession) async throws {
        try await perform(.addComment, fields: [
            "epID": episode.id, "userID": user.userID, "uniqID": user.uniqID,
            "content": content, "animeName": anime.name, "epName": episode.name
        ])
    }

    func react(to commentID: String, like: Bool, user: UserSession) async throws {
        try await perform(like ? .addlike : .addDisLike, fields: [
            "commentID": commentID, "userID": user.userID, "uniqID": user.uniqID
        ])
    }

    func uploadProfile(data: Data, user: UserSession) async throws {
        try await multipart(
            command: .uploadProfilePicture,
            fields: ["uid": user.userID, "uniqID": user.uniqID],
            file: ("file", "temp.jpeg", "image/jpeg", data)
        )
    }

    func uploadBackup(data: Data, user: UserSession) async throws {
        try await multipart(
            command: .saveBackup,
            fields: ["uid": user.userID, "uniqID": user.uniqID],
            file: ("fileToUpload", "animeDB.sqlite", "application/octet-stream", data)
        )
    }

    func downloadBackup(user: UserSession) async throws -> Data {
        let url = URL(string: "https://animecloudapp.com/usersBackup/\(user.userID)-\(user.uniqID).sqlite")!
        let (data, response) = try await session.data(from: url)
        try validate(response)
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, command: LegacyCommand, fields: [String: String] = [:]) async throws -> T {
        let data = try await request(command, fields: fields)
        do { return try decoder.decode(type, from: data) }
        catch { throw APIError.decoding(error) }
    }

    private func request(_ command: LegacyCommand, fields: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: command.gateway.url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("AnimeCloud/1.0 iOS", forHTTPHeaderField: "User-Agent")
        var body = fields
        body["command"] = command.rawValue
        request.httpBody = formEncode(body).data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return data
    }

    private func multipart(
        command: LegacyCommand,
        fields: [String: String],
        file: (field: String, name: String, mime: String, data: Data)
    ) async throws {
        let boundary = "AnimeCloud-\(UUID().uuidString)"
        var body = Data()
        var allFields = fields
        allFields["command"] = command.rawValue
        for (key, value) in allFields {
            body.appendUTF8("--\(boundary)\r\n")
            body.appendUTF8("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
        }
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"\(file.field)\"; filename=\"\(file.name)\"\r\n")
        body.appendUTF8("Content-Type: \(file.mime)\r\n\r\n")
        body.append(file.data)
        body.appendUTF8("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: command.gateway.url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    private func formEncode(_ values: [String: String]) -> String {
        var components = URLComponents()
        components.queryItems = values.sorted { $0.key < $1.key }.map(URLQueryItem.init)
        return components.percentEncodedQuery ?? ""
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        guard 200..<300 ~= http.statusCode else { throw APIError.server(http.statusCode) }
    }

    private func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
}

private struct PlaybackEnvelope: Decodable {
    struct Item: Decodable { var url: String; var note: String? }
    var result: [Item]
}

private extension Data {
    mutating func appendUTF8(_ string: String) { append(Data(string.utf8)) }
}
