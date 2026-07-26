import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingLogin = false
    @State private var showingRecovery = false

    var body: some View {
        NavigationStack {
            ZStack {
                CloudBackground()
                ScrollView {
                    VStack(spacing: 22) {
                        identity
                        stats
                        settings
                    }.padding(20).padding(.bottom, 100)
                }
            }
            .navigationTitle("You")
        }
        .sheet(isPresented: $showingLogin) { LoginView() }
        .sheet(isPresented: $showingRecovery) { PasswordRecoveryView() }
    }

    private var identity: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(CloudTheme.heroGradient).frame(width: 92, height: 92)
                Text(model.session?.username.prefix(1).uppercased() ?? "☁︎").font(.system(size: 36, weight: .black))
            }
            Text(model.session?.username ?? "Guest dreamer").font(.title2.bold())
            Text(model.session?.email ?? "Sign in to sync your library and join discussions")
                .font(.subheadline).foregroundStyle(CloudTheme.muted).multilineTextAlignment(.center)
            if model.session == nil {
                Button("Sign in to Anime Cloud") { showingLogin = true }.buttonStyle(PrimaryCapsuleStyle())
            } else {
                Text("CLOUD MEMBER").font(.caption2.weight(.black)).tracking(1.6).foregroundStyle(CloudTheme.cyan)
            }
        }.frame(maxWidth: .infinity).padding(24).cloudPanel()
    }

    private var stats: some View {
        HStack(spacing: 10) {
            stat("Saved", value: model.library.favorites.count, icon: "heart.fill")
            stat("Watched", value: model.library.seenEpisodeIDs.count, icon: "checkmark.circle.fill")
            stat("Explored", value: model.library.recentAnime.count, icon: "safari.fill")
        }
    }

    private func stat(_ title: String, value: Int, icon: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon).foregroundStyle(CloudTheme.cyan)
            Text(String(value)).font(.title2.bold())
            Text(title).font(.caption2).foregroundStyle(CloudTheme.muted)
        }.frame(maxWidth: .infinity).padding(.vertical, 16).cloudPanel()
    }

    private var settings: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.triangle.2.circlepath.icloud").foregroundStyle(CloudTheme.cyan).frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Automatic cloud sync")
                    Text(model.cloudSyncStatus).font(.caption).foregroundStyle(CloudTheme.muted)
                }
                Spacer()
                if model.isCloudSyncing { ProgressView().controlSize(.small) }
                else { Image(systemName: model.session == nil ? "lock.fill" : "checkmark.circle.fill").foregroundStyle(CloudTheme.cyan) }
            }.padding(16)
            Divider().overlay(Color.white.opacity(0.08))
            setting("Sync library now", icon: "arrow.clockwise.icloud") { Task { await model.syncBackup() } }
            Divider().overlay(Color.white.opacity(0.08))
            setting("Recover password", icon: "key") { showingRecovery = true }
            Divider().overlay(Color.white.opacity(0.08))
            HStack(spacing: 14) {
                Image(systemName: "brain.head.profile").foregroundStyle(CloudTheme.cyan).frame(width: 24)
                VStack(alignment: .leading) { Text("AI discovery"); Text("Private catalog mode • Gemini-ready").font(.caption).foregroundStyle(CloudTheme.muted) }
                Spacer(); Image(systemName: "checkmark.seal.fill").foregroundStyle(CloudTheme.cyan)
            }.padding(16)
            if model.session != nil {
                Divider().overlay(Color.white.opacity(0.08))
                setting("Sign out", icon: "rectangle.portrait.and.arrow.right", role: .destructive) { model.logout() }
            }
        }.cloudPanel()
    }

    private func setting(_ title: String, icon: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 14) { Image(systemName: icon).frame(width: 24); Text(title); Spacer(); Image(systemName: "chevron.right").foregroundStyle(CloudTheme.muted) }
                .padding(16).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            ZStack {
                CloudBackground()
                VStack(spacing: 20) {
                    CloudLogo(size: 72)
                    Text("Return to your cloud").font(.title.bold())
                    TextField("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never).padding(15).cloudPanel()
                    SecureField("Password", text: $password).textContentType(.password).padding(15).cloudPanel()
                    Button { Task { await login() } } label: {
                        Group { if isLoading { ProgressView() } else { Text("Sign in").font(.headline) } }.frame(maxWidth: .infinity).frame(height: 50)
                    }.buttonStyle(.borderedProminent).tint(CloudTheme.violet).clipShape(Capsule()).disabled(email.isEmpty || password.isEmpty || isLoading)
                    Text("Your password goes only to the legacy Anime Cloud login server and is never stored by this app.")
                        .font(.caption).foregroundStyle(CloudTheme.muted).multilineTextAlignment(.center)
                    Spacer()
                }.padding(24)
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
        }
        .alert(item: $model.message) { message in
            Alert(title: Text(message.title), message: Text(message.detail), dismissButton: .default(Text("OK")))
        }
    }

    private func login() async {
        isLoading = true
        if await model.login(email: email, password: password) { dismiss() }
        isLoading = false
    }
}

private struct PasswordRecoveryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            ZStack {
                CloudBackground()
                VStack(spacing: 18) {
                    Image(systemName: "key.fill").font(.system(size: 44)).foregroundStyle(CloudTheme.cyan)
                    Text("Recover your account").font(.title2.bold())
                    TextField("Email", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never).padding(15).cloudPanel()
                    Button("Send recovery request") { Task { await recover() } }.buttonStyle(.borderedProminent).tint(CloudTheme.violet).disabled(email.isEmpty || isLoading)
                    Spacer()
                }.padding(24)
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
        }
    }

    private func recover() async {
        isLoading = true
        do {
            try await model.api.recoverPassword(email: email)
            model.message = AppMessage(title: "Request sent", detail: "Check your email for recovery instructions.")
            dismiss()
        } catch { model.message = AppMessage(error: error) }
        isLoading = false
    }
}
