import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: LibraryStore
    let isActive: Bool
    @AppStorage("library.defaultCategory") private var defaultCategory: LibraryCategory = .watchingNow
    @State private var selection: LibraryCategory = .watchingNow

    private let columns = [GridItem(.adaptive(minimum: 145), spacing: 16)]
    private let categories: [LibraryCategory] = [.watchingNow, .watchLater, .watched, .favorites]

    var body: some View {
        NavigationStack {
            ZStack {
                CloudBackground()
                VStack(spacing: 16) {
                    NavigationLink {
                        DownloadsView(downloads: model.downloads)
                    } label: {
                        HStack {
                            Label("Downloads", systemImage: "arrow.down.circle")
                                .font(.headline)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(CloudTheme.cyan)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 48)
                        .cloudPanel()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 18)
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
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(categories) { category in
                        categoryButton(category).id(category)
                    }
                }
                .padding(.horizontal, 18)
            }
            .onChange(of: isActive, initial: true) { _, active in
                guard active else { return }
                selection = defaultCategory
                proxy.scrollTo(defaultCategory)
            }
        }
    }

    private func categoryButton(_ category: LibraryCategory) -> some View {
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
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Capsule())
            .background(selection == category ? AnyShapeStyle(CloudTheme.heroGradient) : AnyShapeStyle(CloudTheme.panel), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == category ? .isSelected : [])
        .contextMenu {
            if category == defaultCategory {
                Button("Default category", systemImage: "checkmark") {}
                    .disabled(true)
            } else {
                Button("Mark as Default", systemImage: "star") {
                    defaultCategory = category
                    selection = category
                }
            }
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
