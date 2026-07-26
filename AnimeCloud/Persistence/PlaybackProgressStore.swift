import Foundation

struct EpisodePlaybackProgress: Codable, Hashable, Sendable {
    var position: TimeInterval
    var duration: TimeInterval
    var updatedAt: Date

    var fraction: Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }
}

@MainActor
final class PlaybackProgressStore: ObservableObject {
    @Published private(set) var entries: [String: EpisodePlaybackProgress]

    private let defaults: UserDefaults
    private let key = "playback.episodeProgress"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: EpisodePlaybackProgress].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    func progress(for episodeID: String) -> EpisodePlaybackProgress? {
        entries[episodeID]
    }

    func save(episodeID: String, position: TimeInterval, duration: TimeInterval) {
        guard position.isFinite, duration.isFinite, position >= 3, duration > 0 else { return }
        if position / duration >= 0.95 {
            entries.removeValue(forKey: episodeID)
        } else {
            entries[episodeID] = EpisodePlaybackProgress(position: position, duration: duration, updatedAt: Date())
        }
        persist()
    }

    func clear(episodeID: String) {
        entries.removeValue(forKey: episodeID)
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(entries), forKey: key)
    }
}

enum PlaybackTimeFormatter {
    static func string(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainingSeconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds) }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}
