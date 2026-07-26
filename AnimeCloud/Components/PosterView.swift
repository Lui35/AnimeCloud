import ImageIO
import SwiftUI
import UIKit

struct PosterView: View {
    let anime: Anime
    var width: CGFloat = 142
    var height: CGFloat = 204

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            RemoteArtwork(url: anime.imageURL)
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if let year = anime.year, !year.isEmpty {
                        Text(year)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(8)
                    }
                }
            Text(anime.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .frame(width: width, alignment: .leading)
            if !anime.subtitle.isEmpty {
                Text(anime.subtitle)
                    .font(.caption)
                    .foregroundStyle(CloudTheme.muted)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct RemoteArtwork: View {
    let url: URL?
    @Environment(\.displayScale) private var displayScale
    @State private var phase: ArtworkPhase = .empty
    @State private var reloadToken = 0

    var body: some View {
        GeometryReader { proxy in
            artwork
                .task(id: requestID(for: proxy.size)) {
                    await load(size: proxy.size)
                }
        }
        .onReceive(NotificationCenter.default.publisher(for: ArtworkPipeline.didLoadImage)) { notification in
            guard phase.isFailure,
                  let loadedURL = notification.object as? URL,
                  loadedURL == url else { return }
            reloadToken += 1
        }
        .clipped()
    }

    @ViewBuilder private var artwork: some View {
        switch phase {
        case .success(let image):
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .transition(.opacity)
        case .failure:
            placeholder
                .overlay(alignment: .bottom) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(8)
                }
        case .empty:
            placeholder.overlay { ProgressView().tint(.white.opacity(0.7)) }
        }
    }

    private func requestID(for size: CGSize) -> ArtworkRequestID {
        ArtworkRequestID(
            url: url,
            width: Int((size.width * displayScale).rounded()),
            height: Int((size.height * displayScale).rounded()),
            reloadToken: reloadToken
        )
    }

    @MainActor private func load(size: CGSize) async {
        guard let url else {
            phase = .failure
            return
        }
        phase = .empty
        do {
            let image = try await ArtworkPipeline.shared.image(for: url, size: size, scale: displayScale)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { phase = .success(image) }
        } catch is CancellationError {
            // The shared download continues so another visible card can reuse it.
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failure
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [CloudTheme.panel, CloudTheme.violet.opacity(0.45)], startPoint: .top, endPoint: .bottom)
            Image(systemName: "cloud.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.25))
        }
    }
}

private enum ArtworkPhase {
    case empty
    case success(UIImage)
    case failure

    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

private struct ArtworkRequestID: Hashable {
    let url: URL?
    let width: Int
    let height: Int
    let reloadToken: Int
}

private enum ArtworkError: Error {
    case invalidResponse
    case invalidImage
}

private actor ArtworkPipeline {
    static let shared = ArtworkPipeline()
    static let didLoadImage = Notification.Name("AnimeCloud.ArtworkPipeline.didLoadImage")

    private let decodedImages = NSCache<NSString, UIImage>()
    private let responseCache: URLCache
    private let session: URLSession
    private var dataTasks: [URL: Task<Data, Error>] = [:]

    private init() {
        let cache = URLCache(
            memoryCapacity: 48 * 1_024 * 1_024,
            diskCapacity: 300 * 1_024 * 1_024,
            diskPath: "anime-cloud-artwork"
        )
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = cache
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 20
        configuration.httpMaximumConnectionsPerHost = 6
        responseCache = cache
        session = URLSession(configuration: configuration)
        decodedImages.totalCostLimit = 96 * 1_024 * 1_024
        decodedImages.countLimit = 180
    }

    func image(for url: URL, size: CGSize, scale: CGFloat) async throws -> UIImage {
        let pixelWidth = max(Int((size.width * scale).rounded(.up)), 64)
        let pixelHeight = max(Int((size.height * scale).rounded(.up)), 64)
        let maximumPixelSize = max(pixelWidth, pixelHeight)
        let key = "\(url.absoluteString)|\(pixelWidth)x\(pixelHeight)" as NSString

        if let cached = decodedImages.object(forKey: key) { return cached }

        let data = try await data(for: url)
        guard let image = Self.downsample(data: data, maximumPixelSize: maximumPixelSize) else {
            throw ArtworkError.invalidImage
        }
        decodedImages.setObject(image, forKey: key, cost: image.memoryCost)
        Task { @MainActor in
            NotificationCenter.default.post(name: Self.didLoadImage, object: url)
        }
        return image
    }

    private func data(for url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 20

        if let cached = responseCache.cachedResponse(for: request),
           UIImage(data: cached.data) != nil {
            return cached.data
        }
        if let task = dataTasks[url] { return try await task.value }

        let session = session
        let cache = responseCache
        let task = Task<Data, Error> {
            var lastError: Error = ArtworkError.invalidResponse
            for attempt in 0..<3 {
                do {
                    let (data, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else {
                        throw ArtworkError.invalidResponse
                    }
                    guard UIImage(data: data) != nil else { throw ArtworkError.invalidImage }
                    cache.storeCachedResponse(CachedURLResponse(response: response, data: data, storagePolicy: .allowed), for: request)
                    return data
                } catch {
                    lastError = error
                    guard attempt < 2 else { break }
                    try await Task.sleep(for: .milliseconds(350 * (attempt + 1)))
                }
            }
            throw lastError
        }
        dataTasks[url] = task
        defer { dataTasks[url] = nil }
        return try await task.value
    }

    private static func downsample(data: Data, maximumPixelSize: Int) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private extension UIImage {
    var memoryCost: Int {
        guard let cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}

struct SectionHeading: View {
    var title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.bold())
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(CloudTheme.muted) }
            }
            Spacer()
        }
    }
}

struct EmptyCloud: View {
    var title: String
    var detail: String
    var systemImage: String = "cloud"

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(detail))
            .foregroundStyle(.white)
    }
}
