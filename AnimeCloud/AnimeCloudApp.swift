import SwiftUI

@main
struct AnimeCloudApp: App {
    @UIApplicationDelegateAdaptor(DownloadAppDelegate.self) private var downloadDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AppModel.live
    @State private var isLaunching = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environmentObject(model)

                if isLaunching {
                    LaunchExperienceView()
                        .transition(.opacity.combined(with: .scale(scale: 1.04)))
                        .zIndex(10)
                }
            }
            .preferredColorScheme(.dark)
            .task {
                guard isLaunching else { return }
                model.monitorConnectivity()
                Task { await model.downloads.restoreTransfers() }
                Task { await model.bootstrap() }
                try? await Task.sleep(for: .seconds(1.65))

                // Never trap someone behind the splash when a legacy endpoint is slow.
                for _ in 0..<10 where model.isBootstrapping {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                withAnimation(.easeInOut(duration: 0.45)) { isLaunching = false }
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active, !isLaunching else { return }
                Task { await model.syncCloudInBackground() }
            }
        }
    }
}

final class DownloadAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        AppModel.live.downloads.handleBackgroundEvents(identifier: identifier, completion: completionHandler)
    }
}
