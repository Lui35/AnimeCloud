import AVKit
import AVFAudio
import MediaPlayer
import SwiftUI

struct AnimeDetailView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @EnvironmentObject private var model: AppModel
    let anime: Anime
    let library: LibraryStore
    @State private var detail: AnimeDetail?
    @State private var isLoading = true
    @State private var selectedEpisode: Episode?
    @State private var showingDownloadSelection = false
    @State private var navigationVisibility = ScrollAwareNavigationVisibility()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                CloudBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        hero(topInset: geometry.safeAreaInsets.top)
                            .background {
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
                .ignoresSafeArea(.container, edges: .top)
                .coordinateSpace(name: "animeDetailScroll")
                .onPreferenceChange(AnimeDetailScrollOffsetKey.self, perform: updateNavigationVisibility)
                .refreshable { await load(forceRefresh: true) }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(navigationVisibility.isVisible ? .visible : .hidden, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                AnimePlaybackMenu(
                    animeID: anime.id,
                    progress: model.playbackProgress,
                    episodeIDs: Set(detail?.episodes.map(\.id) ?? []).union(
                        model.downloads.records.values.filter { $0.anime.id == anime.id }.map(\.id)
                    ),
                    isToolbarItem: true
                )
            }
        }
        .task { await load() }
        .sheet(isPresented: $showingDownloadSelection) {
            DownloadSelectionView(downloads: model.downloads, library: library, anime: anime, catalog: detail?.episodes ?? [])
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

    private func hero(topInset: CGFloat) -> some View {
        AnimeDetailHero(
            anime: anime,
            artworkHeight: verticalSizeClass == .compact ? 430 : 520,
            topInset: topInset
        ) {
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

    private func load(forceRefresh: Bool = false) async {
        library.recordOpened(anime)
        let loadedDetail = try? await model.api.animeDetail(id: anime.id, forceRefresh: forceRefresh)
        detail = loadedDetail ?? detail
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

struct AnimePlaybackMenu: View {
    @ObservedObject var progress: PlaybackProgressStore
    let episodeIDs: Set<String>
    let isToolbarItem: Bool
    @AppStorage private var nextEpisodeLeadTime: Int
    @State private var confirmingClear = false
    @State private var editingTiming = false

    init(animeID: String, progress: PlaybackProgressStore, episodeIDs: Set<String>, isToolbarItem: Bool = false) {
        self.progress = progress
        self.episodeIDs = episodeIDs
        self.isToolbarItem = isToolbarItem
        _nextEpisodeLeadTime = AppStorage(wrappedValue: NextEpisodeTiming.defaultLeadTime, NextEpisodeTiming.storageKey(for: animeID))
    }

    var body: some View {
        Menu {
            Button("Play Next Timing", systemImage: "timer") {
                editingTiming = true
            }
            Button("Clear Resume Positions", systemImage: "clock.arrow.circlepath", role: .destructive) {
                confirmingClear = true
            }
            .disabled(episodeIDs.isDisjoint(with: progress.entries.keys))
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: isToolbarItem ? nil : 48, height: isToolbarItem ? nil : 48)
                .background {
                    if !isToolbarItem { Circle().fill(.regularMaterial) }
                }
        }
        .accessibilityLabel("More anime actions")
        .sheet(isPresented: $editingTiming) {
            NavigationStack {
                Form {
                    Section {
                        Stepper(value: $nextEpisodeLeadTime, in: 15...300, step: 15) {
                            LabeledContent("Time remaining", value: PlaybackTimeFormatter.string(Double(nextEpisodeLeadTime)))
                        }
                        Button("Reset to 2 Minutes") {
                            nextEpisodeLeadTime = NextEpisodeTiming.defaultLeadTime
                        }
                        .disabled(nextEpisodeLeadTime == NextEpisodeTiming.defaultLeadTime)
                    } footer: {
                        Text("Play Next appears this long before the end of an episode. This setting applies to this anime.")
                    }
                }
                .navigationTitle("Play Next Timing")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { editingTiming = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog("Clear resume positions for this anime?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear Resume Positions", role: .destructive) {
                progress.clear(episodeIDs: episodeIDs)
            }
        } message: {
            Text("Episodes with a saved position will start from the beginning. Watched checkmarks are kept.")
        }
    }
}

struct AnimeDetailScrollOffsetKey: PreferenceKey {
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
    @ObservedObject var library: LibraryStore
    @State private var items: [Anime] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var reloadToken = UUID()

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
                    PosterGrid {
                        ForEach(items) { related in
                            NavigationLink {
                                AnimeDetailView(anime: related, library: library)
                            } label: {
                                PosterView(anime: related)
                            }
                            .buttonStyle(.plain)
                            .libraryQuickAdd(anime: related, store: library)
                        }
                    }
                    .padding(18)
                }
            }
        }
        .safeAreaInset(edge: .top) {
            NavigationLink { WatchOrderView(anime: anime, related: items) } label: {
                HStack {
                    Label("Watch order", systemImage: "list.number").font(.headline)
                    Spacer()
                    Text("Research with Gemini").font(.caption)
                    Image(systemName: "chevron.right").font(.caption)
                }
                .frame(minHeight: 44).padding(.horizontal, 16).cloudPanel()
            }
            .buttonStyle(.plain).foregroundStyle(CloudTheme.cyan)
            .padding(.horizontal, 18).padding(.vertical, 8)
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
    var artworkHeight: CGFloat = 430
    var topInset: CGFloat = 0
    var playbackMenu: AnimePlaybackMenu?
    @ViewBuilder let actions: Actions

    var body: some View {
        ZStack(alignment: .bottom) {
            RemoteArtwork(url: cachedArtworkURL ?? anime.imageURL)
                .frame(height: artworkHeight)
                .overlay(alignment: .top) {
                    if topInset > 0 {
                        LinearGradient(colors: [.black.opacity(0.72), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: topInset + 24)
                            .allowsHitTesting(false)
                    }
                }
            LinearGradient(colors: [.clear, CloudTheme.ink.opacity(0.5), CloudTheme.ink], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 14) {
                Text(anime.name).font(.system(size: 32, weight: .black, design: .rounded)).multilineTextAlignment(.center)
                Text(anime.subtitle).font(.subheadline).foregroundStyle(CloudTheme.muted)
                actions
            }
            .padding(.horizontal, 20)
        }
        .overlay(alignment: .topTrailing) {
            if let playbackMenu { playbackMenu.padding(16) }
        }
    }
}

struct EpisodeRow: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("playback.blurUnwatchedThumbnails") private var blurUnwatchedThumbnails = false
    let anime: Anime
    let episode: Episode
    let library: LibraryStore
    @ObservedObject var progressStore: PlaybackProgressStore
    let download: EpisodeDownload?
    let onExport: (() -> Void)?
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
        onExport: (() -> Void)? = nil,
        onRemove: (() -> Void)? = nil,
        onOpen: @escaping () -> Void
    ) {
        self.anime = anime
        self.episode = episode
        self.library = library
        self.progressStore = progressStore
        self.download = download
        self.onExport = onExport
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
                if canPlay, let onExport {
                    Button("Export video", systemImage: "square.and.arrow.up", action: onExport)
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
        RemoteArtwork(
            url: episode.imageURL,
            fallbackFileURL: download.flatMap { model.downloads.artworkURL(for: $0.anime.id) },
            blurRadius: blurUnwatchedThumbnails && !displayedIsSeen ? 16 : 0
        )
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
    @State private var assetDuration: Double = 0
    @State private var timeObserver: Any?
    @State private var itemFailureObserver: NSObjectProtocol?
    @State private var endObserver: NSObjectProtocol?
    @State private var playbackStatusObserver: NSKeyValueObservation?
    @StateObject private var displaySleep = PlaybackDisplaySleepController()
    @State private var retryToken = UUID()
    @State private var showingUpNext = false
    @State private var isPlayerVisible = true
    @State private var isFullscreen = false
    @StateObject private var anime4KBenchmark = Anime4KBenchmarkController()
    @StateObject private var pictureInPicture = PlaybackPictureInPicture()
    @ObservedObject private var cast = ChromecastPlayback.shared
    @State private var playbackURL: URL?
    @AppStorage("playback.skipFillerEpisodes") private var skipFillerEpisodes = true
    @AppStorage("playback.anime4k.mode") private var anime4KModeRawValue = Anime4KPlaybackMode.off.rawValue
    @AppStorage private var nextEpisodeLeadTime: Int

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
        _nextEpisodeLeadTime = AppStorage(wrappedValue: NextEpisodeTiming.defaultLeadTime, NextEpisodeTiming.storageKey(for: anime.id))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if isCastingEpisode {
                    ChromecastPlayerPanel(cast: cast)
                } else if let player, !anime4KBenchmark.isRunning {
                    if !isFullscreen {
                        ZStack(alignment: .bottom) {
                            PlaybackSurface(player: player, mode: anime4KMode, pictureInPicture: pictureInPicture)
                                .allowsHitTesting(false)
                            PlaybackFullscreenSwipe(onSwipeDown: closePlayer) { isFullscreen = true }
                            PlaybackControls(
                                player: player,
                                assetDuration: assetDuration,
                                areVisible: true,
                                onInteraction: { _ in },
                                isFullscreen: false,
                                toggleFullscreen: { isFullscreen = true },
                                onSwipeDown: closePlayer
                            ) {
                                if !showingUpNext, let immediateNextEpisode {
                                    NextEpisodeButton(
                                        player: player,
                                        episode: immediateNextEpisode,
                                        preferredEpisode: nextEpisode,
                                        alternateEpisode: alternateNextEpisode,
                                        skippingFillers: skipFillerEpisodes,
                                        playAlternate: playAlternateNextEpisode,
                                        assetDuration: assetDuration,
                                        leadTime: nextEpisodeLeadTime,
                                        isEpisodeComplete: false,
                                        action: playNextEpisode
                                    )
                                }
                            }
                            .id(ObjectIdentifier(player))
                        }
                        .ignoresSafeArea(edges: .horizontal)
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
                if showingUpNext {
                    upNextPanel.transition(.move(edge: .bottom).combined(with: .opacity))
                } else if isCastingEpisode, let immediateNextEpisode,
                          NextEpisodeTiming.isNearEnd(position: cast.position, duration: cast.duration, leadTime: nextEpisodeLeadTime) {
                    EpisodeAdvanceButton(
                        immediateEpisode: immediateNextEpisode, preferredEpisode: nextEpisode,
                        alternateEpisode: alternateNextEpisode, skippingFillers: skipFillerEpisodes,
                        action: playNextEpisode, playAlternate: playAlternateNextEpisode
                    )
                    .padding(16)
                }
            }
            .navigationTitle(episode.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close player", systemImage: "xmark", action: closePlayer)
                        .labelStyle(.iconOnly)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isCastingEpisode {
                        ChromecastButton().frame(width: 44, height: 44)
                    } else if player != nil, !isFullscreen {
                        Menu {
                            Anime4KModeMenu(mode: anime4KMode, selectMode: selectAnime4KMode)
                            Button("Run Device Benchmark", systemImage: "gauge.with.dots.needle.67percent", action: runAnime4KBenchmark)
                        } label: {
                            Label("Video settings", systemImage: "slider.horizontal.3")
                        }
                        .labelStyle(.iconOnly)
                        PlaybackOutputControls(pictureInPicture: pictureInPicture, isEnhanced: anime4KMode.preset != nil, canCast: playbackURL?.isFileURL == false)
                        Button("Enter full screen", systemImage: "arrow.up.left.and.arrow.down.right") { isFullscreen = true }
                            .labelStyle(.iconOnly)
                    }
                }
            }
            .interactiveDismissDisabled()
            .onAppear {
                isPlayerVisible = true
                updateDisplaySleep()
            }
        }
        .overlay {
            if !isFullscreen {
                Anime4KBenchmarkOverlay(
                    controller: anime4KBenchmark,
                    applyMode: selectAnime4KMode
                )
            }
        }
        .task(id: retryToken) {
            guard player == nil else { return }
            await preparePlayback(requestID: retryToken)
        }
        .onChange(of: cast.isCasting) { _, casting in
            if casting { pictureInPicture.stop(); isFullscreen = false }
            updateDisplaySleep()
        }
        .onChange(of: cast.completedEpisodeID) { _, completedID in
            guard completedID == "\(anime.id):\(episode.id)" else { return }
            showingUpNext = true
        }
        .alert("Casting unavailable", isPresented: Binding(
            get: { cast.errorMessage != nil },
            set: { if !$0 { cast.errorMessage = nil } }
        )) {
            Button("OK") { cast.errorMessage = nil }
        } message: { Text(cast.errorMessage ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            displaySleep.update(isPlaybackActive: false, isAppActive: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            updateDisplaySleep()
        }
        .onDisappear {
            if !isFullscreen {
                isPlayerVisible = false
                displaySleep.update(isPlaybackActive: false, isAppActive: false)
            }
        }
        .fullScreenCover(isPresented: $isFullscreen) {
            FullscreenPlaybackView(
                player: $player,
                modeRawValue: $anime4KModeRawValue,
                benchmark: anime4KBenchmark,
                pictureInPicture: pictureInPicture,
                isPresented: $isFullscreen,
                animeName: anime.name,
                episodes: episodes,
                episode: $episode,
                assetDuration: $assetDuration,
                nextEpisodeLeadTime: $nextEpisodeLeadTime,
                isEpisodeComplete: $showingUpNext,
                playNext: playNextEpisode,
                playAlternate: playAlternateNextEpisode,
                error: $error,
                retry: { retryToken = UUID() }
            )
        }
    }

    private var isCastingEpisode: Bool {
        (cast.isCasting || cast.isLoading) && cast.currentEpisodeID == "\(anime.id):\(episode.id)"
    }

    private var anime4KMode: Anime4KPlaybackMode {
        Anime4KPlaybackMode(rawValue: anime4KModeRawValue) ?? .off
    }

    private func selectAnime4KMode(_ mode: Anime4KPlaybackMode) {
        anime4KModeRawValue = mode.rawValue
    }

    private func runAnime4KBenchmark() {
        guard let player else { return }
        anime4KBenchmark.start(player: player)
    }

    private func closePlayer() {
        anime4KBenchmark.cancel()
        pictureInPicture.stop()
        isFullscreen = false
        isPlayerVisible = false
        tearDownPlayer()
        dismiss()
    }

    private func preparePlayback(requestID: UUID) async {
        guard requestIsCurrent(requestID) else { return }
        tearDownPlayer(deactivateAudio: false)
        error = nil
        assetDuration = 0
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
            guard requestIsCurrent(requestID) else { return }
            playbackURL = url
            let asset = AVURLAsset(url: url)
            async let loadedDuration = try? asset.load(.duration)
            guard try await asset.load(.isPlayable) else { throw PlaybackPresentationError.notPlayable }
            let seconds = await loadedDuration?.seconds ?? 0
            guard requestIsCurrent(requestID) else { return }
            assetDuration = seconds.isFinite ? seconds : 0

            let item = AVPlayerItem(asset: asset)
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.automaticallyWaitsToMinimizeStalling = true
            player = newPlayer
            playbackStatusObserver = newPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { observedPlayer, _ in
                Task { @MainActor in
                    guard self.player === observedPlayer else { return }
                    updateDisplaySleep()
                }
            }
            installFailureObserver(for: item)
            installEndObserver(for: item)
            installProgressObserver(on: newPlayer)

            if let saved = progressStore.progress(for: episode.id), saved.position >= 3 {
                let resumeTime = CMTime(seconds: saved.position, preferredTimescale: 600)
                await newPlayer.seek(to: resumeTime, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            guard requestIsCurrent(requestID) else {
                if player === newPlayer { tearDownPlayer() }
                return
            }
            newPlayer.play()
            let playingEpisode = episode
            let statusEpisodes = episodesForWatchStatus
            cast.attach(player: newPlayer, episode: CastEpisode(anime: anime, episode: playingEpisode, url: url, duration: assetDuration)) {
                [progressStore, library, anime] position, duration in
                progressStore.save(episodeID: playingEpisode.id, position: position, duration: duration)
                library.recordPlayback(of: playingEpisode, anime: anime, episodes: statusEpisodes, position: position, duration: duration)
            } onComplete: { [progressStore, library, anime] in
                progressStore.clear(episodeID: playingEpisode.id)
                library.completePlayback(of: playingEpisode, anime: anime, episodes: statusEpisodes)
            }
        } catch is CancellationError {
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
            if let immediateNextEpisode {
                Text("Up next").font(.title2.bold())
                Text((nextEpisode ?? immediateNextEpisode).name).font(.headline).foregroundStyle(.white.opacity(0.78))
                HStack(spacing: 10) {
                    Spacer()
                    EpisodeTypeBadge(episode: nextEpisode ?? immediateNextEpisode)
                    EpisodeAdvanceButton(
                        immediateEpisode: immediateNextEpisode, preferredEpisode: nextEpisode,
                        alternateEpisode: alternateNextEpisode,
                        skippingFillers: skipFillerEpisodes,
                        action: playNextEpisode, playAlternate: playAlternateNextEpisode
                    )
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

    private var immediateNextEpisode: Episode? { episodes.nextEpisode(after: episode) }
    private var nextEpisode: Episode? { episodes.nextEpisode(after: episode, skippingFillers: skipFillerEpisodes) }
    private var alternateNextEpisode: Episode? { episodes.nextEpisode(after: episode, skippingFillers: !skipFillerEpisodes) }

    private var episodesForWatchStatus: [Episode] {
        guard downloadedPlayback else { return episodes }
        return model.downloads.records[episode.id]?.finalCanonEpisode.map { [$0] } ?? []
    }

    private func playNextEpisode() {
        guard let nextEpisode else { return }
        playEpisode(nextEpisode)
    }

    private func playAlternateNextEpisode() {
        guard let alternateNextEpisode else { return }
        playEpisode(alternateNextEpisode)
    }

    private func playEpisode(_ nextEpisode: Episode) {
        guard player != nil else { return }
        tearDownPlayer(deactivateAudio: false)
        if !showingUpNext {
            progressStore.clear(episodeID: episode.id)
            library.completePlayback(of: episode, anime: anime, episodes: episodesForWatchStatus)
        }
        episode = nextEpisode
        showingUpNext = false
        retryToken = UUID()
    }

    private func replayEpisode() {
        progressStore.clear(episodeID: episode.id)
        showingUpNext = false
        if isCastingEpisode {
            cast.replay()
        } else if let player {
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
                guard isPlayerVisible, player?.currentItem === item else { return }
                self.error = playbackMessage(for: underlying ?? item.error ?? PlaybackPresentationError.notPlayable)
                tearDownPlayer(deactivateAudio: false)
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
                guard isPlayerVisible, player?.currentItem === item else { return }
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
                guard isPlayerVisible, self.player === player, !showingUpNext, !isCastingEpisode else { return }
                progressStore.save(episodeID: observedEpisode.id, position: position, duration: duration)
                library.recordPlayback(of: observedEpisode, anime: anime, episodes: episodesForWatchStatus, position: position, duration: duration)
            }
        }
    }

    private func tearDownPlayer(deactivateAudio: Bool = true) {
        playbackStatusObserver = nil
        displaySleep.update(isPlaybackActive: false, isAppActive: false)
        if let player {
            let duration = player.currentItem?.duration.seconds ?? 0
            let position = player.currentTime().seconds
            if !showingUpNext, !isCastingEpisode {
                progressStore.save(episodeID: episode.id, position: position, duration: duration)
                library.recordPlayback(of: episode, anime: anime, episodes: episodesForWatchStatus, position: position, duration: duration)
            }
            cast.detach(player: player)
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

    private func updateDisplaySleep() {
        displaySleep.update(
            isPlaybackActive: isPlayerVisible && player != nil && player?.timeControlStatus != .paused && !isCastingEpisode,
            isAppActive: UIApplication.shared.applicationState == .active
        )
    }

    private func playbackMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorAppTransportSecurityRequiresSecureConnection {
            return "This older episode uses an insecure media URL that iOS blocked. Try again after updating the app."
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

@MainActor
final class PlaybackDisplaySleepController: ObservableObject {
    private var previousIdleTimerDisabled: Bool?

    func update(isPlaybackActive: Bool, isAppActive: Bool) {
        if isPlaybackActive && isAppActive {
            if previousIdleTimerDisabled == nil {
                previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            }
            UIApplication.shared.isIdleTimerDisabled = true
        } else if let previousIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
            self.previousIdleTimerDisabled = nil
        }
    }
}

private struct FullscreenPlaybackView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var player: AVPlayer?
    @Binding var modeRawValue: String
    @ObservedObject private var cast = ChromecastPlayback.shared
    @ObservedObject var benchmark: Anime4KBenchmarkController
    let pictureInPicture: PlaybackPictureInPicture
    @Binding var isPresented: Bool
    let animeName: String
    let episodes: [Episode]
    @Binding var episode: Episode
    @Binding var assetDuration: Double
    @Binding var nextEpisodeLeadTime: Int
    @Binding var isEpisodeComplete: Bool
    let playNext: () -> Void
    let playAlternate: () -> Void
    @AppStorage("playback.skipFillerEpisodes") private var skipFillerEpisodes = true
    @Binding var error: String?
    let retry: () -> Void
    @State private var controlsAreVisible = true
    @State private var controlHideTask: Task<Void, Never>?
    @State private var startingLevel: Double?
    @State private var level: Double?
    @State private var levelControl: PlayerGestureZone = .volume
    @State private var levelHideTask: Task<Void, Never>?
    @State private var hardwareVolume: Double?
    @State private var hardwareVolumeHideTask: Task<Void, Never>?
    @State private var lastVolumeGestureAt = Date.distantPast
    @State private var systemVolumeView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 120, height: 44))

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            if cast.isLoading || cast.isCasting {
                ChromecastPlayerPanel(cast: cast)
            } else if let player, !benchmark.isRunning {
                PlaybackSurface(player: player, mode: mode, pictureInPicture: pictureInPicture)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
            if !benchmark.isRunning && benchmark.report == nil && !cast.isLoading && !cast.isCasting {
                GeometryReader { geometry in
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { toggleControls() }
                        .gesture(playbackGesture(size: geometry.size))
                        .onChange(of: PlayerGestureZone.allowsLevelAdjustment(in: geometry.size)) { _, allowed in
                            if !allowed {
                                startingLevel = nil
                                levelHideTask?.cancel()
                                level = nil
                            }
                        }
                }
                if let player {
                    PlaybackControls(
                        player: player,
                        assetDuration: assetDuration,
                        areVisible: controlsAreVisible,
                        onInteraction: scheduleControlFade,
                        isFullscreen: true,
                        toggleFullscreen: { isPresented = false }
                    ) {
                        if let nextEpisode = episodes.nextEpisode(after: episode) {
                            NextEpisodeButton(
                                player: player,
                                episode: nextEpisode,
                                preferredEpisode: episodes.nextEpisode(after: episode, skippingFillers: skipFillerEpisodes),
                                alternateEpisode: episodes.nextEpisode(after: episode, skippingFillers: !skipFillerEpisodes),
                                skippingFillers: skipFillerEpisodes,
                                playAlternate: playAlternate,
                                assetDuration: assetDuration,
                                leadTime: nextEpisodeLeadTime,
                                isEpisodeComplete: isEpisodeComplete,
                                action: playNext
                            )
                        }
                    }
                    .id(ObjectIdentifier(player))
                    if let level {
                        levelIndicator(level, control: levelControl)
                    } else if let hardwareVolume {
                        levelIndicator(hardwareVolume, control: .volume)
                    }
                } else {
                    VStack(spacing: 16) {
                        if let error {
                            Text(error).multilineTextAlignment(.center)
                            Button("Try Again", action: retry)
                                .buttonStyle(.borderedProminent)
                        } else {
                            ProgressView("Loading episode…")
                        }
                        Button("Exit Full Screen") { isPresented = false }
                            .buttonStyle(.bordered)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Anime4KBenchmarkOverlay(
                controller: benchmark,
                applyMode: selectMode
            )
        }
        .background {
            // Keep the system volume slider attached while gestures drive it.
            PlayerSystemVolumeControl(volumeView: systemVolumeView)
                .frame(width: 120, height: 44)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .top) {
            if let player, controlsAreVisible, !benchmark.isRunning, benchmark.report == nil {
                HStack {
                    Button { benchmark.start(player: player) } label: {
                        Image(systemName: "gauge.with.dots.needle.67percent")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Run Device Benchmark")
                    .background(.regularMaterial, in: Circle())

                    VStack(spacing: 3) {
                        Text(animeName).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(episode.name).font(.caption).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 8)
                    .shadow(color: .black, radius: 4)

                    HStack(spacing: 6) {
                        PlaybackOutputControls(pictureInPicture: pictureInPicture, isEnhanced: mode.preset != nil, canCast: (player.currentItem?.asset as? AVURLAsset)?.url.isFileURL == false)
                        Anime4KModeMenu(mode: mode, selectMode: selectMode)
                        Button { isPresented = false } label: {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Exit full screen")
                    }
                    .background(.regularMaterial, in: Capsule())
                }
                .foregroundStyle(.white)
                .buttonStyle(.plain)
                .padding(16)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: controlsAreVisible)
        .onChange(of: isEpisodeComplete) { _, complete in
            if complete {
                controlHideTask?.cancel()
                controlsAreVisible = true
            }
        }
        .onReceive(AVAudioSession.sharedInstance().publisher(for: \.outputVolume).dropFirst().receive(on: RunLoop.main)) { volume in
            guard startingLevel == nil, Date().timeIntervalSince(lastVolumeGestureAt) > 0.3,
                  player != nil, !benchmark.isRunning, benchmark.report == nil else { return }
            hardwareVolumeHideTask?.cancel()
            hardwareVolume = Double(volume)
            hardwareVolumeHideTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                hardwareVolume = nil
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            PlaybackOrientation.request(.landscape)
            scheduleControlFade()
        }
        .onDisappear {
            controlHideTask?.cancel()
            levelHideTask?.cancel()
            hardwareVolumeHideTask?.cancel()
            PlaybackOrientation.request(.portrait)
        }
    }

    private var mode: Anime4KPlaybackMode {
        Anime4KPlaybackMode(rawValue: modeRawValue) ?? .off
    }

    private func selectMode(_ mode: Anime4KPlaybackMode) {
        modeRawValue = mode.rawValue
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

    private func scheduleControlFade(whileScrubbing: Bool = false) {
        controlHideTask?.cancel()
        guard controlsAreVisible, !whileScrubbing, player?.timeControlStatus == .playing else { return }
        controlHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, player?.timeControlStatus == .playing else { return }
            controlsAreVisible = false
        }
    }

    private func exitOnCenterSwipe(_ translation: CGSize) {
        if PlayerFullscreenGesture.action(for: translation, isFullscreen: true) == .exit {
            isPresented = false
        }
    }

    private func playbackGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                guard PlayerGestureZone.allowsLevelAdjustment(in: size), player != nil else { return }
                let zone = PlayerGestureZone.at(value.startLocation.x, width: size.width)
                guard zone != .center,
                      startingLevel != nil || PlayerFullscreenGesture.isVertical(value.translation)
                else { return }
                let screen = PlaybackOrientation.activeScene?.screen
                if zone == .brightness && screen == nil { return }
                let volumeSlider = systemVolumeView.subviews.compactMap { $0 as? UISlider }.first
                if zone == .volume && volumeSlider?.isEnabled != true { return }
                let currentLevel = zone == .brightness ? Double(screen?.brightness ?? 0) : Double(AVAudioSession.sharedInstance().outputVolume)
                let initialLevel = startingLevel ?? currentLevel
                startingLevel = initialLevel
                let adjusted = min(max(initialLevel - Double(value.translation.height / max(1, size.height * 0.75)), 0), 1)
                if zone == .brightness {
                    screen?.brightness = CGFloat(adjusted)
                } else {
                    lastVolumeGestureAt = Date()
                    hardwareVolumeHideTask?.cancel()
                    hardwareVolume = nil
                    volumeSlider?.setValue(Float(adjusted), animated: false)
                    volumeSlider?.sendActions(for: .valueChanged)
                }
                levelHideTask?.cancel()
                levelControl = zone
                level = adjusted
                levelHideTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    level = nil
                }
            }
            .onEnded { value in
                startingLevel = nil
                if PlayerGestureZone.at(value.startLocation.x, width: size.width) == .center {
                    exitOnCenterSwipe(value.translation)
                }
            }
    }

    private func levelIndicator(_ level: Double, control: PlayerGestureZone) -> some View {
        let isBrightness = control == .brightness
        return VStack(spacing: 10) {
            Image(systemName: isBrightness ? "sun.max.fill" : level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
            ZStack(alignment: .bottom) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white).frame(height: 100 * level)
            }
            .frame(width: 6, height: 100)
        }
        .font(.caption)
        .foregroundStyle(.white)
        .padding(14)
        .background(.black.opacity(0.85), in: Capsule())
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isBrightness ? .trailing : .leading)
        .environment(\.layoutDirection, .leftToRight)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isBrightness ? "Brightness" : "System volume")
        .accessibilityValue(Text(level, format: .percent.precision(.fractionLength(0))))
    }
}

private struct PlayerSystemVolumeControl: UIViewRepresentable {
    let volumeView: MPVolumeView

    func makeUIView(context: Context) -> MPVolumeView {
        volumeView
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

private struct EpisodeAdvanceButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let immediateEpisode: Episode
    let preferredEpisode: Episode?
    let alternateEpisode: Episode?
    let skippingFillers: Bool
    let action: () -> Void
    let playAlternate: () -> Void
    @State private var isPressing = false
    @State private var holdProgress = 0.0
    private let holdDuration = 0.65

    private var fillerHint: String {
        if (skippingFillers ? preferredEpisode : alternateEpisode)?.isFiller == true {
            return "Only filler remaining · Plays next episode"
        }
        return skippingFillers ? "Skipping filler · Hold to watch" : "Next is filler · Hold to skip"
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            advanceButton
                .onChange(of: isPressing) { _, pressing in
                    withAnimation(pressing && !reduceMotion ? .linear(duration: holdDuration) : nil) {
                        holdProgress = pressing ? 1 : 0
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Play Next")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { action() }
                .accessibilityHint(preferredEpisode.map { Text($0.name) } ?? Text("Only filler episodes remain"))
                .accessibilityActions {
                    if let alternateEpisode {
                        Button(skippingFillers ? "Play next including filler" : "Play next non-filler episode", action: playAlternate)
                            .accessibilityHint(alternateEpisode.name)
                    }
                }
            if immediateEpisode.isFiller {
                Text(fillerHint)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.8), in: Capsule())
            }
        }
    }

    private var advanceButton: some View {
        Label("Play Next", systemImage: "forward.fill")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(immediateEpisode.isFiller ? Color.orange : .white, in: Capsule())
            .foregroundStyle(.black)
            .opacity(isPressing ? 0.7 : 1)
            .overlay {
                Capsule()
                    .trim(from: 0, to: holdProgress)
                    .stroke(.black.opacity(0.7), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .padding(3)
                    .allowsHitTesting(false)
            }
            .overlay {
                EpisodeAdvanceTouchControl(
                    holdDuration: holdDuration,
                    tap: action,
                    hold: playAlternateIfAvailable,
                    pressed: { isPressing = $0 }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
            }
    }

    private func playAlternateIfAvailable() {
        if alternateEpisode != nil { playAlternate() }
    }
}

private struct EpisodeAdvanceTouchControl: UIViewRepresentable {
    let holdDuration: TimeInterval
    let tap: () -> Void
    let hold: () -> Void
    let pressed: (Bool) -> Void

    func makeUIView(context: Context) -> EpisodeAdvanceControl {
        EpisodeAdvanceControl(holdDuration: holdDuration)
    }

    func updateUIView(_ control: EpisodeAdvanceControl, context: Context) {
        control.onTap = tap
        control.onHold = hold
        control.onPressChanged = pressed
    }

    static func dismantleUIView(_ control: EpisodeAdvanceControl, coordinator: ()) {
        control.cancelPress()
    }
}

// A single touch handler keeps taps, holds, and cancellation mutually exclusive.
final class EpisodeAdvanceControl: UIControl {
    var onTap: () -> Void = {}
    var onHold: () -> Void = {}
    var onPressChanged: (Bool) -> Void = { _ in }
    private let holdDuration: TimeInterval
    private var holdTask: Task<Void, Never>?
    private var pressIsActive = false
    private var didHold = false

    init(holdDuration: TimeInterval) {
        self.holdDuration = holdDuration
        super.init(frame: .zero)
        addTarget(self, action: #selector(beginPress), for: .touchDown)
        addTarget(self, action: #selector(releasePress), for: .touchUpInside)
        addTarget(self, action: #selector(cancelPress), for: [.touchUpOutside, .touchCancel, .touchDragExit])
    }

    required init?(coder: NSCoder) { nil }

    @objc private func beginPress() {
        cancelPress()
        pressIsActive = true
        didHold = false
        onPressChanged(true)
        holdTask = Task { @MainActor [weak self, holdDuration] in
            try? await Task.sleep(for: .seconds(holdDuration))
            guard !Task.isCancelled, let self, self.pressIsActive else { return }
            self.didHold = true
            self.onHold()
        }
    }

    @objc private func releasePress() {
        guard pressIsActive else { return }
        let shouldTap = !didHold
        cancelPress()
        if shouldTap { onTap() }
    }

    @objc func cancelPress() {
        holdTask?.cancel()
        holdTask = nil
        guard pressIsActive else { return }
        pressIsActive = false
        onPressChanged(false)
    }

    deinit { holdTask?.cancel() }
}

private struct NextEpisodeButton: View {
    let player: AVPlayer
    let episode: Episode
    let preferredEpisode: Episode?
    let alternateEpisode: Episode?
    let skippingFillers: Bool
    let playAlternate: () -> Void
    let assetDuration: Double
    let leadTime: Int
    let isEpisodeComplete: Bool
    let action: () -> Void
    @State private var isNearEnd = false
    @State private var timeObserver: Any?

    var body: some View {
        ZStack {
            Color.clear.frame(width: 0, height: 0).allowsHitTesting(false)
            if isEpisodeComplete || isNearEnd {
                EpisodeAdvanceButton(
                    immediateEpisode: episode, preferredEpisode: preferredEpisode,
                    alternateEpisode: alternateEpisode,
                    skippingFillers: skippingFillers,
                    action: action, playAlternate: playAlternate
                )
            }
        }
        .onAppear {
            guard timeObserver == nil else { return }
            updateVisibility(at: player.currentTime().seconds)
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                queue: .main
            ) { time in
                updateVisibility(at: time.seconds)
            }
        }
        .onDisappear {
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            timeObserver = nil
        }
        .onChange(of: leadTime) { _, _ in
            updateVisibility(at: player.currentTime().seconds)
        }
    }

    private func updateVisibility(at position: Double) {
        let itemDuration = player.currentItem?.duration.seconds ?? 0
        let duration = itemDuration.isFinite && itemDuration > 0 ? itemDuration : assetDuration
        let shouldShow = NextEpisodeTiming.isNearEnd(position: position, duration: duration, leadTime: leadTime)
        if isNearEnd != shouldShow { isNearEnd = shouldShow }
    }
}

enum NextEpisodeTiming {
    static let defaultLeadTime = 120

    static func storageKey(for animeID: String) -> String {
        "playback.nextEpisodeLeadTime.\(animeID)"
    }

    static func isNearEnd(position: Double, duration: Double, leadTime: Int = defaultLeadTime) -> Bool {
        guard position.isFinite, duration.isFinite, duration > 0 else { return false }
        let start = Double(leadTime) < duration ? duration - Double(leadTime) : duration * 0.5
        return position >= start
    }
}

enum PlayerGestureZone {
    case volume, center, brightness

    static func allowsLevelAdjustment(in size: CGSize) -> Bool {
        size.width > size.height
    }

    static func at(_ x: CGFloat, width: CGFloat) -> Self {
        if x < width / 3 { return .volume }
        if x > width * 2 / 3 { return .brightness }
        return .center
    }
}

enum PlayerFullscreenGestureAction: Equatable {
    case enter
    case exit
}

enum PlayerFullscreenGesture {
    static func isVertical(_ translation: CGSize) -> Bool {
        abs(translation.height) > abs(translation.width) * 1.25
    }

    static func action(for translation: CGSize, isFullscreen: Bool) -> PlayerFullscreenGestureAction? {
        guard abs(translation.height) >= 70,
              isVertical(translation)
        else { return nil }
        if translation.height < 0, !isFullscreen { return .enter }
        if translation.height > 0, isFullscreen { return .exit }
        return nil
    }
}

struct PlaybackFullscreenSwipe: UIViewRepresentable {
    var isFullscreen = false
    var onTap: (() -> Void)?
    var onSwipeDown: (() -> Void)?
    let toggleFullscreen: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let swipe = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swiped))
        swipe.maximumNumberOfTouches = 1
        swipe.delegate = context.coordinator
        view.addGestureRecognizer(swipe)
        if onTap != nil {
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
            tap.require(toFail: swipe)
            view.addGestureRecognizer(tap)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PlaybackFullscreenSwipe

        init(parent: PlaybackFullscreenSwipe) {
            self.parent = parent
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let swipe = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = swipe.velocity(in: swipe.view)
            let supportsDirection = velocity.y > 0 ? parent.isFullscreen || parent.onSwipeDown != nil : !parent.isFullscreen
            return supportsDirection && PlayerFullscreenGesture.isVertical(CGSize(width: velocity.x, height: velocity.y))
        }

        @objc func swiped(_ swipe: UIPanGestureRecognizer) {
            guard swipe.state == .ended else { return }
            let distance = swipe.translation(in: swipe.view)
            let translation = CGSize(width: distance.x, height: distance.y)
            if PlayerFullscreenGesture.action(for: translation, isFullscreen: parent.isFullscreen) != nil {
                parent.toggleFullscreen()
            } else if PlayerFullscreenGesture.action(for: translation, isFullscreen: true) == .exit {
                parent.onSwipeDown?()
            }
        }

        @objc func tapped() { parent.onTap?() }
    }
}

private enum PlaybackOrientation {
    @MainActor
    static var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        return scenes.first { $0.windows.contains(where: \.isKeyWindow) } ?? scenes.first
    }

    @MainActor
    static func request(_ orientations: UIInterfaceOrientationMask) {
        guard UIDevice.current.userInterfaceIdiom == .phone,
              let scene = activeScene
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
