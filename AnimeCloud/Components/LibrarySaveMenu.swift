import SwiftUI

struct LibrarySaveMenu: View {
    let anime: Anime
    @ObservedObject var store: LibraryStore
    var size: CGFloat = 46

    var body: some View {
        Menu {
            LibraryCategoryActions(anime: anime, store: store)
        } label: {
            Image(systemName: store.category(for: anime)?.icon ?? "plus")
                .foregroundStyle(store.isSaved(anime) ? CloudTheme.coral : .white)
                .frame(width: size, height: size)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(store.category(for: anime).map { "Saved in \($0.title)" } ?? "Save to library")
    }
}

struct LibraryCategoryActions: View {
    let anime: Anime
    @ObservedObject var store: LibraryStore

    var body: some View {
        Section("Save to library") {
            ForEach(LibraryCategory.allCases) { category in
                Button {
                    store.setCategory(category, for: anime)
                } label: {
                    Label(category.title, systemImage: store.category(for: anime) == category ? "checkmark" : category.icon)
                }
            }
        }
        if store.isSaved(anime) {
            Divider()
            Button("Remove from Library", systemImage: "trash", role: .destructive) {
                store.setCategory(nil, for: anime)
            }
        }
    }
}

struct LibraryQuickAddMenu: View {
    let anime: Anime
    @ObservedObject var store: LibraryStore

    var body: some View {
        let category = store.category(for: anime)
        Group {
            if let category {
                Menu {
                    LibraryCategoryActions(anime: anime, store: store)
                } label: {
                    badge(category == .watchLater ? "bookmark.fill" : category.icon, isSaved: true)
                }
                .accessibilityLabel("Saved in \(category.title): \(anime.name)")
            } else {
                Menu {
                    LibraryCategoryActions(anime: anime, store: store)
                } label: {
                    badge("plus", isSaved: false)
                } primaryAction: {
                    store.setCategory(.watchLater, for: anime)
                }
                .accessibilityLabel("Add \(anime.name) to Watch Later")
                .accessibilityHint("Touch and hold to choose a library category")
            }
        }
        .buttonStyle(.plain)
    }

    private func badge(_ icon: String, isSaved: Bool) -> some View {
        Image(systemName: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isSaved ? CloudTheme.cyan : .white)
            .frame(width: 32, height: 32)
            .background(.black.opacity(0.72), in: Circle())
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

extension View {
    func libraryQuickAdd(anime: Anime, store: LibraryStore) -> some View {
        overlay(alignment: .topLeading) {
            LibraryQuickAddMenu(anime: anime, store: store)
                .padding(4)
        }
    }
}
