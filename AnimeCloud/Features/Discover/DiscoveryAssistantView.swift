import SwiftUI

struct DiscoveryAssistantView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var answer: DiscoveryAnswer?
    @State private var isThinking = false

    var body: some View {
        NavigationStack {
            ZStack {
                CloudBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        intro
                        promptBox
                        if isThinking { thinking }
                        if let answer { answerView(answer) }
                    }
                    .padding(20)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Ask the Cloud")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await model.loadCatalog() }
            .navigationDestination(for: Anime.self) { AnimeDetailView(anime: $0, library: model.library) }
        }
    }

    private var intro: some View {
        HStack(alignment: .top, spacing: 15) {
            CloudLogo(size: 54)
            VStack(alignment: .leading, spacing: 5) {
                Text("Describe a feeling, not a filter.").font(.title2.bold())
                Text("I only recommend titles that exist in the live Anime Cloud catalog. Arabic and English both work.")
                    .font(.subheadline).foregroundStyle(CloudTheme.muted)
            }
        }
    }

    private var promptBox: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("A clever mystery with little romance…", text: $prompt, axis: .vertical)
                .lineLimit(3...6).textFieldStyle(.plain).font(.body)
            Divider().overlay(Color.white.opacity(0.12))
            HStack {
                Text("Private catalog mode").font(.caption).foregroundStyle(CloudTheme.muted)
                Spacer()
                Button { Task { await ask() } } label: {
                    Label("Find my anime", systemImage: "sparkles").font(.subheadline.bold())
                        .padding(.horizontal, 16).padding(.vertical, 10).background(CloudTheme.heroGradient, in: Capsule())
                }
                .disabled(isThinking || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18).cloudPanel()
    }

    private var thinking: some View {
        HStack(spacing: 12) { ProgressView(); Text("Reading the catalog…").foregroundStyle(CloudTheme.muted) }
            .frame(maxWidth: .infinity).padding(30)
    }

    private func answerView(_ answer: DiscoveryAnswer) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(answer.headline).font(.title2.bold())
            Text(answer.explanation).font(.subheadline).foregroundStyle(CloudTheme.muted)
            Text(answer.source.uppercased()).font(.caption2.weight(.black)).tracking(1.2).foregroundStyle(CloudTheme.cyan)
            ForEach(answer.anime) { anime in
                NavigationLink(value: anime) {
                    HStack(spacing: 13) {
                        RemoteArtwork(url: anime.imageURL).frame(width: 62, height: 86).clipShape(RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(anime.name).font(.headline).multilineTextAlignment(.leading)
                            Text(anime.subtitle).font(.caption).foregroundStyle(CloudTheme.muted)
                        }
                        Spacer(); Image(systemName: "chevron.right").foregroundStyle(CloudTheme.muted)
                    }
                    .padding(10).cloudPanel()
                }.buttonStyle(.plain)
            }
        }
    }

    private func ask() async {
        isThinking = true
        answer = try? await model.discovery.recommend(prompt: prompt, catalog: model.catalog, favorites: model.library.favorites)
        isThinking = false
    }
}
