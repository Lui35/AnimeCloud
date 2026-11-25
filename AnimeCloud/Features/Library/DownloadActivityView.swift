import SwiftUI

struct DownloadActivityView: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All", active = "Active", failed = "Failed", ready = "Ready"
        var id: Self { self }

        func includes(_ status: EpisodeDownload.Status) -> Bool {
            switch self {
            case .all: true
            case .active: status == .preparing || status == .downloading
            case .failed: status == .failed
            case .ready: status == .ready
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @ObservedObject var downloads: EpisodeDownloads
    @State private var filter: Filter = .all
    @State private var removing: EpisodeDownload?

    private let sections: [(status: EpisodeDownload.Status, title: String)] = [
        (.downloading, "Downloading"), (.preparing, "Preparing"), (.failed, "Failed"), (.ready, "Ready")
    ]

    private var failedCount: Int { downloads.records.values.filter { $0.status == .failed }.count }

    private func records(for status: EpisodeDownload.Status) -> [EpisodeDownload] {
        downloads.records.values.filter { $0.status == status }.sorted {
            let order = $0.anime.name.localizedStandardCompare($1.anime.name)
            if order != .orderedSame { return order == .orderedAscending }
            if $0.anime.id != $1.anime.id { return $0.anime.id < $1.anime.id }
            if $0.catalogPosition != $1.catalogPosition { return $0.catalogPosition > $1.catalogPosition }
            return $0.id < $1.id
        }
    }

    var body: some View {
        ZStack {
            CloudBackground()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    activityHeader
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Filter.allCases) { option in
                                Button { filter = option } label: {
                                    HStack(spacing: 8) {
                                        Text(option.rawValue)
                                        Text("\(count(for: option))").monospacedDigit()
                                            .foregroundStyle(filter == option ? CloudTheme.ink : CloudTheme.cyan)
                                    }
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 16).frame(minHeight: 44)
                                    .background(filter == option ? CloudTheme.cyan : CloudTheme.panel, in: Capsule())
                                    .foregroundStyle(filter == option ? CloudTheme.ink : .white)
                                    .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(option.rawValue) downloads, \(count(for: option)) episodes")
                                .accessibilityAddTraits(filter == option ? .isSelected : [])
                            }
                        }
                    }
                    if count(for: filter) == 0 {
                        EmptyCloud(
                            title: filter == .all ? "No downloads yet" : "No \(filter.rawValue.lowercased()) downloads",
                            detail: filter == .all ? "Choose episodes from an anime’s episode list to download them." : "Download activity updates here automatically.",
                            systemImage: "arrow.down.circle"
                        )
                        .frame(minHeight: 260)
                    }
                    ForEach(sections.indices, id: \.self) { index in
                        let section = sections[index]
                        let items = records(for: section.status)
                        if filter.includes(section.status), !items.isEmpty {
                            HStack {
                                Text(section.title).font(.title3.bold())
                                Spacer()
                                Text("\(items.count) episodes").font(.subheadline).foregroundStyle(CloudTheme.muted)
                            }
                            .padding(.top, 8)
                            ForEach(items) { record in
                                activityRow(record)
                                    .padding(16).cloudPanel()
                                    .overlay {
                                        if record.status == .failed {
                                            RoundedRectangle(cornerRadius: 22).stroke(CloudTheme.coral.opacity(0.5))
                                        }
                                    }
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Download activity")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if failedCount > 0 {
                Button {
                    downloads.retryAllFailed()
                } label: {
                    Label("Retry all failed (\(failedCount))", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(PrimaryCapsuleStyle())
                .padding()
                .background(.regularMaterial)
            }
        }
        .confirmationDialog("Remove download?", isPresented: Binding(
            get: { removing != nil },
            set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible, presenting: removing) { record in
            Button(record.status == .preparing || record.status == .downloading ? "Cancel download" : "Remove download", role: .destructive) {
                do { try downloads.remove(record.id) }
                catch { model.message = AppMessage(error: error) }
                removing = nil
            }
        } message: { record in
            Text("\(record.anime.name) · \(record.episode.name). Your watched status and resume position will stay saved.")
        }
    }

    private func count(for filter: Filter) -> Int {
        downloads.records.values.filter { filter.includes($0.status) }.count
    }

    private var activityHeader: some View {
        let active = count(for: .active)
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: failedCount > 0 ? "exclamationmark.arrow.circlepath" : active > 0 ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                .font(.title).foregroundStyle(failedCount > 0 ? CloudTheme.coral : CloudTheme.cyan)
                .frame(width: 52, height: 52)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(failedCount > 0 ? "\(failedCount) need attention" : active > 0 ? "\(active) in progress" : "\(count(for: .ready)) ready to watch")
                    .font(.title2.bold())
                Text(failedCount > 0 ? "Retry failed episodes below, or retry them all at once." : "Manage active downloads and episodes saved for offline watching.")
                    .font(.subheadline).foregroundStyle(CloudTheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16).cloudPanel()
    }

    private func activityRow(_ record: EpisodeDownload) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                RemoteArtwork(url: nil, fallbackFileURL: downloads.artworkURL(for: record.anime.id))
                    .frame(width: 48, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.anime.name).font(.subheadline.weight(.semibold))
                    Text(record.episode.name).font(.headline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                Menu {
                    Button(record.status == .preparing || record.status == .downloading ? "Cancel download" : "Remove download", role: .destructive) {
                        removing = record
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Options for \(record.anime.name), \(record.episode.name)")
            }
            switch record.status {
            case .preparing:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Preparing download…").font(.subheadline)
                }
            case .downloading:
                if let fraction = downloads.progress[record.id] {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(fraction >= 1 ? "Finishing download…" : "Downloading")
                            Spacer()
                            Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                        }
                        .font(.subheadline)
                        ProgressView(value: fraction)
                            .tint(CloudTheme.cyan)
                            .accessibilityLabel("Download progress for \(record.episode.name)")
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Downloading…").font(.subheadline)
                    }
                }
            case .failed:
                Label("Download failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CloudTheme.coral)
                Text(record.failure ?? "The download couldn’t finish. Try again.")
                    .font(.footnote)
                    .foregroundStyle(CloudTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(CloudTheme.coral.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                Button { downloads.retry(record.id) } label: {
                    Label("Retry episode", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(CloudTheme.cyan)
                .accessibilityLabel("Retry \(record.anime.name), \(record.episode.name)")
            case .ready:
                Label("Ready to watch offline", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(CloudTheme.cyan)
                NavigationLink {
                    DownloadedAnimeView(anime: record.anime, downloads: downloads, library: model.library, progress: model.playbackProgress)
                } label: {
                    Label("View episodes", systemImage: "play.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered).tint(CloudTheme.cyan)
            }
        }
        .padding(.vertical, 4)
        .foregroundStyle(.white)
    }
}
