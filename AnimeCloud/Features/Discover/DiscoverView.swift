import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var selectedStatus = "All"

    private let columns = [GridItem(.adaptive(minimum: 145), spacing: 16)]

    var body: some View {
        NavigationStack {
            ZStack {
                CloudBackground()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        statusPicker
                        if model.isCatalogLoading {
                            ProgressView("Gathering the whole catalog…").frame(maxWidth: .infinity).padding(.top, 100)
                        } else if filtered.isEmpty {
                            EmptyCloud(title: "No anime found", detail: "Try a title, keyword, year, or a different status.", systemImage: "magnifyingglass")
                                .frame(height: 360)
                        } else {
                            Text("\(filtered.count) titles").font(.caption.weight(.semibold)).foregroundStyle(CloudTheme.muted)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                                ForEach(filtered) { anime in
                                    NavigationLink(value: anime) { PosterView(anime: anime, width: 154, height: 220) }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 110)
                }
            }
            .navigationTitle("Discover")
            .searchable(text: $query, prompt: "Titles, keywords, years")
            .task { await model.loadCatalog() }
            .navigationDestination(for: Anime.self) { AnimeDetailView(anime: $0, library: model.library) }
        }
    }

    private var filtered: [Anime] {
        model.catalog.filter { anime in
            let statusMatches = selectedStatus == "All" || normalizedStatus(anime.status) == selectedStatus
            let text = [anime.name, anime.keywords, anime.year].compactMap { $0 }.joined(separator: " ")
            return statusMatches && (query.isEmpty || text.localizedCaseInsensitiveContains(query))
        }
    }

    private var statusPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(["All", "Ongoing", "Completed"], id: \.self) { status in
                    Button(status) { selectedStatus = status }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 15).padding(.vertical, 9)
                        .background(selectedStatus == status ? AnyShapeStyle(CloudTheme.heroGradient) : AnyShapeStyle(CloudTheme.panel), in: Capsule())
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private func normalizedStatus(_ status: String?) -> String {
        guard let status else { return "" }
        if status.contains("مستمر") || status.localizedCaseInsensitiveContains("ongoing") { return "Ongoing" }
        if status.contains("مكتمل") || status.localizedCaseInsensitiveContains("complete") { return "Completed" }
        return status
    }
}
