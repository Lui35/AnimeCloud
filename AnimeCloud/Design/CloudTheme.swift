import SwiftUI

enum CloudTheme {
    static let ink = Color(red: 0.035, green: 0.055, blue: 0.098)
    static let panel = Color(red: 0.075, green: 0.095, blue: 0.155)
    static let violet = Color(red: 0.49, green: 0.31, blue: 0.98)
    static let cyan = Color(red: 0.18, green: 0.78, blue: 0.94)
    static let coral = Color(red: 1.0, green: 0.39, blue: 0.46)
    static let muted = Color.white.opacity(0.62)
    static let heroGradient = LinearGradient(
        colors: [violet, Color(red: 0.20, green: 0.37, blue: 0.90), cyan],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct CloudBackground: View {
    var body: some View {
        ZStack {
            CloudTheme.ink.ignoresSafeArea()
            Circle()
                .fill(CloudTheme.violet.opacity(0.20))
                .frame(width: 340)
                .blur(radius: 90)
                .offset(x: 170, y: -320)
            Circle()
                .fill(CloudTheme.cyan.opacity(0.10))
                .frame(width: 260)
                .blur(radius: 80)
                .offset(x: -170, y: 300)
        }
    }
}

extension View {
    func cloudPanel() -> some View {
        self
            .background(CloudTheme.panel.opacity(0.82), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
    }
}

struct CloudLogo: View {
    var size: CGFloat = 42

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .fill(CloudTheme.heroGradient)
            Image(systemName: "cloud.fill")
                .font(.system(size: size * 0.47, weight: .bold))
                .foregroundStyle(.white)
            Image(systemName: "play.fill")
                .font(.system(size: size * 0.17, weight: .black))
                .foregroundStyle(CloudTheme.violet)
                .offset(y: 1)
        }
        .frame(width: size, height: size)
        .shadow(color: CloudTheme.violet.opacity(0.38), radius: 18, y: 8)
    }
}
