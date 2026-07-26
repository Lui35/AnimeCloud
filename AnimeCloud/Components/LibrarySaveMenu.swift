import SwiftUI

struct LibrarySaveMenu: View {
    let anime: Anime
    @ObservedObject var store: LibraryStore
    var size: CGFloat = 46

    var body: some View {
        Menu {
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
        } label: {
            Image(systemName: store.category(for: anime)?.icon ?? "plus")
                .foregroundStyle(store.isSaved(anime) ? CloudTheme.coral : .white)
                .frame(width: size, height: size)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(store.category(for: anime).map { "Saved in \($0.title)" } ?? "Save to library")
    }
}
