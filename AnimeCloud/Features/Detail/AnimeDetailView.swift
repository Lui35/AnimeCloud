import AVKit
import AVFAudio
import SwiftUI

struct AnimeDetailView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var model: AppModel
    let anime: Anime
    let library: LibraryStore
    @State private var detail: AnimeDetail?
    @State private var isLoading = true
    @State private var selectedEpisode: Episode?
    @State private var showingDownloadSelection = false
    @State private var navigationVisibility = ScrollAwareNavigationVisibility()

    var body: some View {
        ZStack {
            CloudBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    hero.background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: AnimeDetailScrollOffsetKey.self,
                                value: proxy.frame(in: .named("animeDetailScroll")).minY
                            )
                        }
                    }
                    if isLoading { ProgressView("Loading episodes…").frame(maxWidth: .infinity).padding(50) }
                    if let detail {
                        metadata(detail)
                        story(detail)
                        episodes(detail.episodes)
                    }
                }
                .padding(.bottom, 80)
            }
            .coordinateSpace(name: "animeDetailScroll")
            .onPreferenceChange(AnimeDetailScrollOffsetKey.self, perform: updateNavigationVisibility)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(navigationVisibility.isVisible ? .visible : .hidden, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await load() }
        .sheet(isPresented: $showingDownloadSelection) {
            DownloadSelectionView(downloads: model.downloads, anime: anime, catalog: detail?.episodes ?? [])
        }
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
        AnimeDetailHero(anime: anime) {
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
            HStack {
                SectionHeading(title: "Episodes", subtitle: "Newest first")
                Button { showingDownloadSelection = true } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .disabled(items.isEmpty)
            }
            .padding(.horizontal, 20)
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

    private func updateNavigationVisibility(for offset: CGFloat) {
        var next = navigationVisibility
        next.update(offset: offset)
        guard next.isVisible != navigationVisibility.isVisible else {
            navigationVisibility = next
            return
        }
        if reduceMotion {
            navigationVisibility = next
        } else {
            withAnimation(.snappy(duration: 0.22)) { navigationVisibility = next }
        }
    }
}

private struct AnimeDetailScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct ScrollAwareNavigationVisibility: Equatable {
    private(set) var isVisible = true
    private var referenceOffset: CGFloat?

    mutating func update(offset: CGFloat) {
        guard offset.isFinite else { return }
        guard let referenceOffset else {
            self.referenceOffset = offset
            return
        }
        if offset >= -12 {
            isVisible = true
            self.referenceOffset = offset
            return
        }
        let delta = offset - referenceOffset
        guard abs(delta) >= 8 else { return }
        isVisible = delta > 0
        self.referenceOffset = offset
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

struct AnimeDetailHero<Actions: View>: View {
    let anime: Anime
    var cachedArtworkURL: URL?
    @ViewBuilder let actions: Actions

    var body: some View {
        ZStack(alignment: .bottom) {
            RemoteArtwork(url: cachedArtworkURL ?? anime.imageURL).frame(height: 430)
            LinearGradient(colors: [.clear, CloudTheme.ink.opacity(0.5), CloudTheme.ink], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 14) {
                Text(anime.name).font(.system(size: 32, weight: .black, design: .rounded)).multilineTextAlignment(.center)
                Text(anime.subtitle).font(.subheadline).foregroundStyle(CloudTheme.muted)
                actions
            }
            .padding(.horizontal, 20)
        }
    }
}

struct EpisodeRow: View {
    @EnvironmentObject private var model: AppModel
    let anime: Anime
    let episode: Episode
    let library: LibraryStore
    @ObservedObject var progressStore: PlaybackProgressStore
    let download: EpisodeDownload?
    let onRemove: (() -> Void)?
    let onOpen: () -> Void
    @State private var displayedIsSeen: Bool
    @State private var statusCommitTask: Task<Void, Never>?

    init(
        anime: Anime,
        episode: Episode,
        library: LibraryStore,
        progressStore: PlaybackProgressStore,
        download: EpisodeDownload? = nil,
        onRemove: (() -> Void)? = nil,
        onOpen: @escaping () -> Void
    ) {
        self.anime = anime
        self.episode = episode
        self.library = library
        self.progressStore = progressStore
        self.download = download
        self.onRemove = onRemove
        self.onOpen = onOpen
        _displayedIsSeen = State(initialValue: library.isSeen(episode))
    }

    var body: some View {
        rowContent
            .background {
                if displayedIsSeen {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(CloudTheme.cyan.opacity(0.08))
                }
            }
            .cloudPanel()
            .overlay {
                if displayedIsSeen {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(CloudTheme.cyan.opacity(0.45), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .onReceive(library.seenStatusChanged) { change in
                guard change.episodeID == episode.id else { return }
                displayedIsSeen = change.isSeen
            }
    }

    private var canPlay: Bool {
        download == nil || model.downloads.localURL(for: episode.id) != nil
    }

    private var canRetry: Bool {
        download?.status == .failed || (download?.status == .ready && !canPlay)
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Button {
                if canPlay { onOpen() }
                else { model.downloads.retry(episode.id) }
            } label: {
                HStack(spacing: 13) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 7) {
                        Text(episode.name).font(.headline).multilineTextAlignment(.leading)
                        VStack(alignment: .leading, spacing: 7) { episodeStatus }
                            .font(.caption)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canPlay && !canRetry)
            .accessibilityElement(children: .combine)
            .accessibilityValue("\(displayedIsSeen ? "Watched" : "Unwatched"), \(episode.episodeTypeLabel) episode")

            Menu {
                Button {
                    commitSeenStatus(!displayedIsSeen)
                } label: {
                    Label(
                        displayedIsSeen ? "Mark as Unwatched" : "Mark as Watched",
                        systemImage: displayedIsSeen ? "eye.slash" : "checkmark.circle"
                    )
                }
                if canRetry {
                    Button("Retry download", systemImage: "arrow.clockwise") { model.downloads.retry(episode.id) }
                }
                if let onRemove {
                    Button(role: .destructive, action: onRemove) {
                        Label("Remove download", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(CloudTheme.muted)
                    .frame(width: 44, height: 52)
            }
            .accessibilityLabel("Options for \(episode.name)")
        }
        .padding(10)
    }

    private var thumbnail: some View {
        RemoteArtwork(url: episode.imageURL, fallbackFileURL: download.flatMap { model.downloads.artworkURL(for: $0.anime.id) })
            .frame(width: 120, height: 72)
            .overlay(alignment: .topLeading) {
                if episode.isFiller {
                    EpisodeTypeBadge(episode: episode).padding(6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if displayedIsSeen {
                    Label("Watched", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(CloudTheme.ink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(CloudTheme.cyan, in: Capsule())
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 13))
            .accessibilityHidden(true)
    }

    @ViewBuilder private var episodeStatus: some View {
        if canPlay {
            if let progress = progressStore.progress(for: episode.id) {
                Label("Resume \(PlaybackTimeFormatter.string(progress.position))", systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(CloudTheme.cyan)
                ProgressView(value: progress.fraction)
                    .tint(CloudTheme.cyan)
                    .frame(maxWidth: 170)
            } else {
                Label(displayedIsSeen ? "Watch again" : (download == nil ? "Ready to play" : "Ready to play offline"),
                      systemImage: displayedIsSeen ? "arrow.counterclockwise" : "play.circle")
                    .foregroundStyle(CloudTheme.muted)
            }
        } else if canRetry {
            Label("Retry download", systemImage: "arrow.clockwise")
                .foregroundStyle(CloudTheme.cyan)
            Text(download?.failure ?? "Video missing. Download again.")
                .foregroundStyle(CloudTheme.muted)
        } else if download?.status == .preparing {
            Text("Preparing download…").foregroundStyle(CloudTheme.muted)
        } else if let fraction = model.downloads.progress[episode.id], fraction > 0, fraction <= 1 {
            ProgressView(value: fraction) { Text("Downloading") }.tint(CloudTheme.cyan)
        } else {
            ProgressView("Downloading…").tint(CloudTheme.cyan)
        }
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

struct PlayerSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let anime: Anime
    let episodes: [Episode]
    let library: LibraryStore
    let downloadedPlayback: Bool
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
    @State private var isAnime4KFullscreen = false
    @StateObject private var anime4KBenchmark = Anime4KBenchmarkController()
    @AppStorage("playback.anime4k.mode") private var anime4KModeRawValue = Anime4KPlaybackMode.off.rawValue

    init(
        anime: Anime,
        initialEpisode: Episode,
        episodes: [Episode],
        library: LibraryStore,
        progressStore: PlaybackProgressStore,
        downloadedPlayback: Bool = false
    ) {
        self.anime = anime
        self.episodes = episodes
        self.library = library
        self.downloadedPlayback = downloadedPlayback
        self.progressStore = progressStore
        _episode = State(initialValue: initialEpisode)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player, !anime4KBenchmark.isRunning {
                    if !isAnime4KFullscreen {
                        if let preset = anime4KMode.preset {
                            ZStack {
                                Anime4KVideoPlayer(player: player, preset: preset)
                                    .id(anime4KMode.rawValue)
                                    .contentShape(Rectangle())
                                    .gesture(verticalFullscreenGesture(isFullscreen: false))
                                EnhancedVideoControls(
                                    player: player,
                                    isFullscreen: false,
                                    toggleFullscreen: { isAnime4KFullscreen = true },
                                    hideControls: nil,
                                    anime4KMode: nil,
                                    selectAnime4KMode: nil,
                                    runAnime4KBenchmark: nil,
                                    onInteraction: {}
                                )
                            }
                            .ignoresSafeArea(edges: .horizontal)
                        } else {
                            NativeVideoPlayer(player: player).ignoresSafeArea(edges: .horizontal)
                        }
                    }
                }
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
            .overlay(alignment: .top) {
                if downloadedPlayback, player != nil {
                    Label("Playing offline", systemImage: "arrow.down.circle.fill")
                        .font(.caption.weight(.semibold))
                        .padding(8)
                        .background(.regularMaterial, in: Capsule())
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if showingUpNext { upNextPanel.transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
            .navigationTitle(episode.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { anime4KMenu }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { closePlayer() } }
            }
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
        .overlay {
            if !isAnime4KFullscreen {
                Anime4KBenchmarkOverlay(
                    controller: anime4KBenchmark,
                    applyMode: selectAnime4KMode
                )
            }
        }
        .fullScreenCover(isPresented: $isAnime4KFullscreen) {
            if let player {
                Anime4KFullscreenPlayer(
                    player: player,
                    modeRawValue: $anime4KModeRawValue,
                    benchmark: anime4KBenchmark,
                    isPresented: $isAnime4KFullscreen
                )
            }
        }
    }

    private var anime4KMode: Anime4KPlaybackMode {
        Anime4KPlaybackMode(rawValue: anime4KModeRawValue) ?? .off
    }

    private var anime4KMenu: some View {
        Anime4KModeMenu(
            mode: anime4KMode,
            selectMode: selectAnime4KMode,
            runBenchmark: runAnime4KBenchmark
        )
    }

    private func selectAnime4KMode(_ mode: Anime4KPlaybackMode) {
        anime4KModeRawValue = mode.rawValue
    }

    private func runAnime4KBenchmark() {
        guard let player else { return }
        anime4KBenchmark.start(player: player)
    }

    private func verticalFullscreenGesture(isFullscreen: Bool) -> some Gesture {
        DragGesture(minimumDistance: 30).onEnded { value in
            guard PlayerFullscreenGesture.action(
                for: value.translation,
                isFullscreen: isFullscreen
            ) == .enter else { return }
            isAnime4KFullscreen = true
        }
    }

    private func closePlayer() {
        anime4KBenchmark.cancel()
        isAnime4KFullscreen = false
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
            let url: URL
            if let local = model.downloads.localURL(for: episode.id) {
                url = local
            } else if downloadedPlayback {
                throw DownloadError.missing
            } else {
                url = try await model.api.playback(epID: episode.id, quality: "1").url
            }
            guard requestIsCurrent(requestID) else {
                tearDownPlayer()
                return
            }
            let asset = AVURLAsset(url: url)
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
                Text(downloadedPlayback ? "No more downloaded episodes" : "You’re all caught up").font(.title2.bold())
                if !downloadedPlayback {
                    Text("There isn’t a newer episode available yet.").font(.subheadline).foregroundStyle(CloudTheme.muted)
                }
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

    private var episodesForWatchStatus: [Episode] {
        guard downloadedPlayback else { return episodes }
        return model.downloads.records[episode.id]?.finalCanonEpisode.map { [$0] } ?? []
    }

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
                guard isPlayerVisible, episode.id == completedEpisode.id else { return }
                progressStore.clear(episodeID: completedEpisode.id)
                library.completePlayback(of: completedEpisode, anime: anime, episodes: episodesForWatchStatus)
                withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { showingUpNext = true }
            }
        }
    }

    private func installProgressObserver(on player: AVPlayer) {
        let observedEpisode = episode
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 3, preferredTimescale: 600),
            queue: .main
        ) { time in
            let duration = player.currentItem?.duration.seconds ?? 0
            let position = time.seconds
            Task { @MainActor in
                guard isPlayerVisible, episode.id == observedEpisode.id else { return }
                progressStore.save(episodeID: observedEpisode.id, position: position, duration: duration)
                library.recordPlayback(of: observedEpisode, anime: anime, episodes: episodesForWatchStatus, position: position, duration: duration)
            }
        }
    }

    private func tearDownPlayer(deactivateAudio: Bool = true) {
        if let player {
            let duration = player.currentItem?.duration.seconds ?? 0
            let position = player.currentTime().seconds
            progressStore.save(episodeID: episode.id, position: position, duration: duration)
            library.recordPlayback(of: episode, anime: anime, episodes: episodes, position: position, duration: duration)
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

private struct Anime4KFullscreenPlayer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let player: AVPlayer
    @Binding var modeRawValue: String
    @ObservedObject var benchmark: Anime4KBenchmarkController
    @Binding var isPresented: Bool
    @State private var controlsAreVisible = true
    @State private var controlHideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if !benchmark.isRunning {
                Group {
                    if let preset = mode.preset {
                        Anime4KVideoPlayer(player: player, preset: preset)
                            .id("fullscreen-\(mode.rawValue)")
                    } else {
                        NativeVideoSurface(player: player)
                    }
                }
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }
                .gesture(verticalFullscreenGesture)
            }
            if controlsAreVisible && !benchmark.isRunning && benchmark.report == nil {
                EnhancedVideoControls(
                    player: player,
                    isFullscreen: true,
                    toggleFullscreen: { isPresented = false },
                    hideControls: { hideControls() },
                    anime4KMode: mode,
                    selectAnime4KMode: selectMode,
                    runAnime4KBenchmark: runBenchmark,
                    onInteraction: scheduleControlFade
                )
                .ignoresSafeArea(edges: .horizontal)
                .transition(.opacity)
            }
            Anime4KBenchmarkOverlay(
                controller: benchmark,
                applyMode: selectMode
            )
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: controlsAreVisible)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            PlaybackOrientation.request(.landscape)
            scheduleControlFade()
        }
        .onDisappear {
            controlHideTask?.cancel()
            PlaybackOrientation.request(.portrait)
        }
    }

    private var mode: Anime4KPlaybackMode {
        Anime4KPlaybackMode(rawValue: modeRawValue) ?? .off
    }

    private func selectMode(_ mode: Anime4KPlaybackMode) {
        modeRawValue = mode.rawValue
    }

    private func runBenchmark() {
        benchmark.start(player: player)
    }

    private func toggleControls() {
        if controlsAreVisible {
            hideControls()
        } else {
            controlsAreVisible = true
            scheduleControlFade()
        }
    }

    private func hideControls() {
        controlHideTask?.cancel()
        controlsAreVisible = false
    }

    private func scheduleControlFade() {
        controlHideTask?.cancel()
        guard controlsAreVisible else { return }
        controlHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            controlsAreVisible = false
        }
    }

    private var verticalFullscreenGesture: some Gesture {
        DragGesture(minimumDistance: 30).onEnded { value in
            guard PlayerFullscreenGesture.action(
                for: value.translation,
                isFullscreen: true
            ) == .exit else { return }
            isPresented = false
        }
    }
}

enum PlayerFullscreenGestureAction: Equatable {
    case enter
    case exit
}

enum PlayerFullscreenGesture {
    static func action(for translation: CGSize, isFullscreen: Bool) -> PlayerFullscreenGestureAction? {
        guard abs(translation.height) >= 70,
              abs(translation.height) > abs(translation.width) * 1.25
        else { return nil }
        if translation.height < 0, !isFullscreen { return .enter }
        if translation.height > 0, isFullscreen { return .exit }
        return nil
    }
}

private enum PlaybackOrientation {
    @MainActor
    static func request(_ orientations: UIInterfaceOrientationMask) {
        guard UIDevice.current.userInterfaceIdiom == .phone,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
        else { return }

        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations))
        scene.windows
            .first(where: \.isKeyWindow)?
            .rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
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
        if episode.isFiller {
            Label("Filler", systemImage: "sparkles")
                .font(.caption.weight(.bold))
                .foregroundStyle(CloudTheme.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.orange, in: Capsule())
                .accessibilityLabel("Filler episode")
        } else {
            Image(systemName: "checkmark.seal.fill")
                .font(.caption.weight(.black))
                .foregroundStyle(CloudTheme.cyan)
                .frame(width: 26, height: 26)
                .background(CloudTheme.cyan.opacity(0.14), in: Circle())
                .overlay { Circle().stroke(CloudTheme.cyan.opacity(0.28), lineWidth: 1) }
                .accessibilityLabel("Canon episode")
        }
    }
}
