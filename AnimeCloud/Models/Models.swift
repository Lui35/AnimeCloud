import Foundation

enum LibraryCategory: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case favorites = "0"
    case watched = "1"
    case watchLater = "2"
    case watchingNow = "3"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .favorites: "Favorites"
        case .watched: "Watched"
        case .watchLater: "Watch Later"
        case .watchingNow: "Watching Now"
        }
    }

    var icon: String {
        switch self {
        case .favorites: "heart.fill"
        case .watched: "checkmark.circle.fill"
        case .watchLater: "clock.fill"
        case .watchingNow: "play.circle.fill"
        }
    }
}

struct Anime: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var image: String?
    var status: String?
    var year: String?
    var keywords: String?
    var day: String?
    var latestEpisodeName: String?

    var imageURL: URL? { image.flatMap(URL.init(string:)) }
    var subtitle: String { [year, status].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • ") }

    enum CodingKeys: String, CodingKey {
        case id, name, image, status, year, keywords, day
        case latestEpisodeName = "epName"
    }

    init(id: String, name: String, image: String? = nil, status: String? = nil, year: String? = nil, keywords: String? = nil, day: String? = nil, latestEpisodeName: String? = nil) {
        self.id = id
        self.name = name
        self.image = image
        self.status = status
        self.year = year
        self.keywords = keywords
        self.day = day
        self.latestEpisodeName = latestEpisodeName
    }
}

struct NamedValue: Codable, Hashable, Sendable { let name: String }

struct Episode: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var image170: String?
    var image300: String?
    var filer: String?
    var enableComment: String?

    var imageURL: URL? { (image300 ?? image170).flatMap(URL.init(string:)) }

    var isFiller: Bool {
        let value = (filer ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if value.isEmpty || ["0", "false", "no", "canon", "canonical"].contains(value) {
            return false
        }
        return value == "1" || value == "true" || value == "yes"
            || value.contains("filler") || value.contains("فلر")
    }

    var episodeTypeLabel: String { isFiller ? "Filler" : "Canon" }

    /// AniList stores aggregate progress rather than individual episode IDs.
    /// Legacy episode titles include the episode number in Arabic or Latin digits.
    var episodeNumber: Int? {
        let latinDigits = name.unicodeScalars.map { scalar -> Character in
            if let value = scalar.properties.numericValue,
               value.rounded() == value,
               (0...9).contains(value) {
                return Character(String(Int(value)))
            }
            return Character(String(scalar))
        }
        let groups = String(latinDigits).split { !$0.isNumber }
        return groups.compactMap { Int($0) }.last
    }
}

struct EpisodeWatchRecord: Codable, Hashable, Sendable {
    var animeID: String
    var episodeNumber: Int
}

extension Array where Element == Episode {
    /// Detail responses are ordered newest-first, so the next chronological
    /// episode is the item immediately before the current one.
    func nextEpisode(after episode: Episode) -> Episode? {
        guard let index = firstIndex(where: { $0.id == episode.id }), index > startIndex else { return nil }
        return self[index - 1]
    }
}

struct AnimeSummary: Codable, Hashable, Sendable {
    var age: String?
    var rank: String?
    var relatedID: String?
}

struct AnimeMoreDetails: Codable, Hashable, Sendable {
    var story: String?
    var genres: String?
}

struct RemoteSettings: Codable, Hashable, Sendable {
    var version: String?
    var EnablePurchase: String?
    var EnableDownload: String?
    var HidePlayButton: String?
    var AdType: String?
    var mm: String?
    var showPurchaseButtonForRigserUserOnly: String?
}

struct AnimeDetail: Hashable, Sendable {
    var summary: AnimeSummary?
    var more: AnimeMoreDetails?
    var episodes: [Episode]
    var settings: RemoteSettings?
}

struct NewsItem: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var image: String?
    var content: String?
    var count: String?
    var sh: String?
    var url: String?

    var imageURL: URL? { image.flatMap(URL.init(string:)) }
}

struct AnimeComment: Codable, Identifiable, Hashable, Sendable {
    var id: String { commentID ?? UUID().uuidString }
    var commentID: String?
    var content: String?
    var username: String?
    var userImage: String?
    var time: String?
    var likes: String?
    var dislikes: String?
    var userID: String?
}

struct UserSession: Codable, Hashable, Sendable {
    var userID: String
    var uniqID: String
    var username: String
    var email: String
    var profilePicture: String?
    var subscribe: String?
}

struct PlaybackSource: Hashable, Sendable {
    var url: URL
    var note: String?
}

struct APIEnvelope<T: Decodable>: Decodable { let result: T }

struct DetailEnvelope: Decodable {
    var mainResult: [AnimeSummary]?
    var result: [Episode]
    var SettingsResult: RemoteSettings?
}

struct NewContentEnvelope: Decodable {
    var result2: [Anime]?
}
