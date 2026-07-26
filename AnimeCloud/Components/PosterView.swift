import SwiftUI

struct PosterView: View {
    let anime: Anime
    var width: CGFloat = 142
    var height: CGFloat = 204

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            RemoteArtwork(url: anime.imageURL)
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if let year = anime.year, !year.isEmpty {
                        Text(year)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(8)
                    }
                }
            Text(anime.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .frame(width: width, alignment: .leading)
            if !anime.subtitle.isEmpty {
                Text(anime.subtitle)
                    .font(.caption)
                    .foregroundStyle(CloudTheme.muted)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct RemoteArtwork: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFill()
            case .failure: placeholder
            case .empty: placeholder.overlay { ProgressView().tint(.white.opacity(0.7)) }
            @unknown default: placeholder
            }
        }
        .clipped()
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [CloudTheme.panel, CloudTheme.violet.opacity(0.45)], startPoint: .top, endPoint: .bottom)
            Image(systemName: "cloud.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.25))
        }
    }
}

struct SectionHeading: View {
    var title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.bold())
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(CloudTheme.muted) }
            }
            Spacer()
        }
    }
}

struct EmptyCloud: View {
    var title: String
    var detail: String
    var systemImage: String = "cloud"

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(detail))
            .foregroundStyle(.white)
    }
}
