import SwiftUI
import WebKit

struct WatchPlansView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: WatchPlanStore
    @ObservedObject var library: LibraryStore
    @State private var query = ""
    @State private var removing: WatchPlan?
    @State private var errorMessage: String?

    private var candidates: [Anime] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Array((library.recentAnime.isEmpty ? model.featured : library.recentAnime).prefix(8))
        }
        return Array(model.catalog.filter { $0.name.localizedCaseInsensitiveContains(query) || ($0.keywords ?? "").localizedCaseInsensitiveContains(query) }.prefix(30))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CloudBackground()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        Text("One story. Every part.").font(.title2.bold())
                        Text("Save a researched viewing order and pick up at the next part.")
                            .foregroundStyle(CloudTheme.muted)
                        if store.plans.isEmpty {
                            Label("Start from an anime below, or open Watch order in Related.", systemImage: "list.number")
                                .padding(18).frame(maxWidth: .infinity, alignment: .leading).cloudPanel()
                        }
                        ForEach(store.plans) { plan in
                            NavigationLink {
                                SavedWatchPlanView(planID: plan.id, store: store, library: library)
                            } label: { planCard(plan) }
                            .buttonStyle(.plain)
                            .contextMenu { Button("Remove plan", systemImage: "trash", role: .destructive) { removing = plan } }
                        }
                        SectionHeading(title: query.isEmpty ? "Start a new plan" : "Matching titles")
                        if model.isCatalogLoading { ProgressView("Loading the catalog…") }
                        ForEach(candidates) { anime in
                            NavigationLink { WatchOrderView(anime: anime) } label: { PlannerAnimeLabel(anime: anime) }
                                .buttonStyle(.plain)
                        }
                        if !model.isCatalogLoading && !query.isEmpty && candidates.isEmpty {
                            Text("No matching uploaded titles. Try another title or spelling.").foregroundStyle(CloudTheme.muted)
                        }
                    }
                    .padding(20).padding(.bottom, 100)
                }
            }
            .navigationTitle("Watch Plans")
            .searchable(text: $query, prompt: "Find an anime to plan")
            .task { await model.loadCatalog() }
            .confirmationDialog("Remove this saved plan?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Remove plan", role: .destructive) {
                    guard let removing else { return }
                    do { try store.remove(removing.id) } catch { errorMessage = error.localizedDescription }
                    self.removing = nil
                }
            } message: { Text("Your library and episode history will stay saved.") }
            .alert("Could not save change", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func planCard(_ plan: WatchPlan) -> some View {
        let required = plan.steps.filter { plan.includeOptional || !$0.isOptional }
        let complete = required.filter { store.isComplete($0, library: library) }.count
        return VStack(alignment: .leading, spacing: 12) {
            PlannerAnimeLabel(anime: plan.anchor)
            Text(plan.mode.title).font(.caption).foregroundStyle(CloudTheme.muted)
            ProgressView(value: Double(complete), total: Double(max(required.count, 1))).tint(CloudTheme.cyan)
            Text("\(complete) of \(required.count) parts complete").font(.caption)
            if let next = store.nextStep(in: plan, library: library) {
                Text("Next: \(next.title)").font(.subheadline.weight(.semibold)).foregroundStyle(CloudTheme.cyan)
            } else { Label("Plan complete", systemImage: "checkmark.seal.fill").foregroundStyle(CloudTheme.cyan) }
        }
        .padding(16).cloudPanel()
    }
}

struct WatchOrderView: View {
    @EnvironmentObject private var model: AppModel
    let anime: Anime
    var related: [Anime] = []
    @State private var mode = WatchOrderMode.firstWatch
    @State private var proposal: WatchPlan?
    @State private var isThinking = false
    @State private var reviewed = false
    @State private var saved = false
    @State private var errorMessage: String?
    @State private var showingSetup = false
    @State private var researchTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            CloudBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    PlannerAnimeLabel(anime: anime).padding(16).cloudPanel()
                    Text("Find your way through the story").font(.title2.bold())
                    Text("Gemini researches the viewing order and cites its sources. Review the result before saving your plan.")
                        .foregroundStyle(CloudTheme.muted)
                    Picker("Viewing preference", selection: $mode) {
                        ForEach(WatchOrderMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu).disabled(isThinking)
                    Button(action: startResearch) {
                        Label(isThinking ? "Researching…" : "Research watch order", systemImage: "sparkle.magnifyingglass")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(PrimaryCapsuleStyle()).disabled(isThinking)
                    Text("Sends this title and its related titles to Gemini. Your watch history is not sent to Gemini. Google API charges may apply.")
                        .font(.caption).foregroundStyle(CloudTheme.muted)
                    if isThinking { ProgressView("Comparing sources and related parts…").frame(maxWidth: .infinity).padding(.vertical, 20) }
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(CloudTheme.coral)
                        Button("Gemini settings") { showingSetup = true }.frame(minHeight: 44)
                        Link("View Google project limits", destination: URL(string: "https://aistudio.google.com/rate-limit")!)
                            .frame(minHeight: 44)
                    }
                    if let proposal {
                        WatchResearchView(plan: proposal)
                        Divider()
                        Text("Your proposed plan").font(.title2.bold())
                        Text("Title matches are checked locally. Resolve missing matches before continuing past them.")
                            .font(.subheadline).foregroundStyle(CloudTheme.muted)
                        WatchPlanStepsView(plan: proposalBinding(proposal), library: model.library)
                        Toggle("I have reviewed this proposed order", isOn: $reviewed).tint(CloudTheme.cyan)
                        Button {
                            do { try model.watchPlans.save(self.proposal ?? proposal); saved = true }
                            catch { self.errorMessage = error.localizedDescription }
                        } label: {
                            Label(saved ? "Saved to Watch Plans" : (model.watchPlans.plans.contains(where: { $0.id == proposal.id }) ? "Update saved plan" : "Save this watch plan"), systemImage: saved ? "checkmark.circle.fill" : "bookmark")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(PrimaryCapsuleStyle()).disabled(!reviewed || saved)
                    }
                }
                .padding(20).padding(.bottom, 80)
            }
        }
        .navigationTitle("Watch order")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Gemini settings", systemImage: "gearshape") { showingSetup = true } } }
        .sheet(isPresented: $showingSetup) { GeminiSetupView(settings: model.gemini) }
        .onChange(of: mode) { _, _ in proposal = nil; reviewed = false; saved = false; errorMessage = nil }
        .onDisappear { researchTask?.cancel() }
    }

    private func proposalBinding(_ fallback: WatchPlan) -> Binding<WatchPlan> {
        Binding(get: { proposal ?? fallback }, set: { proposal = $0; reviewed = false; saved = false })
    }

    private func startResearch() {
        guard !isThinking else { return }
        guard model.gemini.isConfigured else { showingSetup = true; return }
        isThinking = true
        researchTask = Task { await research() }
    }

    private func research() async {
        proposal = nil
        errorMessage = nil
        reviewed = false
        saved = false
        defer { isThinking = false }
        do {
            let key = try model.gemini.apiKey()
            await model.loadCatalog()
            var context = related
            if context.isEmpty, let detail = try? await model.api.animeDetail(id: anime.id) {
                context = (try? await model.api.relatedAnime(animeID: anime.id, relatedID: detail.summary?.relatedID)) ?? []
            }
            try Task.checkCancellation()
            let result = try await model.watchOrder.research(anime: anime, related: context, mode: mode, catalog: model.knownAnime, apiKey: key)
            try Task.checkCancellation()
            proposal = result
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch { errorMessage = error.localizedDescription }
    }
}

struct SavedWatchPlanView: View {
    @EnvironmentObject private var model: AppModel
    let planID: String
    @ObservedObject var store: WatchPlanStore
    @ObservedObject var library: LibraryStore
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            CloudBackground()
            if let plan = store.plans.first(where: { $0.id == planID }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        PlannerAnimeLabel(anime: plan.anchor)
                        Text(plan.mode.title).foregroundStyle(CloudTheme.muted)
                        WatchPlanStepsView(plan: Binding(get: { store.plans.first(where: { $0.id == planID }) ?? plan }, set: { updated in
                            do { try store.update(planID) { $0 = updated } } catch { errorMessage = error.localizedDescription }
                        }), library: library)
                        DisclosureGroup("Saved research and sources") { WatchResearchView(plan: plan).padding(.top, 12) }
                        NavigationLink { WatchOrderView(anime: plan.anchor) } label: {
                            Label("Research another order", systemImage: "arrow.triangle.2.circlepath").frame(minHeight: 44)
                        }
                    }
                    .padding(20).padding(.bottom, 80)
                }
            }
        }
        .navigationTitle("Your watch plan").navigationBarTitleDisplayMode(.inline)
        .alert("Could not save change", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}

private struct WatchPlanStepsView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var plan: WatchPlan
    @ObservedObject var library: LibraryStore
    @State private var matching: WatchPlanStep?
    @State private var playing: Anime?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Include optional parts", isOn: $plan.includeOptional).tint(CloudTheme.cyan)
            if let next = model.watchPlans.nextStep(in: plan, library: library) {
                if let anime = next.anime {
                    Button { playing = anime } label: {
                        Label("Continue: \(anime.name)", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(PrimaryCapsuleStyle())
                } else {
                    Label("Match the next part before continuing: \(next.title)", systemImage: "questionmark.circle")
                        .foregroundStyle(.orange)
                }
            } else { Label("All selected parts are complete", systemImage: "checkmark.seal.fill").foregroundStyle(CloudTheme.cyan) }
            ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)").font(.headline.monospacedDigit()).foregroundStyle(CloudTheme.cyan)
                            .frame(width: 32, height: 32).background(CloudTheme.cyan.opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.anime?.name ?? step.title).font(.headline)
                            Text([step.anime?.year ?? step.year.map(String.init), step.format, step.isOptional ? "Optional" : nil].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(CloudTheme.muted)
                        }
                        Spacer(minLength: 0)
                        if model.watchPlans.isComplete(step, library: library) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(CloudTheme.cyan).accessibilityLabel("Complete")
                        }
                    }
                    Text(step.reason).font(.subheadline).foregroundStyle(CloudTheme.muted)
                    if let anime = step.anime {
                        NavigationLink { AnimeDetailView(anime: anime, library: library) } label: {
                            Label("Open anime", systemImage: "rectangle.stack").frame(minHeight: 44)
                        }
                    } else {
                        Text("Not matched to an uploaded title").font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        Button(step.anime == nil ? "Match title" : "Change match") { matching = step }.frame(minHeight: 44)
                        Spacer()
                        Button(model.watchPlans.isComplete(step, library: library) ? "Mark incomplete" : "Mark complete") {
                            guard let position = plan.steps.firstIndex(where: { $0.id == step.id }) else { return }
                            plan.steps[position].completionOverride = !model.watchPlans.isComplete(step, library: library)
                        }.frame(minHeight: 44)
                    }
                    .font(.caption.weight(.semibold))
                }
                .padding(16).cloudPanel()
            }
        }
        .sheet(item: $matching) { step in
            WatchTitleMatchView(step: step, catalog: model.knownAnime) { anime in
                guard let index = plan.steps.firstIndex(where: { $0.id == step.id }) else { return }
                plan.steps[index].anime = anime
            }
        }
        .sheet(item: $playing) { anime in PlanPlaybackView(anime: anime) }
    }
}

private struct WatchTitleMatchView: View {
    @Environment(\.dismiss) private var dismiss
    let step: WatchPlanStep
    let catalog: [Anime]
    let select: (Anime) -> Void
    @State private var query = ""

    private var matches: [Anime] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Array(catalog.filter { term.isEmpty || $0.name.localizedCaseInsensitiveContains(term) }.prefix(50))
    }
    var body: some View {
        NavigationStack {
            List {
                Section { Text("Choose the uploaded title for \(step.title). Similar names may be different seasons or adaptations.") }
                ForEach(matches) { anime in
                    Button { select(anime); dismiss() } label: { PlannerAnimeLabel(anime: anime) }.buttonStyle(.plain)
                }
                if matches.isEmpty { Text("No uploaded titles match this search. Leave this step unmatched if it is missing.") }
            }
            .navigationTitle("Match uploaded title").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search the uploaded catalog")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

private struct WatchResearchView: View {
    let plan: WatchPlan
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Gemini research").font(.title2.bold())
            Text(plan.researchedAt, style: .date).font(.caption).foregroundStyle(CloudTheme.muted)
            Text(.init(plan.guide)).textSelection(.enabled)
                .environment(\.openURL, OpenURLAction { WatchSource.isWebURL($0) ? .systemAction : .discarded })
            ForEach(Array(plan.cautions.enumerated()), id: \.offset) { _, caution in
                Label(caution, systemImage: "info.circle").font(.subheadline).foregroundStyle(.orange)
            }
            Text("Sources").font(.headline)
            ForEach(plan.sources) { source in
                Link(destination: source.url) { Label(source.title, systemImage: "arrow.up.right.square").frame(minHeight: 44, alignment: .leading) }
            }
            GoogleSearchSuggestions(html: plan.searchSuggestions).frame(height: 160)
            Text("AI-researched guidance can contain mistakes. Source citations show where Gemini looked; they do not guarantee that an order is correct.")
                .font(.caption).foregroundStyle(CloudTheme.muted)
        }
    }
}

private struct GoogleSearchSuggestions: UIViewRepresentable {
    let html: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        uiView.loadHTMLString(html, baseURL: URL(string: "https://www.google.com"))
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url, WatchSource.isWebURL(url) { UIApplication.shared.open(url) }
                decisionHandler(.cancel)
            } else { decisionHandler(navigationAction.request.url?.scheme == "about" ? .allow : .cancel) }
        }
    }
}

struct GeminiSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: GeminiSettings
    @State private var key = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Use your personal Gemini API key to research watch orders with web sources. The key is saved in this device's Keychain and is never bundled into the app.")
                    Text("Web research uses Google Search. For Gemini 3.8 Flash, that feature requires a billing-enabled project even though text generation has a free tier.")
                        .font(.subheadline)
                    Link("Open Google AI Studio", destination: URL(string: "https://aistudio.google.com/apikey")!)
                    Link("Check project limits", destination: URL(string: "https://aistudio.google.com/rate-limit")!)
                    SecureField(settings.isConfigured ? "Replace API key" : "Gemini API key", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save key") {
                        do { try settings.save(key); key = ""; dismiss() } catch { errorMessage = error.localizedDescription }
                    }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("Your selected anime and related titles are sent to Google when you request research. Your account and watch history are not sent. Usage is billed to your Google project; Google applies its own data policies.")
                }
                if settings.isConfigured {
                    Section {
                        Label("Personal key saved", systemImage: "checkmark.shield")
                        Button("Remove key", role: .destructive) {
                            do { try settings.remove(); dismiss() } catch { errorMessage = error.localizedDescription }
                        }
                    }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("Gemini watch planner").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onDisappear { key = "" }
        }
    }
}

private struct PlannerAnimeLabel: View {
    let anime: Anime
    var body: some View {
        HStack(spacing: 14) {
            RemoteArtwork(url: anime.imageURL).frame(width: 54, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(anime.name).font(.headline).multilineTextAlignment(.leading)
                Text(anime.subtitle).font(.caption).foregroundStyle(CloudTheme.muted)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

private struct PlanPlaybackView: View {
    @EnvironmentObject private var model: AppModel
    let anime: Anime
    @State private var episode: Episode?
    @State private var episodes: [Episode] = []
    @State private var offline = false
    @State private var errorMessage: String?
    @State private var retry = UUID()
    var body: some View {
        Group {
            if let episode {
                PlayerSheet(anime: anime, initialEpisode: episode, episodes: episodes, library: model.library,
                            progressStore: model.playbackProgress, downloadedPlayback: offline)
            } else {
                VStack(spacing: 16) {
                    if let errorMessage {
                        Text(errorMessage)
                        Button("Try again") { retry = UUID() }.frame(minHeight: 44)
                    } else { ProgressView("Finding your next episode…") }
                }.padding(24)
            }
        }
        .task(id: retry) {
            errorMessage = nil
            let detail = try? await model.api.animeDetail(id: anime.id)
            guard !Task.isCancelled else { return }
            episodes = detail?.episodes ?? model.downloads.records.values.filter {
                $0.anime.id == anime.id && model.downloads.localURL(for: $0.id) != nil
            }.sorted { $0.catalogPosition < $1.catalogPosition }.map(\.episode)
            offline = detail == nil
            episode = model.playbackProgress.episodeToContinue(in: episodes, library: model.library) ?? episodes.last
            if episode == nil { errorMessage = "No playable episodes could be loaded for this part. Try again when connected or open its downloaded episodes." }
        }
    }
}

struct ContinueWatchPlanCard: View {
    @ObservedObject var store: WatchPlanStore
    @ObservedObject var library: LibraryStore
    var body: some View {
        if let plan = store.plans.first(where: { store.nextStep(in: $0, library: library) != nil }),
           let next = store.nextStep(in: plan, library: library) {
            NavigationLink { SavedWatchPlanView(planID: plan.id, store: store, library: library) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Label("CONTINUE YOUR WATCH PLAN", systemImage: "list.number").font(.caption.weight(.bold))
                    Text(plan.title).font(.headline)
                    Text("Next: \(next.anime?.name ?? next.title)").font(.subheadline)
                }
                .foregroundStyle(CloudTheme.cyan).frame(maxWidth: .infinity, alignment: .leading)
                .padding(18).cloudPanel()
            }.buttonStyle(.plain).padding(.horizontal, 20)
        }
    }
}
