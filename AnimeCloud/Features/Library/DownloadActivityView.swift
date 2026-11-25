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
            if !downloads.records.values.contains(where: { filter.includes($0.status) }) {
                EmptyCloud(
                    title: filter == .all ? "No downloads yet" : "No \(filter.rawValue.lowercased()) downloads",
                    detail: filter == .all ? "Choose episodes from an anime’s episode list to download them." : "Download activity updates here automatically.",
                    systemImage: "arrow.down.circle"
                )
            } else {
                List {
                    ForEach(sections.indices, id: \.self) { index in
                        let section = sections[index]
                        let items = records(for: section.status)
                        if filter.includes(section.status), !items.isEmpty {
                            Section("\(section.title) (\(items.count))") {
                                ForEach(items) { record in
                                    activityRow(record)
                                        .listRowBackground(CloudTheme.panel)
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Download activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("Show downloads", selection: $filter) {
                    ForEach(Filter.allCases) { option in Text(option.rawValue).tag(option) }
                }
                .pickerStyle(.menu)
            }
        }
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

    private func activityRow(_ record: EpisodeDownload) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
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
                Button { downloads.retry(record.id) } label: {
                    Label("Retry episode", systemImage: "arrow.clockwise")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(CloudTheme.cyan)
                .accessibilityLabel("Retry \(record.anime.name), \(record.episode.name)")
            case .ready:
                Label("Ready to watch offline", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(CloudTheme.cyan)
            }
        }
        .padding(.vertical, 8)
        .foregroundStyle(.white)
    }
}
