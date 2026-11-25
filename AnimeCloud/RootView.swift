import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(library: model.library).tag(0).tabItem { Label("Home", systemImage: "sparkles.tv") }
            DiscoverView().tag(1).tabItem { Label("Discover", systemImage: "safari") }
            WatchPlansView(store: model.watchPlans, library: model.library)
                .tag(2).tabItem { Label("Plans", systemImage: "list.number") }
            LibraryView(store: model.library, isActive: selectedTab == 3)
                .tag(3).tabItem { Label("Library", systemImage: "rectangle.stack.fill") }
            ProfileView().tag(4).tabItem { Label("You", systemImage: "person.crop.circle") }
        }
        .tint(CloudTheme.cyan)
        .alert(item: $model.message) { message in
            Alert(title: Text(message.title), message: Text(message.detail), dismissButton: .default(Text("OK")))
        }
    }
}
