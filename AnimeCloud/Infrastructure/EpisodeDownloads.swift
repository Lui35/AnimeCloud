import AVFoundation
import Foundation
import CryptoKit

struct EpisodeDownload: Codable, Identifiable {
    enum Status: String, Codable {
        case preparing, downloading, ready, failed
    }

    var id: String { episode.id }
    let anime: Anime
    let episode: Episode
    let catalogPosition: Int
    let finalCanonEpisode: Episode?
    var transferID = UUID()
    var status: Status = .preparing
    var relativePath: String?
    var isHLS = false
    var failure: String?
}

@MainActor
final class EpisodeDownloads: NSObject, ObservableObject {
    @Published private(set) var records: [String: EpisodeDownload] = [:]
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var availableArtwork: Set<String> = []

    private let api: LegacyAPI
    private let defaults: UserDefaults
    private let directory: URL
    private var preparation: [String: Task<Void, Never>] = [:]
    private var observations: [UUID: NSKeyValueObservation] = [:]
    private var validating: Set<UUID> = []
    private var artworkTasks: [String: Task<Void, Never>] = [:]
    private var backgroundHandlers: [String: () -> Void] = [:]

    private static let fileSessionID = "com.animecloud.episode-files"
    private static let hlsSessionID = "com.animecloud.episode-hls"

    private lazy var files = URLSession(
        configuration: .background(withIdentifier: Self.fileSessionID),
        delegate: self,
        delegateQueue: .main
    )
    private lazy var foregroundFiles = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    private lazy var streams = AVAssetDownloadURLSession(
        configuration: .background(withIdentifier: Self.hlsSessionID),
        assetDownloadDelegate: self,
        delegateQueue: .main
    )

    init(api: LegacyAPI, defaults: UserDefaults, directory: URL = .applicationSupportDirectory.appending(path: "EpisodeDownloads")) {
        self.api = api
        self.defaults = defaults
        self.directory = directory
        super.init()
        if let data = defaults.data(forKey: "downloads.episodes"),
           let saved = try? JSONDecoder().decode([String: EpisodeDownload].self, from: data) {
            records = saved
            availableArtwork = Set(saved.values.map(\.anime.id).filter {
                FileManager.default.fileExists(atPath: artworkFile(for: $0).path)
            })
        }
    }

    func restoreTransfers() async {
        let saved = Array(records.values)
        async let fileTasks = files.allTasks
        async let streamTasks = streams.allTasks
        async let foregroundTasks = foregroundFiles.allTasks
        let tasks = await fileTasks + streamTasks + foregroundTasks
        for record in saved {
            guard let current = records[record.id],
                  current.transferID == record.transferID,
                  current.status == record.status else { continue }
            switch current.status {
            case .preparing:
                if preparation[current.id] == nil { start(current) }
            case .downloading:
                if let task = tasks.first(where: { $0.taskDescription == current.transferID.uuidString }) {
                    observe(task, for: current)
                    if task.state == .suspended { task.resume() }
                } else if current.relativePath != nil {
                    validate(current)
                } else {
                    fail(current, with: DownloadError.interrupted)
                }
            case .ready:
                if localURL(for: current.id) == nil { fail(current, with: DownloadError.missing) }
            case .failed:
                break
            }
        }
    }

    func enqueue(anime: Anime, catalog: [Episode], selected: Set<String>) {
        let finalCanonEpisode = catalog.first { !$0.isFiller }
        for (position, episode) in catalog.enumerated() where selected.contains(episode.id) {
            if let existing = records[episode.id] {
                if existing.status == .failed { retry(existing.id) }
                continue
            }
            start(EpisodeDownload(anime: anime, episode: episode, catalogPosition: position, finalCanonEpisode: finalCanonEpisode))
        }
    }

    func retry(_ episodeID: String) {
        guard var record = records[episodeID],
              record.status == .failed || (record.status == .ready && localURL(for: episodeID) == nil) else { return }
        record.transferID = UUID()
        record.relativePath = nil
        record.isHLS = false
        start(record)
    }

    func remove(_ episodeID: String) throws {
        guard let record = records[episodeID] else { return }
        try deleteMedia(for: record)
        records[episodeID] = nil
        persist()
        preparation.removeValue(forKey: episodeID)?.cancel()
        observations[record.transferID] = nil
        progress[episodeID] = nil
        if record.status == .downloading {
            Task {
                let tasks = record.isHLS ? await streams.allTasks : await files.allTasks + foregroundFiles.allTasks
                for task in tasks where task.taskDescription == record.transferID.uuidString { task.cancel() }
            }
        }
        if !records.values.contains(where: { $0.anime.id == record.anime.id }) {
            artworkTasks.removeValue(forKey: record.anime.id)?.cancel()
            try? FileManager.default.removeItem(at: artworkFile(for: record.anime.id))
            availableArtwork.remove(record.anime.id)
        }
    }

    func removeAll(forAnimeID animeID: String) throws {
        let episodeIDs = records.values.filter { $0.anime.id == animeID }.map(\.id)
        var firstError: Error?
        for episodeID in episodeIDs {
            do {
                try remove(episodeID)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    func localURL(for episodeID: String) -> URL? {
        guard let record = records[episodeID], record.status == .ready,
              let url = mediaURL(for: record), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func artworkURL(for animeID: String) -> URL? {
        availableArtwork.contains(animeID) ? artworkFile(for: animeID) : nil
    }

    func handleBackgroundEvents(identifier: String, completion: @escaping () -> Void) {
        switch identifier {
        case Self.fileSessionID:
            backgroundHandlers[identifier] = completion
            _ = files
        case Self.hlsSessionID:
            backgroundHandlers[identifier] = completion
            _ = streams
        default:
            completion()
        }
    }

    private func start(_ original: EpisodeDownload) {
        var pending = original
        pending.status = .preparing
        pending.failure = nil
        let record = pending
        save(record)
        saveArtwork(for: record.anime)
        preparation[record.id] = Task {
            defer {
                if records[record.id]?.transferID == record.transferID { preparation[record.id] = nil }
            }
            do {
                try prepareDirectory()
                let source = try await api.playback(epID: record.id, quality: "1")
                let (url, isHLS) = await Self.downloadSource(source.url)
                let configuration: AVAssetDownloadConfiguration?
                if isHLS {
                    let asset = AVURLAsset(url: url)
                    let (duration, isPlayable, isProtected) = try await asset.load(.duration, .isPlayable, .hasProtectedContent)
                    guard duration.isNumeric, duration.seconds > 0, isPlayable, !isProtected else {
                        throw DownloadError.unsupported
                    }
                    configuration = AVAssetDownloadConfiguration(asset: asset, title: record.episode.name)
                } else {
                    configuration = nil
                }
                try Task.checkCancellation()
                guard records[record.id]?.transferID == record.transferID else { return }

                let task: URLSessionTask
                if let configuration {
                    task = streams.makeAssetDownloadTask(downloadConfiguration: configuration)
                } else {
                    task = files.downloadTask(with: url)
                }
                var downloading = record
                downloading.status = .downloading
                downloading.isHLS = isHLS
                task.taskDescription = record.transferID.uuidString
                save(downloading)
                observe(task, for: downloading)
                task.resume()
            } catch {
                guard !Task.isCancelled else { return }
                fail(record, with: error)
            }
        }
    }

    private static func downloadSource(_ url: URL) async -> (URL, Bool) {
        if url.pathExtension.lowercased() == "m3u8" { return (url, true) }
        if ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased()) { return (url, false) }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { return (url, false) }
        let resolvedURL = response.url ?? url
        return (resolvedURL, resolvedURL.pathExtension.lowercased() == "m3u8" || response.mimeType?.contains("mpegurl") == true)
    }

    private func observe(_ task: URLSessionTask, for record: EpisodeDownload) {
        observations[record.transferID] = task.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] value, _ in
            let fraction = value.fractionCompleted
            Task { @MainActor in
                guard let self, self.records[record.id]?.transferID == record.transferID,
                      self.records[record.id]?.status == .downloading else { return }
                self.progress[record.id] = fraction
            }
        }
    }

    private func validate(_ record: EpisodeDownload) {
        guard validating.insert(record.transferID).inserted else { return }
        Task {
            defer { validating.remove(record.transferID) }
            do {
                guard let url = mediaURL(for: record), FileManager.default.fileExists(atPath: url.path) else { throw DownloadError.missing }
                let asset = AVURLAsset(url: url)
                guard try await asset.load(.isPlayable), !record.isHLS || asset.assetCache?.isPlayableOffline == true else {
                    throw DownloadError.unsupported
                }
                guard records[record.id]?.transferID == record.transferID,
                      records[record.id]?.status == .downloading else { return }
                var ready = record
                ready.status = .ready
                save(ready)
                progress[record.id] = nil
            } catch {
                fail(record, with: error)
            }
        }
    }

    private func fail(_ record: EpisodeDownload, with error: Error) {
        guard var failed = records[record.id], failed.transferID == record.transferID else { return }
        try? deleteMedia(for: failed)
        failed.status = .failed
        failed.relativePath = nil
        failed.failure = error.localizedDescription
        progress[record.id] = nil
        save(failed)
    }

    private func mediaURL(for record: EpisodeDownload) -> URL? {
        guard let path = record.relativePath else { return nil }
        return (record.isHLS ? .homeDirectory : directory).appending(path: path)
    }

    private func deleteMedia(for record: EpisodeDownload) throws {
        if let url = mediaURL(for: record), FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try url.setResourceValues(resources)
    }

    private func artworkFile(for animeID: String) -> URL {
        let hash = SHA256.hash(data: Data(animeID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: hash + ".jpg")
    }

    private func saveArtwork(for anime: Anime) {
        guard let url = anime.imageURL, artworkTasks[anime.id] == nil, !availableArtwork.contains(anime.id) else { return }
        artworkTasks[anime.id] = Task {
            defer { if !Task.isCancelled { artworkTasks[anime.id] = nil } }
            guard let image = try? await ArtworkPipeline.shared.image(for: url, size: CGSize(width: 120, height: 180), scale: 2),
                  let data = image.jpegData(compressionQuality: 0.85), !Task.isCancelled else { return }
            do {
                try prepareDirectory()
                try data.write(to: artworkFile(for: anime.id), options: .atomic)
                availableArtwork.insert(anime.id)
            } catch {
                // A missing poster does not affect the video download.
            }
        }
    }

    private func save(_ record: EpisodeDownload) {
        records[record.id] = record
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(records), forKey: "downloads.episodes")
    }

    private func record(for task: URLSessionTask) -> EpisodeDownload? {
        records.values.first { $0.transferID.uuidString == task.taskDescription && $0.status == .downloading }
    }
}

// Both background sessions deliver delegate callbacks on OperationQueue.main.
extension EpisodeDownloads: URLSessionDownloadDelegate, AVAssetDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        MainActor.assumeIsolated {
            guard var record = record(for: downloadTask) else { return }
            do {
                guard let response = downloadTask.response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode),
                      response.mimeType?.contains("mpegurl") != true else { throw DownloadError.unsupported }
                let ext = response.url?.pathExtension.lowercased() ?? ""
                let fileExtension = ["mp4", "mov", "m4v"].contains(ext) ? ext : "mp4"
                let path = record.transferID.uuidString + "." + fileExtension
                try prepareDirectory()
                record.relativePath = path
                save(record)
                try FileManager.default.moveItem(at: location, to: directory.appending(path: path))
            } catch {
                fail(record, with: error)
            }
        }
    }

    @available(iOS 18, *)
    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL) {
        MainActor.assumeIsolated { storeStreamLocation(location, for: assetDownloadTask) }
    }

    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        MainActor.assumeIsolated { storeStreamLocation(location, for: assetDownloadTask) }
    }

    private func storeStreamLocation(_ location: URL, for task: AVAssetDownloadTask) {
        guard var record = record(for: task) else { return }
        let home = URL.homeDirectory.resolvingSymlinksInPath().path
        let path = location.resolvingSymlinksInPath().path
        guard path.hasPrefix(home + "/") else {
            fail(record, with: DownloadError.unsupported)
            task.cancel()
            return
        }
        // AVFoundation manages this package at its original location.
        record.relativePath = String(path.dropFirst(home.count + 1))
        save(record)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            if let description = task.taskDescription, let id = UUID(uuidString: description) {
                observations[id] = nil
            }
            guard let record = record(for: task) else { return }
            if let error {
                if session.configuration.identifier == Self.fileSessionID,
                   (error as? URLError)?.code == .unknown, let request = task.originalRequest {
                    let retry = foregroundFiles.downloadTask(with: request)
                    retry.taskDescription = task.taskDescription
                    observe(retry, for: record)
                    retry.resume()
                } else {
                    fail(record, with: error)
                }
            } else {
                validate(record)
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            guard let identifier = session.configuration.identifier else { return }
            backgroundHandlers.removeValue(forKey: identifier)?()
        }
    }
}

enum DownloadError: LocalizedError {
    case interrupted, missing, unsupported

    var errorDescription: String? {
        switch self {
        case .interrupted: "The download was interrupted. Try again when you’re connected."
        case .missing: "This video is missing from the device. Download it again."
        case .unsupported: "This source couldn’t be saved for offline playback."
        }
    }
}
