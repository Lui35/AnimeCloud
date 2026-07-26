import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            ZStack {
                CloudBackground()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        header
                        if model.isBootstrapping && model.featured.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(.top, 120) }
                        else if let hero = model.featured.first { HeroCard(anime: hero, library: model.library) }
                        if !model.featured.isEmpty { posterRail(title: "Trending in the cloud", items: Array(model.featured.dropFirst())) }
                        if !model.library.recentAnime.isEmpty { posterRail(title: "Continue exploring", items: model.library.recentAnime) }
                        if !model.news.isEmpty { newsRail }
                    }
                    .padding(.bottom, 110)
                }
                .refreshable { await model.refresh() }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Anime.self) { anime in AnimeDetailView(anime: anime, library: model.library) }
        }
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
                    ForEach(items) { anime in NavigationLink(value: anime) { PosterView(anime: anime) }.buttonStyle(.plain) }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var newsRail: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "Cloud bulletin", subtitle: "Updates from Anime Cloud").padding(.horizontal, 20)
            ForEach(model.news.prefix(3)) { item in
                HStack(spacing: 14) {
                    RemoteArtwork(url: item.imageURL).frame(width: 74, height: 74).clipShape(RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.title).font(.headline).lineLimit(2)
                        Text(item.content?.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) ?? "Latest Anime Cloud update")
                            .font(.caption).foregroundStyle(CloudTheme.muted).lineLimit(2)
                    }
                    Spacer()
                }
                .padding(12)
                .cloudPanel()
                .padding(.horizontal, 20)
            }
        }
    }
}

private struct HeroCard: View {
    let anime: Anime
    @ObservedObject var library: LibraryStore

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteArtwork(url: anime.imageURL).frame(height: 440)
            LinearGradient(colors: [.clear, CloudTheme.ink.opacity(0.28), CloudTheme.ink], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 12) {
                Text("FEATURED NOW").font(.caption.weight(.black)).tracking(1.8).foregroundStyle(CloudTheme.cyan)
                Text(anime.name).font(.system(size: 34, weight: .black, design: .rounded)).lineLimit(3)
                Text(anime.subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.78))
                HStack {
                    NavigationLink(value: anime) {
                        Label("Explore", systemImage: "play.fill").font(.headline).padding(.horizontal, 18).padding(.vertical, 12).background(.white, in: Capsule()).foregroundStyle(CloudTheme.ink)
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
