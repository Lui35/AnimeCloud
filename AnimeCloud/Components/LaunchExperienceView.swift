import SwiftUI

struct LaunchExperienceView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false
    @State private var progress: CGFloat = 0.12

    var body: some View {
        ZStack {
            CloudTheme.ink.ignoresSafeArea()

            Circle()
                .fill(CloudTheme.violet.opacity(0.28))
                .frame(width: 390, height: 390)
                .blur(radius: 95)
                .offset(x: 150, y: -250)

            Circle()
                .fill(CloudTheme.cyan.opacity(0.16))
                .frame(width: 330, height: 330)
                .blur(radius: 90)
                .offset(x: -150, y: 290)

            VStack(spacing: 0) {
                Spacer()

                ZStack {
                    Circle()
                        .stroke(CloudTheme.cyan.opacity(0.14), lineWidth: 1)
                        .frame(width: 176, height: 176)
                        .scaleEffect(isAnimating ? 1.12 : 0.88)
                        .opacity(isAnimating ? 0.05 : 0.8)

                    Circle()
                        .trim(from: 0.08, to: 0.72)
                        .stroke(CloudTheme.heroGradient, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 142, height: 142)
                        .rotationEffect(.degrees(isAnimating ? 360 : 0))

                    CloudLogo(size: 94)
                        .scaleEffect(isAnimating ? 1 : 0.92)
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 1.25).repeatForever(autoreverses: true), value: isAnimating)

                Text("ANIME CLOUD")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .tracking(5)
                    .padding(.top, 32)

                Text("Stories, synced across the sky")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(CloudTheme.muted)
                    .padding(.top, 9)

                Spacer()

                VStack(spacing: 12) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Color.white.opacity(0.09))
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(CloudTheme.heroGradient)
                                    .frame(width: proxy.size.width * progress)
                            }
                    }
                    .frame(width: 148, height: 4)

                    Text("CONNECTING TO YOUR CLOUD")
                        .font(.caption2.weight(.bold))
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.48))
                }
                .padding(.bottom, 46)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Anime Cloud is loading")
        .onAppear {
            isAnimating = true
            withAnimation(.easeInOut(duration: 1.55)) { progress = 0.94 }
        }
    }
}

#Preview {
    LaunchExperienceView()
        .preferredColorScheme(.dark)
}
