import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: LibraryStore
    @State private var selection: LibraryCategory = .favorites

    private let columns = [GridItem(.adaptive(minimum: 145), spacing: 16)]

    var body: some View {
        NavigationStack {
            ZStack {
                CloudBackground()
                VStack(spacing: 16) {
                    categorySelector
                    if items.isEmpty {
                        EmptyCloud(title: emptyTitle, detail: emptyDetail, systemImage: selection.icon)
                    } else {
                        ScrollView {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                                ForEach(items) { anime in NavigationLink(value: anime) { PosterView(anime: anime, width: 154, height: 220) }.buttonStyle(.plain) }
                            }.padding(18).padding(.bottom, 100)
                        }
                    }
                }
            }
            .navigationTitle("Your library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await model.syncBackup() } } label: {
                        if model.isCloudSyncing { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.triangle.2.circlepath.icloud") }
                    }
                    .disabled(model.isCloudSyncing)
                    .accessibilityLabel("Sync library now")
                }
            }
            .navigationDestination(for: Anime.self) { AnimeDetailView(anime: $0, library: store) }
        }
    }

    private var categorySelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(LibraryCategory.allCases) { category in
                    Button { withAnimation(.easeInOut(duration: 0.2)) { selection = category } } label: {
                        HStack(spacing: 7) {
                            Image(systemName: category.icon)
                            Text(category.title)
                            Text(String(count(for: category)))
                                .font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Color.white.opacity(0.12), in: Capsule())
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 13).padding(.vertical, 10)
                        .background(selection == category ? AnyShapeStyle(CloudTheme.heroGradient) : AnyShapeStyle(CloudTheme.panel), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
        }
    }

    private var items: [Anime] {
        store.favorites.filter { store.category(for: $0) == selection }
    }

    private func count(for category: LibraryCategory) -> Int {
        store.favorites.count { store.category(for: $0) == category }
    }

    private var emptyTitle: String {
        switch selection {
        case .favorites: "Save what moves you"
        case .watched: "Nothing marked watched"
        case .watchLater: "Your watchlist is clear"
        case .watchingNow: "Choose your current series"
        }
    }

    private var emptyDetail: String {
        switch selection {
        case .favorites: "Use the library button on any anime and choose Favorites."
        case .watched: "Series you have completed can be kept here."
        case .watchLater: "Add anime you want to return to later."
        case .watchingNow: "Keep the shows you are actively following close."
        }
    }
}
