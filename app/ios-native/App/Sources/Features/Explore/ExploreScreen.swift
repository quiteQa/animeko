import AniCore
import SwiftUI

@MainActor
@Observable
final class ExploreModel {
    private(set) var trending: [AniSubject] = []
    private(set) var trendingError: String?
    private(set) var schedule: [AniScheduleDay] = []
    private(set) var scheduleError: String?

    func loadTrending(core: AniCore) async {
        trendingError = nil
        do {
            trending = try await core.trendingSubjects()
        } catch {
            trendingError = error.localizedDescription
        }
    }

    func observeSchedule(core: AniCore) async {
        scheduleError = nil
        for await update in core.scheduleUpdates {
            switch update {
            case .value(let days): schedule = days
            case .failure(let message): scheduleError = message
            }
        }
    }
}

struct ExploreScreen: View {
    private enum Page: Hashable { case trending, schedule }

    @Environment(AppServices.self) private var services
    @State private var model = ExploreModel()
    @State private var page: Page = .trending

    var body: some View {
        Group {
            switch page {
            case .trending: TrendingGrid(model: model)
            case .schedule: ScheduleView(model: model)
            }
        }
        .navigationTitle("探索")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("页面", selection: $page) {
                    Text("热门").tag(Page.trending)
                    Text("时间表").tag(Page.schedule)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        .task { await model.loadTrending(core: services.core) }
        .task { await model.observeSchedule(core: services.core) }
    }
}

private struct TrendingGrid: View {
    let model: ExploreModel
    @Environment(AppServices.self) private var services

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 12)], spacing: 16) {
                ForEach(model.trending, id: \.id) { subject in
                    NavigationLink(value: SubjectRoute(subject)) {
                        VStack(alignment: .leading, spacing: 6) {
                            CoverImage(url: subject.imageUrl)
                                .aspectRatio(0.7, contentMode: .fit)
                            Text(subject.displayName)
                                .font(.footnote)
                                .lineLimit(2, reservesSpace: true)
                                .foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .refreshable { await model.loadTrending(core: services.core) }
        .overlay {
            if model.trending.isEmpty {
                if let message = model.trendingError {
                    ContentUnavailableView {
                        Label("加载失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("重试") { Task { await model.loadTrending(core: services.core) } }
                    }
                } else {
                    ProgressView()
                }
            }
        }
    }
}

private struct ScheduleView: View {
    let model: ExploreModel
    @State private var selectedDate: String?

    private static let today = ScheduleFormat.dateKey(Date())

    private var currentDay: AniScheduleDay? {
        let key = selectedDate ?? Self.today
        return model.schedule.first { $0.date == key } ?? model.schedule.first
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.schedule, id: \.date) { day in
                            DayButton(
                                day: day,
                                today: Self.today,
                                isSelected: day.date == currentDay?.date,
                            ) {
                                selectedDate = day.date
                            }
                            .id(day.date)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .onAppear { proxy.scrollTo(Self.today, anchor: .center) }
            }

            List(currentDay?.items ?? [], id: \.episodeId) { item in
                NavigationLink(value: SubjectRoute(id: item.subjectId, name: item.subjectName, imageUrl: item.imageUrl)) {
                    HStack(spacing: 12) {
                        Text(item.timeKnown ? ScheduleFormat.time(item.airingTimeMillis) : "--:--")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                        CoverImage(url: item.imageUrl)
                            .frame(width: 44, height: 62)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.subjectName).lineLimit(2)
                            Text(item.episodeName.isEmpty ? "第 \(item.episodeSort) 话" : "\(item.episodeSort) · \(item.episodeName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if model.schedule.isEmpty {
                    if let message = model.scheduleError {
                        ContentUnavailableView("加载失败", systemImage: "calendar.badge.exclamationmark", description: Text(message))
                    } else {
                        ProgressView()
                    }
                } else if currentDay?.items.isEmpty == true {
                    ContentUnavailableView("这天没有放送", systemImage: "calendar")
                }
            }
        }
    }
}

/// 时间表的日期与时间格式. 日期键为 `yyyy-MM-dd` (与 Kotlin 侧 `LocalDate.toString()` 一致).
enum ScheduleFormat {
    private static let keyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func dateKey(_ date: Date) -> String { keyFormatter.string(from: date) }

    static func date(_ key: String) -> Date? { keyFormatter.date(from: key) }

    static func weekday(_ key: String, today: String) -> String {
        if key == today { return "今天" }
        guard let date = date(key) else { return "" }
        return date.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "zh_CN")))
    }

    static func monthDay(_ key: String) -> String {
        guard let date = date(key) else { return key }
        return date.formatted(.dateTime.month(.defaultDigits).day())
    }

    static func time(_ epochMillis: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(epochMillis) / 1000)
            .formatted(date: .omitted, time: .shortened)
    }
}

private struct DayButton: View {
    let day: AniScheduleDay
    let today: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        if isSelected {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.glass)
        }
    }

    private var button: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(ScheduleFormat.weekday(day.date, today: today))
                    .font(.caption)
                Text(ScheduleFormat.monthDay(day.date))
                    .font(.subheadline.monospacedDigit())
            }
            .frame(minWidth: 52)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
