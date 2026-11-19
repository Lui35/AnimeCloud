import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var library: LibraryStore
    @State private var recommendation: HomePlayback?
    @State private var playing: HomePlayback?
    @State private var recommendationRevision = 0

    var body: some View {
        NavigationStack {
            ZStack {
                CloudBackground()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        header
                        if let recommendation, !library.isSeen(recommendation.episode) {
                            ContinueWatchingCard(playback: recommendation, library: library) { playing = recommendation }
                        } else if model.isBootstrapping && model.featured.isEmpty {
                            ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
                        }
                        if !library.recentAnime.isEmpty { posterRail(title: "Continue exploring", items: library.recentAnime) }
                        if !model.featured.isEmpty { posterRail(title: "Trending in the cloud", items: model.featured) }
                        if !model.newlyAddedEpisodes.isEmpty { newEpisodesRail }
                    }
                    .padding(.bottom, 110)
                }
                .refreshable {
                    await model.refresh()
                    recommendationRevision += 1
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Anime.self) { anime in AnimeDetailView(anime: anime, library: library) }
            .task(id: RecommendationRequest(candidates: continuationCandidates, revision: recommendationRevision)) {
                await loadRecommendation()
            }
            .onReceive(library.seenStatusChanged) { _ in
                if playing == nil { recommendationRevision += 1 }
            }
            .sheet(item: $playing, onDismiss: { recommendationRevision += 1 }) { playback in
                PlayerSheet(
                    anime: playback.anime,
                    initialEpisode: playback.episode,
                    episodes: playback.episodes,
                    library: library,
                    progressStore: model.playbackProgress,
                    downloadedPlayback: playback.isOffline
                )
            }
        }
    }

    private var continuationCandidates: [Anime] {
        let saved = library.favorites.filter { library.category(for: $0) == .watchingNow }
        let recentlyOpened = model.playbackProgress.entries.isEmpty ? [] : library.recentAnime
        var included: Set<String> = []
        return (library.recentlyPlayedAnime + saved + recentlyOpened).filter {
            library.category(for: $0) != .watched && included.insert($0.id).inserted
        }
    }

    private func loadRecommendation() async {
        let playedIDs = Set(library.recentlyPlayedAnime.map(\.id))
        for anime in continuationCandidates {
            let detail = try? await model.api.animeDetail(id: anime.id)
            guard !Task.isCancelled else { return }
            let episodes = detail?.episodes ?? model.downloads.records.values
                .filter { $0.anime.id == anime.id && model.downloads.localURL(for: $0.id) != nil }
                .sorted { ($0.catalogPosition, $0.id) < ($1.catalogPosition, $1.id) }
                .map(\.episode)

            if detail != nil { model.applyAniListProgress(to: anime, episodes: episodes) }
            let hasPlayback = playedIDs.contains(anime.id) || library.category(for: anime) == .watchingNow ||
                episodes.contains { model.playbackProgress.progress(for: $0.id) != nil }
            if hasPlayback, let episode = model.playbackProgress.episodeToContinue(in: episodes, library: library) {
                recommendation = HomePlayback(anime: anime, episode: episode, episodes: episodes, isOffline: detail == nil)
                return
            }
        }
        recommendation = nil
    }

    private var header: some View {
        HStack(spacing: 12) {
            CloudLogo()
            VStack(alignment: .leading, spacing: 1) {
                Text("ANIME CLOUD").font(.caption.weight(.black)).tracking(2.1).foregroundStyle(CloudTheme.cyan)
                Text(greeting).font(.title2.bold())
            }
            Spacer()
            Image(systemName: "bell.badge.fill").font(.title3).foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var greeting: String {
        if let name = model.session?.username, !name.isEmpty { return "Welcome back, \(name)" }
        return "Your next world awaits"
    }

    private func posterRail(title: String, items: [Anime]) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            SectionHeading(title: title).padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { anime in
                        NavigationLink(value: anime) { PosterView(anime: anime, width: 142) }
                            .buttonStyle(.plain)
                            .libraryQuickAdd(anime: anime, store: library)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var newEpisodesRail: some View {
        VStack(alignment: .leading, spacing: 15) {
            SectionHeading(title: "New episodes", subtitle: "Freshly added to Anime Cloud")
                .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(model.newlyAddedEpisodes) { anime in
                        NavigationLink(value: anime) { NewEpisodeCard(anime: anime) }
                            .buttonStyle(.plain)
                            .libraryQuickAdd(anime: anime, store: library)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

}

private struct NewEpisodeCard: View {
    let anime: Anime

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            RemoteArtwork(url: anime.imageURL)
                .frame(width: 158, height: 218)
                .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                .accessibilityHidden(true)
                .overlay(alignment: .bottomLeading) {
                    if let episode = anime.latestEpisodeName, !episode.isEmpty {
                        Text(episode)
                            .font(.caption.weight(.black))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(10)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 19).stroke(CloudTheme.cyan.opacity(0.24), lineWidth: 1)
                }
            Text(anime.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2, reservesSpace: true)
                .frame(width: 158, alignment: .leading)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the anime preview")
    }
}

private struct RecommendationRequest: Equatable {
    let candidates: [Anime]
    let revision: Int
}

private struct HomePlayback: Identifiable {
    let anime: Anime
    let episode: Episode
    let episodes: [Episode]
    let isOffline: Bool

    var id: String { episode.id }
}

private struct ContinueWatchingCard: View {
    let playback: HomePlayback
    @ObservedObject var library: LibraryStore
    let play: () -> Void

    private var anime: Anime { playback.anime }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteArtwork(url: anime.imageURL).frame(height: 440)
            LinearGradient(colors: [.clear, CloudTheme.ink.opacity(0.28), CloudTheme.ink], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 12) {
                Text("CONTINUE WATCHING").font(.caption.weight(.black)).tracking(1.8).foregroundStyle(CloudTheme.cyan)
                Text(anime.name).font(.system(size: 34, weight: .black, design: .rounded)).lineLimit(3)
                Text(playback.episode.name).font(.subheadline).foregroundStyle(.white.opacity(0.78))
                HStack {
                    Button(action: play) {
                        Label("Play", systemImage: "play.fill").font(.headline).padding(.horizontal, 18).padding(.vertical, 12).background(.white, in: Capsule()).foregroundStyle(CloudTheme.ink)
                    }
                    .buttonStyle(.plain)
                    LibrarySaveMenu(anime: anime, store: library, size: 44)
                }
            }
            .padding(24)
        }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 30).stroke(Color.white.opacity(0.1)) }
        .padding(.horizontal, 16)
    }
}
