import AVKit
import AVFAudio
import SwiftUI

struct AnimeDetailView: View {
    @EnvironmentObject private var model: AppModel
    let anime: Anime
    let library: LibraryStore
    @State private var detail: AnimeDetail?
    @State private var isLoading = true
    @State private var selectedEpisode: Episode?

    var body: some View {
        ZStack {
            CloudBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    hero
                    if isLoading { ProgressView("Loading episodes…").frame(maxWidth: .infinity).padding(50) }
                    if let detail {
                        metadata(detail)
                        story(detail)
                        episodes(detail.episodes)
                    }
                }
                .padding(.bottom, 80)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await load() }
        .sheet(item: $selectedEpisode) { episode in
            PlayerSheet(
                anime: anime,
                initialEpisode: episode,
                episodes: detail?.episodes ?? [episode],
                library: library,
                progressStore: model.playbackProgress
            )
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottom) {
            RemoteArtwork(url: anime.imageURL).frame(height: 430)
            LinearGradient(colors: [.clear, CloudTheme.ink.opacity(0.5), CloudTheme.ink], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 14) {
                Text(anime.name).font(.system(size: 32, weight: .black, design: .rounded)).multilineTextAlignment(.center)
                Text(anime.subtitle).font(.subheadline).foregroundStyle(CloudTheme.muted)
                HStack(spacing: 12) {
                    if let first = detail?.episodes.last {
                        Button { selectedEpisode = first } label: { Label("Start watching", systemImage: "play.fill") }
                            .buttonStyle(PrimaryCapsuleStyle())
                    }
                    LibrarySaveMenu(anime: anime, store: library, size: 48)
                }
                NavigationLink {
                    RelatedAnimeView(
                        anime: anime,
                        relatedID: detail?.summary?.relatedID,
                        library: library
                    )
                } label: {
                    Label("Related series", systemImage: "rectangle.stack.fill")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 17)
                        .frame(height: 42)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .disabled(detail == nil)
            }.padding(.horizontal, 20)
        }
    }

    private func metadata(_ detail: AnimeDetail) -> some View {
        HStack(spacing: 10) {
            if let rank = detail.summary?.rank, !rank.isEmpty { tag("★ \(rank)") }
            if let age = detail.summary?.age, !age.isEmpty { tag(age) }
            tag("\(detail.episodes.count) episodes")
        }
        .padding(.horizontal, 20)
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.caption.weight(.bold)).padding(.horizontal, 11).padding(.vertical, 7).background(CloudTheme.panel, in: Capsule())
    }

    @ViewBuilder private func story(_ detail: AnimeDetail) -> some View {
        if let story = detail.more?.story, !story.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(title: "Story", subtitle: detail.more?.genres)
                Text(story).font(.body).foregroundStyle(.white.opacity(0.82)).lineSpacing(5)
            }.padding(.horizontal, 20)
        }
    }

    private func episodes(_ items: [Episode]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "Episodes", subtitle: "Newest first").padding(.horizontal, 20)
            LazyVStack(spacing: 12) {
                ForEach(items) { episode in
                    EpisodeRow(
                        anime: anime,
                        episode: episode,
                        library: library,
                        progressStore: model.playbackProgress
                    ) {
                        selectedEpisode = episode
                    }
                }
            }.padding(.horizontal, 16)
        }
    }

    private func load() async {
        library.recordOpened(anime)
        let loadedDetail = try? await model.api.animeDetail(id: anime.id)
        detail = loadedDetail
        if let episodes = loadedDetail?.episodes {
            model.applyAniListProgress(to: anime, episodes: episodes)
        }
        isLoading = false
    }
}

private struct RelatedAnimeView: View {
    @EnvironmentObject private var model: AppModel
    let anime: Anime
    let relatedID: String?
    let library: LibraryStore
    @State private var items: [Anime] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var reloadToken = UUID()

    private let columns = [GridItem(.adaptive(minimum: 142), spacing: 16)]

    var body: some View {
        ZStack {
            CloudBackground()
            if isLoading {
                ProgressView("Finding connected stories…")
            } else if let errorMessage {
                VStack(spacing: 18) {
                    EmptyCloud(title: "Related series unavailable", detail: errorMessage, systemImage: "rectangle.stack.badge.exclamationmark")
                    Button("Try Again", systemImage: "arrow.clockwise") { reloadToken = UUID() }
                        .buttonStyle(.borderedProminent).tint(CloudTheme.violet)
                }.padding(24)
            } else if items.isEmpty {
                EmptyCloud(
                    title: "No related series found",
                    detail: "The Anime Cloud catalog does not currently link another season, sequel, prequel, or movie to \(anime.name).",
                    systemImage: "rectangle.stack"
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                        ForEach(items) { related in
                            NavigationLink {
                                AnimeDetailView(anime: related, library: library)
                            } label: {
                                PosterView(anime: related, width: 142, height: 204)
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle("Related to \(anime.name)")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: reloadToken) { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            items = try await model.api.relatedAnime(animeID: anime.id, relatedID: relatedID)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}

struct PrimaryCapsuleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).padding(.horizontal, 18).frame(height: 48)
            .background(.white.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule()).foregroundStyle(CloudTheme.ink)
    }
}

private struct EpisodeRow: View {
    let anime: Anime
    let episode: Episode
    let library: LibraryStore
    @ObservedObject var progressStore: PlaybackProgressStore
    let onOpen: () -> Void
    @State private var displayedIsSeen: Bool
    @State private var statusCommitTask: Task<Void, Never>?

    init(
        anime: Anime,
        episode: Episode,
        library: LibraryStore,
        progressStore: PlaybackProgressStore,
        onOpen: @escaping () -> Void
    ) {
        self.anime = anime
        self.episode = episode
        self.library = library
        self.progressStore = progressStore
        self.onOpen = onOpen
        _displayedIsSeen = State(initialValue: library.isSeen(episode))
    }

    var body: some View {
        rowContent
            .cloudPanel()
            .onReceive(library.seenStatusChanged) { change in
                guard change.episodeID == episode.id else { return }
                displayedIsSeen = change.isSeen
            }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            HStack(spacing: 13) {
                RemoteArtwork(url: episode.imageURL)
                    .frame(width: 120, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 7) {
                    Text(episode.name).font(.headline).multilineTextAlignment(.leading)
                    HStack(spacing: 8) {
                        if let progress = progressStore.progress(for: episode.id) {
                            Label("Resume \(PlaybackTimeFormatter.string(progress.position))", systemImage: "clock.arrow.circlepath")
                                .font(.caption).foregroundStyle(CloudTheme.cyan)
                        } else {
                            Label(displayedIsSeen ? "Watched" : "Ready to play", systemImage: displayedIsSeen ? "checkmark.circle.fill" : "play.circle")
                                .font(.caption).foregroundStyle(displayedIsSeen ? CloudTheme.cyan : CloudTheme.muted)
                        }
                        EpisodeTypeBadge(episode: episode)
                    }
                    if let progress = progressStore.progress(for: episode.id) {
                        ProgressView(value: progress.fraction)
                            .tint(CloudTheme.cyan)
                            .frame(maxWidth: 170)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onOpen() }

            Menu {
                Button {
                    commitSeenStatus(!displayedIsSeen)
                } label: {
                    Label(
                        displayedIsSeen ? "Mark as Unwatched" : "Mark as Watched",
                        systemImage: displayedIsSeen ? "eye.slash" : "checkmark.circle"
                    )
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(CloudTheme.muted)
                    .frame(width: 38, height: 52)
            }
            .accessibilityLabel("Options for \(episode.name)")
        }
        .padding(10)
    }

    private func commitSeenStatus(_ newValue: Bool) {
        displayedIsSeen = newValue
        statusCommitTask?.cancel()
        statusCommitTask = Task { @MainActor in
            // Let the native Menu dismiss and the optimistic row update render first.
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            if newValue { library.markSeen(episode, anime: anime) }
            else { library.markUnseen(episode, anime: anime) }
        }
    }
}

private struct PlayerSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let anime: Anime
    let episodes: [Episode]
    let library: LibraryStore
    @ObservedObject var progressStore: PlaybackProgressStore
    @State private var episode: Episode
    @State private var player: AVPlayer?
    @State private var error: String?
    @State private var timeObserver: Any?
    @State private var itemFailureObserver: NSObjectProtocol?
    @State private var endObserver: NSObjectProtocol?
    @State private var retryToken = UUID()
    @State private var showingUpNext = false
    @State private var isPlayerVisible = true

    init(
        anime: Anime,
        initialEpisode: Episode,
        episodes: [Episode],
        library: LibraryStore,
        progressStore: PlaybackProgressStore
    ) {
        self.anime = anime
        self.episodes = episodes
        self.library = library
        self.progressStore = progressStore
        _episode = State(initialValue: initialEpisode)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player { NativeVideoPlayer(player: player).ignoresSafeArea(edges: .horizontal) }
                else if let error {
                    VStack(spacing: 18) {
                        EmptyCloud(title: "Playback unavailable", detail: error, systemImage: "exclamationmark.triangle")
                        Button("Try Again", systemImage: "arrow.clockwise") { retryToken = UUID() }
                            .buttonStyle(.borderedProminent)
                            .tint(CloudTheme.violet)
                    }
                    .padding(24)
                }
                else {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text(progressStore.progress(for: episode.id) == nil ? "Preparing playback…" : "Preparing your resume point…")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if showingUpNext { upNextPanel.transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
            .navigationTitle(episode.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { closePlayer() } } }
            // SwiftUI emits onDisappear while AVPlayerViewController enters and exits
            // native fullscreen, so it cannot be used as a dismissal signal. Requiring
            // Done gives playback one unambiguous cleanup path.
            .interactiveDismissDisabled()
            .onAppear { isPlayerVisible = true }
            .task(id: retryToken) {
                // Returning from AVPlayerViewController fullscreen makes SwiftUI
                // run this task again. Keep the existing player and media item.
                guard player == nil else { return }
                let requestID = retryToken
                await preparePlayback(requestID: requestID)
            }
        }
    }

    private func closePlayer() {
        isPlayerVisible = false
        tearDownPlayer()
        dismiss()
    }

    private func preparePlayback(requestID: UUID) async {
        guard requestIsCurrent(requestID) else { return }
        tearDownPlayer(deactivateAudio: false)
        error = nil
        showingUpNext = false
        configureAudioSession()

        do {
            let source = try await model.api.playback(epID: episode.id, quality: "1")
            guard requestIsCurrent(requestID) else {
                tearDownPlayer()
                return
            }
            let asset = AVURLAsset(url: source.url)
            guard try await asset.load(.isPlayable) else { throw PlaybackPresentationError.notPlayable }
            guard requestIsCurrent(requestID) else {
                tearDownPlayer()
                return
            }

            let item = AVPlayerItem(asset: asset)
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.automaticallyWaitsToMinimizeStalling = true
            player = newPlayer
            installFailureObserver(for: item)
            installEndObserver(for: item)
            installProgressObserver(on: newPlayer)

            if let saved = progressStore.progress(for: episode.id), saved.position >= 3 {
                let resumeTime = CMTime(seconds: saved.position, preferredTimescale: 600)
                await newPlayer.seek(to: resumeTime, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            guard requestIsCurrent(requestID) else {
                tearDownPlayer()
                return
            }
            newPlayer.play()
        } catch is CancellationError {
            tearDownPlayer()
            return
        } catch {
            guard requestIsCurrent(requestID) else { return }
            self.error = playbackMessage(for: error)
        }
    }

    private func requestIsCurrent(_ requestID: UUID) -> Bool {
        isPlayerVisible && !Task.isCancelled && retryToken == requestID
    }

    @ViewBuilder private var upNextPanel: some View {
        VStack(spacing: 14) {
            Text("EPISODE COMPLETE").font(.caption.weight(.black)).tracking(1.5).foregroundStyle(CloudTheme.cyan)
            if let nextEpisode {
                Text("Up next").font(.title2.bold())
                Text(nextEpisode.name).font(.headline).foregroundStyle(.white.opacity(0.78))
                HStack(spacing: 10) {
                    Button { playNextEpisode() } label: { Label("Play Next", systemImage: "forward.fill") }
                        .buttonStyle(.borderedProminent).tint(CloudTheme.violet)
                    EpisodeTypeBadge(episode: nextEpisode)
                }
            } else {
                Text("You’re all caught up").font(.title2.bold())
                Text("There isn’t a newer episode available yet.").font(.subheadline).foregroundStyle(CloudTheme.muted)
            }
            Button("Replay", systemImage: "arrow.counterclockwise") { replayEpisode() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 26).stroke(Color.white.opacity(0.12)) }
        .padding(16)
    }

    private var nextEpisode: Episode? { episodes.nextEpisode(after: episode) }

    private func playNextEpisode() {
        guard let nextEpisode else { return }
        tearDownPlayer(deactivateAudio: false)
        episode = nextEpisode
        showingUpNext = false
        retryToken = UUID()
    }

    private func replayEpisode() {
        progressStore.clear(episodeID: episode.id)
        showingUpNext = false
        if let player {
            Task {
                await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                player.play()
            }
        } else {
            retryToken = UUID()
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // AirPlay is already supported by the playback category. Passing the
            // allowAirPlay option here returns paramErr (-50) on some real devices.
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            // Audio-session conflicts must never prevent a valid video from loading.
            // AVPlayer can still use the currently active session configuration.
        }
    }

    private func installFailureObserver(for item: AVPlayerItem) {
        itemFailureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { notification in
            let underlying = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in
                guard isPlayerVisible else { return }
                self.error = playbackMessage(for: underlying ?? item.error ?? PlaybackPresentationError.notPlayable)
                self.player?.pause()
                self.player = nil
            }
        }
    }

    private func installEndObserver(for item: AVPlayerItem) {
        let completedEpisode = episode
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in
                guard isPlayerVisible else { return }
                progressStore.clear(episodeID: completedEpisode.id)
                library.markSeen(completedEpisode, anime: anime)
                withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { showingUpNext = true }
            }
        }
    }

    private func installProgressObserver(on player: AVPlayer) {
        let episodeID = episode.id
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 3, preferredTimescale: 600),
            queue: .main
        ) { time in
            let duration = player.currentItem?.duration.seconds ?? 0
            let position = time.seconds
            Task { @MainActor in
                progressStore.save(episodeID: episodeID, position: position, duration: duration)
                if duration.isFinite, duration > 0, position / duration >= 0.90 {
                    library.markSeen(episode, anime: anime)
                }
            }
        }
    }

    private func tearDownPlayer(deactivateAudio: Bool = true) {
        if let player {
            let duration = player.currentItem?.duration.seconds ?? 0
            let position = player.currentTime().seconds
            progressStore.save(episodeID: episode.id, position: position, duration: duration)
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        self.timeObserver = nil
        if let itemFailureObserver { NotificationCenter.default.removeObserver(itemFailureObserver) }
        self.itemFailureObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        self.endObserver = nil
        self.player = nil
        if deactivateAudio {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func playbackMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorAppTransportSecurityRequiresSecureConnection {
            return "This older episode uses an insecure media URL that iOS blocked. Try again after updating the app."
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

private enum PlaybackPresentationError: LocalizedError {
    case notPlayable

    var errorDescription: String? {
        "The episode source exists, but iOS cannot play its current media format or the server rejected the stream."
    }
}

private struct NativeVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.exitsFullScreenWhenPlaybackEnds = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
    }
}

private struct EpisodeTypeBadge: View {
    let episode: Episode

    var body: some View {
        Image(systemName: episode.isFiller ? "wand.and.stars" : "checkmark.seal.fill")
        .font(.caption.weight(.black))
        .foregroundStyle(episode.isFiller ? CloudTheme.coral : CloudTheme.cyan)
        .frame(width: 26, height: 26)
        .background((episode.isFiller ? CloudTheme.coral : CloudTheme.cyan).opacity(0.14), in: Circle())
        .overlay {
            Circle().stroke((episode.isFiller ? CloudTheme.coral : CloudTheme.cyan).opacity(0.28), lineWidth: 1)
        }
        .accessibilityLabel(episode.isFiller ? "Filler episode" : "Canon episode")
    }
}
