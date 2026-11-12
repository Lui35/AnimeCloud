import SwiftUI

struct DownloadSelectionView: View {
    private enum RangeField { case from, to }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var downloads: EpisodeDownloads
    let anime: Anime
    let catalog: [Episode]
    @State private var selected: Set<String> = []
    @State private var fromEpisode = ""
    @State private var toEpisode = ""
    @State private var episodeRange: ClosedRange<Int>?
    @FocusState private var editingRange: RangeField?

    var body: some View {
        NavigationStack {
            ZStack {
                CloudBackground()
                List {
                    HStack(spacing: 14) {
                        RemoteArtwork(url: anime.imageURL)
                            .frame(width: 56, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .accessibilityHidden(true)
                        Text(anime.name).font(.headline)
                    }
                    .listRowBackground(CloudTheme.panel)
                    rangeFilter
                        .listRowBackground(CloudTheme.panel)
                    if visibleEpisodes.isEmpty {
                        Text("No episodes in this range.")
                            .foregroundStyle(CloudTheme.muted)
                            .listRowBackground(CloudTheme.panel)
                    }
                    ForEach(visibleEpisodes) { episode in
                        let status = downloads.records[episode.id]?.status
                        let selectable = canSelect(episode)
                        Button {
                            if selected.remove(episode.id) == nil { selected.insert(episode.id) }
                        } label: {
                            HStack {
                                Text(episode.name)
                                Spacer()
                                if selectable {
                                    Image(systemName: selected.contains(episode.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(CloudTheme.cyan)
                                } else {
                                    Text(status == .ready ? "Downloaded" : "Queued")
                                        .font(.caption)
                                        .foregroundStyle(CloudTheme.muted)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!selectable)
                        .accessibilityAddTraits(selected.contains(episode.id) ? .isSelected : [])
                        .listRowBackground(CloudTheme.panel)
                    }
                }
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Select episodes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    downloads.enqueue(anime: anime, catalog: catalog, selected: selected)
                    dismiss()
                } label: {
                    Label(downloadButtonTitle,
                          systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryCapsuleStyle())
                .disabled(selected.isEmpty)
                .opacity(selected.isEmpty ? 0.5 : 1)
                .padding()
                .background(.regularMaterial)
            }
        }
    }

    private var rangeFilter: some View {
        let availableIDs = episodeRange == nil ? [] : visibleEpisodes.filter(canSelect).map(\.id)
        let allSelected = !availableIDs.isEmpty && availableIDs.allSatisfy(selected.contains)
        return DisclosureGroup(episodeRange.map { "Episodes \($0.lowerBound)–\($0.upperBound)" } ?? "Episode range") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    TextField("From", text: $fromEpisode)
                        .accessibilityLabel("From episode")
                        .focused($editingRange, equals: .from)
                    TextField("To", text: $toEpisode)
                        .accessibilityLabel("To episode")
                        .focused($editingRange, equals: .to)
                }
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)
                HStack {
                    Button("Filter episodes") {
                        episodeRange = inputRange
                        editingRange = nil
                    }
                    .disabled(inputRange == nil)
                    if episodeRange != nil {
                        Spacer()
                        Button("Clear filter") {
                            episodeRange = nil
                            fromEpisode = ""
                            toEpisode = ""
                            editingRange = nil
                        }
                    }
                }
                .buttonStyle(.borderless)
                if !availableIDs.isEmpty {
                    Button(allSelected ? "Deselect all in range" : "Select all in range") {
                        if allSelected {
                            selected.subtract(availableIDs)
                        } else {
                            selected.formUnion(availableIDs)
                        }
                    }
                    .buttonStyle(.borderless)
                }
                if !fromEpisode.isEmpty && !toEpisode.isEmpty && inputRange == nil {
                    Text("Enter a valid range, with the smaller episode number first.")
                        .font(.caption)
                        .foregroundStyle(CloudTheme.muted)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var inputRange: ClosedRange<Int>? {
        guard let lower = episodeNumber(fromEpisode), let upper = episodeNumber(toEpisode), lower <= upper else { return nil }
        return lower...upper
    }

    private func episodeNumber(_ text: String) -> Int? {
        let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let values = digits.compactMap(\.wholeNumberValue)
        guard values.count == digits.count, values.allSatisfy({ (0...9).contains($0) }) else { return nil }
        return Int(values.map(String.init).joined())
    }

    private var visibleEpisodes: [Episode] {
        guard let episodeRange else { return catalog }
        return catalog.filter { $0.episodeNumber.map(episodeRange.contains) ?? false }
    }

    private func canSelect(_ episode: Episode) -> Bool {
        let status = downloads.records[episode.id]?.status
        return status == nil || status == .failed
    }

    private var downloadButtonTitle: String {
        switch selected.count {
        case 0: "Download episodes"
        case 1: "Download 1 episode"
        default: "Download \(selected.count) episodes"
        }
    }
}

struct DownloadsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var downloads: EpisodeDownloads

    private var groups: [(anime: Anime, records: [EpisodeDownload])] {
        Dictionary(grouping: downloads.records.values, by: { $0.anime.id })
            .values.compactMap { records in records.first.map { ($0.anime, records) } }
            .sorted { $0.anime.name.localizedStandardCompare($1.anime.name) == .orderedAscending }
    }

    var body: some View {
        ZStack {
            CloudBackground()
            if groups.isEmpty {
                EmptyCloud(title: "No downloads yet", detail: "Choose episodes from an anime’s episode list to watch offline.",
                           systemImage: "arrow.down.circle")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if model.hasPendingCloudChanges { DownloadSyncStatus() }
                        SectionHeading(title: "On this device")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 154), spacing: 16)], alignment: .leading, spacing: 22) {
                            ForEach(groups, id: \.anime.id) { group in
                                let anime = group.anime
                                let ready = group.records.filter { downloads.localURL(for: $0.id) != nil }.count
                                NavigationLink {
                                    DownloadedAnimeView(anime: anime, downloads: downloads, library: model.library, progress: model.playbackProgress)
                                } label: {
                                    VStack(alignment: .leading, spacing: 7) {
                                        PosterView(anime: anime, width: 154, height: 220,
                                                   cachedArtworkURL: downloads.artworkURL(for: anime.id))
                                        Text(ready == group.records.count
                                             ? (ready == 1 ? "1 episode" : "\(ready) episodes")
                                             : "\(ready) of \(group.records.count) ready")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(CloudTheme.cyan)
                                    }
                                    .accessibilityElement(children: .combine)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 110)
                }
            }
        }
        .navigationTitle("Downloads")
        .task { await model.retryPendingWatchSync() }
        .refreshable { await model.retryPendingWatchSync() }
    }
}

private struct DownloadedAnimeView: View {
    @EnvironmentObject private var model: AppModel
    let anime: Anime
    @ObservedObject var downloads: EpisodeDownloads
    @ObservedObject var library: LibraryStore
    @ObservedObject var progress: PlaybackProgressStore
    @State private var selected: EpisodeDownload?
    @State private var removing: EpisodeDownload?

    private var records: [EpisodeDownload] {
        downloads.records.values.filter { $0.anime.id == anime.id }
            .sorted {
                let first = $0.episode.episodeNumber ?? -1
                let second = $1.episode.episodeNumber ?? -1
                if first != second { return first > second }
                return ($0.catalogPosition, $0.id) < ($1.catalogPosition, $1.id)
            }
    }

    private var ready: [EpisodeDownload] {
        records.filter { downloads.localURL(for: $0.id) != nil }
    }

    private var resumeOrNext: EpisodeDownload? {
        ready.compactMap { record in
            progress.progress(for: record.id).map { (record, $0.updatedAt) }
        }
        .max { $0.1 < $1.1 }?.0
        ?? ready.last { !library.isSeen($0.episode) }
        ?? ready.last
    }

    var body: some View {
        ZStack {
            CloudBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    AnimeDetailHero(anime: anime, cachedArtworkURL: downloads.artworkURL(for: anime.id)) {
                        HStack(spacing: 12) {
                            if let record = resumeOrNext {
                                Button { selected = record } label: {
                                    Label(progress.progress(for: record.id) == nil ? "Play downloaded episode" : "Resume watching",
                                          systemImage: "play.fill")
                                }
                                .buttonStyle(PrimaryCapsuleStyle())
                            }
                            LibrarySaveMenu(anime: anime, store: library, size: 48)
                        }
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        if model.hasPendingCloudChanges { DownloadSyncStatus() }
                        SectionHeading(title: "Downloaded episodes", subtitle: "Newest first")
                        if records.isEmpty {
                            Text("No episodes saved on this device.").foregroundStyle(CloudTheme.muted)
                        }
                        LazyVStack(spacing: 12) {
                            ForEach(records) { record in
                                EpisodeRow(anime: anime, episode: record.episode, library: library,
                                           progressStore: progress, download: record, onRemove: { removing = record }) {
                                    selected = record
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 110)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await model.retryPendingWatchSync() }
        .confirmationDialog("Remove download?", isPresented: Binding(
            get: { removing != nil },
            set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible, presenting: removing) { record in
            Button("Remove download", role: .destructive) {
                do { try downloads.remove(record.id) }
                catch { model.message = AppMessage(error: error) }
            }
        } message: { _ in
            Text("Your watched status and resume position will stay saved.")
        }
        .sheet(item: $selected) { record in
            PlayerSheet(anime: anime, initialEpisode: record.episode, episodes: ready.map(\.episode),
                        library: library, progressStore: progress, downloadedPlayback: true)
        }
    }

}

private struct DownloadSyncStatus: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Label(model.isCloudSyncing ? "Syncing watch activity…" : "Watch activity pending sync",
              systemImage: "icloud")
            .font(.subheadline)
            .foregroundStyle(CloudTheme.cyan)
    }
}
