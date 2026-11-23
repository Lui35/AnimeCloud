import AVFoundation
import GoogleCast
import SwiftUI

struct CastEpisode {
    let anime: Anime
    let episode: Episode
    let url: URL
    let duration: Double

    var id: String { "\(anime.id):\(episode.id)" }
    var isSupported: Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && !(url.host ?? "").isEmpty
    }

    func mediaInformation() -> GCKMediaInformation {
        let metadata = GCKMediaMetadata(metadataType: .tvShow)
        metadata.setString(anime.name, forKey: kGCKMetadataKeyTitle)
        metadata.setString(episode.name, forKey: kGCKMetadataKeySubtitle)
        if let image = anime.imageURL, ["https", "http"].contains(image.scheme ?? "") {
            metadata.addImage(GCKImage(url: image, width: 0, height: 0))
        }
        let builder = GCKMediaInformationBuilder(contentURL: url)
        builder.streamType = .buffered
        switch url.pathExtension.lowercased() {
        case "m3u8": builder.contentType = "application/x-mpegURL"
        case "mpd": builder.contentType = "application/dash+xml"
        case "webm": builder.contentType = "video/webm"
        default: builder.contentType = "video/mp4"
        }
        builder.streamDuration = duration.isFinite ? max(0, duration) : 0
        builder.metadata = metadata
        builder.customData = ["animeCloudEpisode": id]
        return builder.build()
    }

    func matches(_ information: GCKMediaInformation?) -> Bool {
        (information?.customData as? [String: Any])?["animeCloudEpisode"] as? String == id
    }
}

/// One session survives closing the player; its progress callback belongs to the episode on TV.
@MainActor
final class ChromecastPlayback: NSObject, ObservableObject, @preconcurrency GCKSessionManagerListener,
                                @preconcurrency GCKRemoteMediaClientListener, @preconcurrency GCKRequestDelegate {
    static let shared = ChromecastPlayback()
    @Published private(set) var isCasting = false
    @Published private(set) var isLoading = false
    @Published private(set) var isConnected = false
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var deviceName = "TV"
    @Published var errorMessage: String?
    @Published private(set) var completedEpisodeID: String?
    private weak var player: AVPlayer?
    private var episode: CastEpisode?
    private var loadRequest: GCKRequest?
    private var wasPlaying = false
    private var completed = false
    private var onProgress: ((Double, Double) -> Void)?
    private var onComplete: (() -> Void)?
    private var timer: Timer?
    private weak var observedClient: GCKRemoteMediaClient?

    var currentEpisodeID: String? { episode?.id }

    private var sessions: GCKSessionManager { GCKCastContext.sharedInstance().sessionManager }
    private var client: GCKRemoteMediaClient? { sessions.currentCastSession?.remoteMediaClient }

    private override init() {
        if !GCKCastContext.isSharedInstanceInitialized() {
            let options = GCKCastOptions(discoveryCriteria: GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID))
            options.disableAnalyticsLogging = true
            options.startDiscoveryAfterFirstTapOnCastButton = true
            GCKCastContext.setSharedInstanceWith(options)
            GCKCastContext.sharedInstance().useDefaultExpandedMediaControls = true
        }
        super.init()
        sessions.add(self)
        observeSession()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateRemoteProgress() }
        }
    }

    func attach(player: AVPlayer, episode: CastEpisode,
                onProgress: @escaping (Double, Double) -> Void, onComplete: @escaping () -> Void) {
        // Save the old TV episode before replacing its callbacks.
        updateRemoteProgress()
        if !episode.isSupported, isCasting || isLoading {
            isCasting = false
            isLoading = false
            loadRequest?.delegate = nil
            loadRequest = nil
            sessions.endSessionAndStopCasting(true)
        }
        self.player = player
        self.episode = episode
        self.onProgress = onProgress
        self.onComplete = onComplete
        completed = false
        completedEpisodeID = nil
        errorMessage = nil
        guard episode.isSupported else { return }
        if episode.matches(client?.mediaStatus?.mediaInformation), isConnected {
            isCasting = true
            player.pause()
            if let client { remoteMediaClient(client, didUpdate: client.mediaStatus) }
            updateRemoteProgress()
        } else if isConnected {
            castCurrentEpisode()
        }
    }

    func detach(player: AVPlayer) {
        guard self.player === player else { return }
        updateRemoteProgress()
        self.player = nil
        // The TV keeps playing and still records progress after this sheet closes.
    }

    func controls() { GCKCastContext.sharedInstance().presentDefaultExpandedMediaControls() }

    func stopCasting() { sessions.endSessionAndStopCasting(true) }

    func replay() {
        guard let client else { return }
        completed = false
        completedEpisodeID = nil
        let seek = GCKMediaSeekOptions()
        seek.interval = 0
        client.seek(with: seek)
        client.play()
    }

    private func observeSession() {
        let current = client
        if observedClient !== current {
            observedClient?.remove(self)
            observedClient = current
            current?.add(self)
        }
        isConnected = sessions.currentCastSession?.connectionState == .connected
        deviceName = sessions.currentCastSession?.device.friendlyName ?? "TV"
    }

    private func castCurrentEpisode() {
        guard let episode, episode.isSupported, let client, let player, isConnected else { return }
        loadRequest?.delegate = nil
        loadRequest = nil
        wasPlaying = player.timeControlStatus != .paused
        let localPosition = player.currentTime().seconds
        position = localPosition.isFinite ? max(0, localPosition) : 0
        duration = episode.duration
        completed = false
        completedEpisodeID = nil
        isCasting = false
        isLoading = true
        errorMessage = nil
        player.pause()
        let request = GCKMediaLoadRequestDataBuilder()
        request.mediaInformation = episode.mediaInformation()
        request.startTime = position
        request.autoplay = NSNumber(value: wasPlaying)
        loadRequest = client.loadMedia(with: request.build())
        loadRequest?.delegate = self
    }

    private func updateRemoteProgress() {
        guard isCasting, isConnected, !isLoading, let episode, let client,
              episode.matches(client.mediaStatus?.mediaInformation), !completed else { return }
        let time = client.approximateStreamPosition()
        let length = client.mediaStatus?.mediaInformation?.streamDuration ?? episode.duration
        guard time.isFinite, length.isFinite else { return }
        position = max(0, time)
        duration = max(0, length)
        onProgress?(position, duration)
    }

    private func resumeOnPhone() {
        guard let player else { return }
        let time = CMTime(seconds: position.isFinite ? max(0, position) : 0, preferredTimescale: 600)
        let resume = wasPlaying && !completed
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] _ in
            Task { @MainActor in
                guard let self, self.player === player, !self.isCasting, !self.isLoading else { return }
                if resume { player?.play() }
            }
        }
    }

    private func failLoad() {
        loadRequest?.delegate = nil
        loadRequest = nil
        isLoading = false
        isCasting = false
        sessions.endSessionAndStopCasting(true)
        errorMessage = "The TV couldn’t play this source. Try another episode source, or continue on your phone. Both devices must be on the same Wi-Fi network. Downloaded videos can’t be cast."
        resumeOnPhone()
    }

    func requestDidComplete(_ request: GCKRequest) {
        guard request === loadRequest else { return }
        loadRequest = nil
        isLoading = false
        isCasting = true
        if let client, episode?.matches(client.mediaStatus?.mediaInformation) == true {
            remoteMediaClient(client, didUpdate: client.mediaStatus)
        }
        updateRemoteProgress()
    }

    func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        guard request === loadRequest else { return }
        failLoad()
    }

    func request(_ request: GCKRequest, didAbortWith reason: GCKRequestAbortReason) {
        guard request === loadRequest else { return }
        failLoad()
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKSession) {
        observeSession()
        castCurrentEpisode()
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didResumeSession session: GCKSession) {
        observeSession()
        if let episode, episode.matches(client?.mediaStatus?.mediaInformation) {
            isCasting = true
            player?.pause()
            if let client { remoteMediaClient(client, didUpdate: client.mediaStatus) }
            updateRemoteProgress()
        } else if episode != nil, client?.mediaStatus?.mediaInformation == nil {
            // Resumption can precede the first media status; keep the phone paused until it arrives.
            isCasting = true
            player?.pause()
        } else {
            isCasting = false
            isLoading = false
        }
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didSuspend session: GCKSession, with reason: GCKConnectionSuspendReason) {
        updateRemoteProgress()
        isConnected = false
        // A suspended connection can still be playing on the TV; don't start a second copy.
    }

    func sessionManager(_ sessionManager: GCKSessionManager, willEnd session: GCKSession) {
        updateRemoteProgress()
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKSession, withError error: Error?) {
        let shouldResume = isCasting || isLoading
        loadRequest?.delegate = nil
        loadRequest = nil
        isCasting = false
        isLoading = false
        observeSession()
        if shouldResume { resumeOnPhone() }
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKSession, withError error: Error) {
        observeSession()
        errorMessage = "Couldn’t connect to the TV. Check that both devices are on the same Wi-Fi network and allow Local Network access in iPhone Settings."
    }

    func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        guard let episode, isCasting, !isLoading else { return }
        guard episode.matches(mediaStatus?.mediaInformation) else {
            // Another sender replaced the TV's video; never save it as this episode.
            if mediaStatus?.mediaInformation != nil { isCasting = false }
            return
        }
        if mediaStatus?.idleReason == .error {
            failLoad()
        } else if mediaStatus?.idleReason == .finished, !completed {
            updateRemoteProgress()
            completed = true
            completedEpisodeID = episode.id
            wasPlaying = false
            onComplete?()
        } else if mediaStatus?.playerState == .playing || mediaStatus?.playerState == .paused {
            isCasting = true
            wasPlaying = mediaStatus?.playerState == .playing
            player?.pause()
            updateRemoteProgress()
        }
    }
}

struct ChromecastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> GCKUICastButton {
        let button = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        button.tintColor = .white
        button.accessibilityLabel = "Cast to TV"
        return button
    }
    func updateUIView(_ view: GCKUICastButton, context: Context) {}
}

struct ChromecastMiniController: UIViewControllerRepresentable {
    @Binding var isActive: Bool
    func makeCoordinator() -> Coordinator { Coordinator(isActive: $isActive) }
    func makeUIViewController(context: Context) -> GCKUIMiniMediaControlsViewController {
        let controller = GCKCastContext.sharedInstance().createMiniMediaControlsViewController()
        controller.delegate = context.coordinator
        controller.loadViewIfNeeded()
        DispatchQueue.main.async { context.coordinator.isActive.wrappedValue = controller.active }
        return controller
    }
    func updateUIViewController(_ controller: GCKUIMiniMediaControlsViewController, context: Context) {}

    final class Coordinator: NSObject, GCKUIMiniMediaControlsViewControllerDelegate {
        let isActive: Binding<Bool>
        init(isActive: Binding<Bool>) { self.isActive = isActive }
        func miniMediaControlsViewController(_ miniMediaControlsViewController: GCKUIMiniMediaControlsViewController,
                                             shouldAppear: Bool) {
            DispatchQueue.main.async { self.isActive.wrappedValue = shouldAppear }
        }
    }
}

struct ChromecastPlayerPanel: View {
    @ObservedObject var cast: ChromecastPlayback
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "tv").font(.system(size: 40)).accessibilityHidden(true)
            Text(cast.isLoading ? "Connecting to \(cast.deviceName)…" : cast.isConnected ? "Playing on \(cast.deviceName)" : "Reconnecting to \(cast.deviceName)…")
                .font(.headline).multilineTextAlignment(.center)
            if cast.isLoading { ProgressView() }
            else {
                Button("TV controls", systemImage: "playpause", action: cast.controls)
                    .buttonStyle(.borderedProminent).tint(CloudTheme.violet)
                    .disabled(!cast.isConnected)
            }
            Button("Play on this iPhone", action: cast.stopCasting).buttonStyle(.bordered)
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
