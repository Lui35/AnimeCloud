import SwiftUI

struct ScheduleView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedDay: String?

    private let dayNames = ["1": "Sunday", "2": "Monday", "3": "Tuesday", "4": "Wednesday", "5": "Thursday", "6": "Friday", "7": "Saturday"]

    var body: some View {
        NavigationStack {
            ZStack {
                CloudBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        dayStrip
                        if displayed.isEmpty {
                            EmptyCloud(title: "Nothing scheduled", detail: "Choose another day or pull Home to refresh the schedule.", systemImage: "calendar.badge.exclamationmark")
                                .frame(height: 420)
                        } else {
                            ForEach(displayed) { anime in
                                NavigationLink(value: anime) {
                                    HStack(spacing: 14) {
                                        RemoteArtwork(url: anime.imageURL).frame(width: 90, height: 122).clipShape(RoundedRectangle(cornerRadius: 16))
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(anime.name).font(.headline).multilineTextAlignment(.leading)
                                            Text(anime.subtitle).font(.caption).foregroundStyle(CloudTheme.muted)
                                            Label(dayNames[anime.day ?? ""] ?? "Scheduled", systemImage: "clock")
                                                .font(.caption.weight(.semibold)).foregroundStyle(CloudTheme.cyan)
                                        }
                                        Spacer(); Image(systemName: "chevron.right").foregroundStyle(CloudTheme.muted)
                                    }.padding(11).cloudPanel()
                                }.buttonStyle(.plain)
                            }
                        }
                    }.padding(18).padding(.bottom, 100)
                }
            }
            .navigationTitle("Weekly drops")
            .navigationDestination(for: Anime.self) { AnimeDetailView(anime: $0, library: model.library) }
        }
    }

    private var displayed: [Anime] {
        guard let selectedDay else { return model.schedule }
        return model.schedule.filter { $0.day == selectedDay }
    }

    private var dayStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                dayButton("All", value: nil)
                ForEach((1...7).map(String.init), id: \.self) { day in dayButton(String((dayNames[day] ?? "Day").prefix(3)), value: day) }
            }
        }
    }

    private func dayButton(_ title: String, value: String?) -> some View {
        Button(title) { selectedDay = value }
            .font(.subheadline.weight(.bold)).padding(.horizontal, 14).padding(.vertical, 10)
            .background(selectedDay == value ? AnyShapeStyle(CloudTheme.heroGradient) : AnyShapeStyle(CloudTheme.panel), in: Capsule())
            .foregroundStyle(.white)
    }
}
