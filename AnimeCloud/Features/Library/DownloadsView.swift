import SwiftUI
import UIKit

enum DownloadEpisodeSelection {
    static func eligibleIDs(in episodes: [Episode], records: [String: EpisodeDownload], excludingFillers: Bool = false) -> Set<String> {
        Set(episodes.filter {
            (!excludingFillers || !$0.isFiller) && (records[$0.id] == nil || records[$0.id]?.status == .failed)
        }.map(\.id))
    }
}

struct DownloadSelectionView: View {
    private enum RangeField { case from, to }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var downloads: EpisodeDownloads
    let library: LibraryStore
    let anime: Anime
    let catalog: [Episode]
    @State private var watchedEpisodeIDs: Set<String> = []
    @State private var selected: Set<String> = []
    @State private var showingActivity = false
    @State private var fromEpisode = ""
    @State private var toEpisode = ""
    @State private var episodeRange: ClosedRange<Int>?
    @FocusState private var editingRange: RangeField?

    var body: some View {
        NavigationStack {
            ZStack {
                CloudBackground()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        selectionHeader
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Quick selection").font(.headline)
                            Text(episodeRange == nil ? "Choose all available episodes or skip the fillers." : "Selections apply to the current episode range.")
                                .font(.subheadline).foregroundStyle(CloudTheme.muted)
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 10) { selectionPresets }
                                VStack(spacing: 10) { selectionPresets }
                            }
                            if !selected.isEmpty {
                                Button { selected.removeAll() } label: {
                                    Label("Clear selection", systemImage: "minus.circle").frame(minHeight: 44)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(16).cloudPanel()
                        rangeFilter.padding(16).cloudPanel()
                        HStack {
                            Text("Episodes").font(.title3.bold())
                            Spacer()
                            Text("\(visibleEpisodes.count) in view").font(.subheadline).foregroundStyle(CloudTheme.muted)
                        }
                        if visibleEpisodes.isEmpty {
                            Text("No episodes in this range.").foregroundStyle(CloudTheme.muted).padding(16)
                        }
                        ForEach(visibleEpisodes) { episode in selectionRow(episode) }
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Download episodes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { DownloadActivityView(downloads: downloads) } label: {
                        Label("Download activity", systemImage: "list.bullet.rectangle")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Text("\(selected.count) selected · \(selectedFillerCount) filler")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(CloudTheme.muted)
                    Button {
                        downloads.enqueue(anime: anime, catalog: catalog, selected: selected)
                        selected.removeAll()
                        showingActivity = true
                    } label: {
                        Label(downloadButtonTitle, systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(PrimaryCapsuleStyle())
                    .disabled(selected.isEmpty)
                    .opacity(selected.isEmpty ? 0.5 : 1)
                }
                .padding().background(.regularMaterial)
            }
            .navigationDestination(isPresented: $showingActivity) {
                DownloadActivityView(downloads: downloads)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                    }
            }
        }
        .onAppear { watchedEpisodeIDs = library.seenEpisodeIDs }
        .onReceive(library.seenStatusChanged) { change in
            if change.isSeen { watchedEpisodeIDs.insert(change.episodeID) }
            else { watchedEpisodeIDs.remove(change.episodeID) }
        }
        .onReceive(downloads.$records) { records in
            selected.formIntersection(DownloadEpisodeSelection.eligibleIDs(in: catalog, records: records))
        }
        .onChange(of: episodeRange) { _, _ in selected.formIntersection(Set(visibleEpisodes.map(\.id))) }
    }

    private var selectionHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            RemoteArtwork(url: anime.imageURL)
                .frame(width: 72, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(anime.name).font(.headline)
                Text("\(catalog.count) episodes").font(.subheadline).foregroundStyle(CloudTheme.muted)
                Text("\(selectableVisibleIDs.count) available to download")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(CloudTheme.cyan)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16).cloudPanel()
    }

    @ViewBuilder private var selectionPresets: some View {
        presetButton("All episodes", detail: "\(selectableVisibleIDs.count) available", icon: "checkmark.circle", ids: selectableVisibleIDs)
        presetButton("Non-filler episodes", detail: "\(nonFillerIDs.count) available", icon: "line.3.horizontal.decrease.circle", ids: nonFillerIDs)
    }

    private func presetButton(_ title: String, detail: String, icon: String, ids: Set<String>) -> some View {
        Button { selected = ids } label: {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(CloudTheme.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .padding(12)
            .background(selected == ids && !ids.isEmpty ? CloudTheme.violet.opacity(0.25) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(selected == ids && !ids.isEmpty ? CloudTheme.cyan : Color.white.opacity(0.12)) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(ids.isEmpty)
        .accessibilityAddTraits(selected == ids && !ids.isEmpty ? .isSelected : [])
    }

    private func selectionRow(_ episode: Episode) -> some View {
        let status = downloads.records[episode.id]?.status
        let selectable = canSelect(episode)
        let watched = watchedEpisodeIDs.contains(episode.id)
        return Button {
            if selected.remove(episode.id) == nil { selected.insert(episode.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectable ? (selected.contains(episode.id) ? "checkmark.circle.fill" : "circle") : (status == .ready ? "checkmark.circle.fill" : "arrow.down.circle"))
                    .font(.title2).foregroundStyle(CloudTheme.cyan).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(episode.name).font(.subheadline.weight(.semibold))
                    HStack(spacing: 10) {
                        if episode.isFiller { Label("Filler", systemImage: "sparkles").foregroundStyle(.orange) }
                        if watched { Label("Watched", systemImage: "eye.fill").foregroundStyle(CloudTheme.muted) }
                        if !selectable { Text(status == .ready ? "Downloaded" : "In download activity").foregroundStyle(CloudTheme.cyan) }
                    }
                    .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16).frame(minHeight: 60).cloudPanel().contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!selectable)
        .accessibilityLabel(episode.name)
        .accessibilityValue(downloadRowStatus(episode, isWatched: watched, status: status))
        .accessibilityAddTraits(selected.contains(episode.id) ? .isSelected : [])
    }

    private func downloadRowStatus(_ episode: Episode, isWatched: Bool, status: EpisodeDownload.Status?) -> String {
        var descriptions: [String] = []
        if episode.isFiller { descriptions.append("Filler") }
        if isWatched { descriptions.append("Watched") }
        if !canSelect(episode) { descriptions.append(status == .ready ? "Downloaded" : "Queued") }
        return descriptions.joined(separator: ", ")
    }

    private var rangeFilter: some View {
        DisclosureGroup(episodeRange.map { "Episodes \($0.lowerBound)–\($0.upperBound)" } ?? "Episode range") {
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
                if !fromEpisode.isEmpty && !toEpisode.isEmpty && inputRange == nil {
                    Text("Enter a valid range, with the smaller episode number first.")
                        .font(.caption)
                        .foregroundStyle(CloudTheme.muted)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var selectableVisibleIDs: Set<String> {
        DownloadEpisodeSelection.eligibleIDs(in: visibleEpisodes, records: downloads.records)
    }

    private var nonFillerIDs: Set<String> {
        DownloadEpisodeSelection.eligibleIDs(in: visibleEpisodes, records: downloads.records, excludingFillers: true)
    }

    private var selectedFillerCount: Int { catalog.filter { selected.contains($0.id) && $0.isFiller }.count }

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

    @State private var exportRequest: EpisodeExportRequest?

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
                        NavigationLink {
                            DownloadActivityView(downloads: downloads)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Label("Download activity", systemImage: "list.bullet.rectangle")
                                        .font(.headline)
                                    Text(activitySummary)
                                        .font(.subheadline)
                                        .foregroundStyle(CloudTheme.muted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").accessibilityHidden(true)
                            }
                            .foregroundStyle(CloudTheme.cyan)
                            .padding(16)
                            .frame(minHeight: 44)
                            .cloudPanel()
                        }
                        .buttonStyle(.plain)
                        if model.hasPendingCloudChanges { DownloadSyncStatus() }
                        SectionHeading(title: "On this device")
                        PosterGrid {
                            ForEach(groups, id: \.anime.id) { group in
                                let anime = group.anime
                                let ready = group.records.filter { downloads.localURL(for: $0.id) != nil }.count
                                NavigationLink {
                                    DownloadedAnimeView(anime: anime, downloads: downloads, library: model.library, progress: model.playbackProgress)
                                } label: {
                                    VStack(alignment: .leading, spacing: 7) {
                                        PosterView(anime: anime, cachedArtworkURL: downloads.artworkURL(for: anime.id))
                                        Text(ready == group.records.count
                                             ? (ready == 1 ? "1 episode" : "\(ready) episodes")
                                             : "\(ready) of \(group.records.count) ready")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(CloudTheme.cyan)
                                            .lineLimit(1)
                                    }
                                    .accessibilityElement(children: .combine)
                                }
                                .buttonStyle(.plain)
                                .libraryQuickAdd(anime: anime, store: model.library)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 110)
                }
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    DownloadActivityView(downloads: downloads)
                } label: {
                    Label("Download activity", systemImage: "list.bullet.rectangle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Export all", systemImage: "square.and.arrow.up") {
                    exportRequest = EpisodeExportRequest(episodeIDs: groups.flatMap { group in
                        group.records.sorted { $0.catalogPosition < $1.catalogPosition }
                            .filter { downloads.localURL(for: $0.id) != nil }.map(\.id)
                    })
                }
                .disabled(!downloads.records.values.contains { downloads.localURL(for: $0.id) != nil })
            }
        }
        .sheet(item: $exportRequest) { request in
            EpisodeExportSheet(downloads: downloads, episodeIDs: request.episodeIDs)
        }
        .task { await model.retryPendingWatchSync() }
        .refreshable { await model.retryPendingWatchSync() }
    }

    private var activitySummary: String {
        let records = Array(downloads.records.values)
        let active = records.filter { $0.status == .preparing || $0.status == .downloading }.count
        let failed = records.filter { $0.status == .failed }.count
        let ready = records.filter { $0.status == .ready }.count
        return "\(active) active · \(failed) failed · \(ready) ready"
    }
}

struct DownloadedAnimeView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var navigationVisibility = ScrollAwareNavigationVisibility()
    @EnvironmentObject private var model: AppModel
    let anime: Anime
    @ObservedObject var downloads: EpisodeDownloads
    @ObservedObject var library: LibraryStore
    @ObservedObject var progress: PlaybackProgressStore
    @State private var selected: EpisodeDownload?
    @State private var removing: EpisodeDownload?
    @State private var exportRequest: EpisodeExportRequest?

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
        GeometryReader { geometry in
            ZStack {
                CloudBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        AnimeDetailHero(
                            anime: anime,
                            cachedArtworkURL: downloads.artworkURL(for: anime.id),
                            artworkHeight: verticalSizeClass == .compact ? 430 : 520,
                            topInset: geometry.safeAreaInsets.top
                        ) {
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
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: AnimeDetailScrollOffsetKey.self,
                                    value: proxy.frame(in: .named("downloadedAnimeScroll")).minY
                                )
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
                                               progressStore: progress, download: record,
                                               onExport: { exportRequest = EpisodeExportRequest(episodeIDs: [record.id]) }, onRemove: { removing = record }) {
                                        selected = record
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 110)
                }
                .ignoresSafeArea(.container, edges: .top)
                .coordinateSpace(name: "downloadedAnimeScroll")
                .onPreferenceChange(AnimeDetailScrollOffsetKey.self) { offset in
                    var next = navigationVisibility
                    next.update(offset: offset)
                    if reduceMotion || next.isVisible == navigationVisibility.isVisible {
                        navigationVisibility = next
                    } else {
                        withAnimation(.snappy(duration: 0.22)) { navigationVisibility = next }
                    }
                }
            }
        }
        .toolbar(navigationVisibility.isVisible ? .visible : .hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                AnimePlaybackMenu(anime: anime, library: library, progress: progress, episodeIDs: Set(records.map(\.id)), isToolbarItem: true)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Export all", systemImage: "square.and.arrow.up") {
                    exportRequest = EpisodeExportRequest(episodeIDs: ready.map(\.id))
                }
                .disabled(ready.isEmpty)
            }
        }
        .sheet(item: $exportRequest) { request in
            EpisodeExportSheet(downloads: downloads, episodeIDs: request.episodeIDs)
        }
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

private struct EpisodeExportRequest: Identifiable {
    let id = UUID()
    let episodeIDs: [String]
}

private struct EpisodeExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let downloads: EpisodeDownloads
    let episodeIDs: [String]
    @State private var directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    @State private var exportedFolder: URL?
    @State private var failure: String?

    var body: some View {
        Group {
            if let exportedFolder {
                EpisodeFolderExporter(folder: exportedFolder) { dismiss() }
                    .ignoresSafeArea()
            } else {
                NavigationStack {
                    VStack(spacing: 16) {
                        if let failure {
                            Text(failure)
                        } else {
                            ProgressView("Preparing \(episodeIDs.count == 1 ? "episode" : "\(episodeIDs.count) episodes")…")
                            Text("Episodes are organized into folders by anime. Choose where to save them in Files next.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .navigationTitle("Export videos")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(failure == nil ? "Cancel" : "Done") { dismiss() }
                        }
                    }
                }
            }
        }
        .task {
            do {
                exportedFolder = try await downloads.exportVideos(episodeIDs, to: directory)
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
        .onDisappear { try? FileManager.default.removeItem(at: directory) }
    }
}

private struct EpisodeFolderExporter: UIViewControllerRepresentable {
    let folder: URL
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [folder], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onFinish() }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onFinish() }
    }
}
