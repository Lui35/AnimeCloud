import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedTab = 0
    @State private var showingAI = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            TabView(selection: $selectedTab) {
                HomeView().tag(0).tabItem { Label("Home", systemImage: "sparkles.tv") }
                DiscoverView().tag(1).tabItem { Label("Discover", systemImage: "safari") }
                ScheduleView().tag(2).tabItem { Label("Schedule", systemImage: "calendar") }
                LibraryView(store: model.library).tag(3).tabItem { Label("Library", systemImage: "rectangle.stack.fill") }
                ProfileView().tag(4).tabItem { Label("You", systemImage: "person.crop.circle") }
            }
            .tint(CloudTheme.cyan)

            Button { showingAI = true } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(CloudTheme.heroGradient, in: Circle())
                    .shadow(color: CloudTheme.violet.opacity(0.55), radius: 18, y: 8)
            }
            .padding(.trailing, 18)
            .padding(.bottom, 72)
            .accessibilityLabel("Ask Anime Cloud")
        }
        .sheet(isPresented: $showingAI) { DiscoveryAssistantView() }
        .alert(item: $model.message) { message in
            Alert(title: Text(message.title), message: Text(message.detail), dismissButton: .default(Text("OK")))
        }
    }
}
