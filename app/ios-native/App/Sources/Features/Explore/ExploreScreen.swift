import AniCore
import SwiftUI

@MainActor
@Observable
final class ExploreModel {
    private(set) var trending: [AniSubject] = []
    private(set) var trendingError: String?
    private(set) var isLoadingTrending = true
    private(set) var spotlight: AniSeasonSpotlight?
    private(set) var schedule: [AniScheduleDay] = []
    private(set) var scheduleError: String?

    func loadTrending(core: AniClient) async {
        trendingError = nil
        isLoadingTrending = true
        defer { isLoadingTrending = false }
        do {
            let subjects = try await core.trendingSubjects()
            try Task.checkCancellation()
            trending = subjects
        } catch {
            if !Task.isCancelled { trendingError = error.localizedDescription }
        }
    }

    func loadSpotlight(core: AniClient) async {
        if let result = try? await core.seasonSpotlight(), !Task.isCancelled {
            spotlight = result
        }
    }

    func observeSchedule(core: AniClient) async {
        scheduleError = nil
        for await update in core.scheduleUpdates() {
            if let days = update.days {
                schedule = days
            } else {
                scheduleError = update.error
            }
        }
    }
}

struct ExploreScreen: View {
    @Environment(AppServices.self) private var services
    @State private var model = ExploreModel()
    @State private var showsSchedule = false
    @State private var selectedSubject: SubjectRoute?

    var body: some View {
        let features = model.spotlight?.items.map { item in
            ExploreGalleryItem(id: item.subjectId, title: item.title, coverURL: item.coverUrl, backdropURL: item.backdropUrl)
        } ?? []
        ExploreGallery(
            features: features,
            seasonTitle: seasonTitle,
            trending: model.trending.map {
                ExploreGalleryItem(id: $0.id, title: $0.displayName, coverURL: $0.imageUrl)
            },
            isLoading: model.isLoadingTrending,
            error: model.trendingError,
            onSelect: {
                selectedSubject = SubjectRoute(id: $0.id, name: $0.title, imageUrl: $0.coverURL)
            },
            onShowSchedule: { showsSchedule = true },
            onRefresh: reload
        )
        .toolbarVisibility(.hidden, for: .navigationBar)
        .navigationDestination(item: $selectedSubject) { route in
            SubjectScreen(route: route)
                .toolbarVisibility(.visible, for: .navigationBar)
        }
        .navigationDestination(isPresented: $showsSchedule) {
            ScheduleView(model: model)
                .navigationTitle("时间表")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarVisibility(.visible, for: .navigationBar)
        }
        .task {
            if model.trending.isEmpty && model.spotlight == nil {
                await reload()
            } else if model.spotlight == nil {
                await model.loadSpotlight(core: services.core)
            }
        }
    }

    private var seasonTitle: String {
        guard let spotlight = model.spotlight else { return "" }
        let seasons: [Int32: String] = [1: "冬季", 2: "春季", 3: "夏季", 4: "秋季"]
        return "\(spotlight.year) \(seasons[spotlight.quarter] ?? "")"
    }

    private func reload() async {
        async let trending: Void = model.loadTrending(core: services.core)
        async let spotlight: Void = model.loadSpotlight(core: services.core)
        _ = await (trending, spotlight)
    }
}

private struct ScheduleView: View {
    let model: ExploreModel
    @Environment(AppServices.self) private var services
    @State private var selectedDate: String?

    private static let today = ScheduleFormat.dateKey(Date())

    private var currentDay: AniScheduleDay? {
        let key = selectedDate ?? Self.today
        return model.schedule.first { $0.date == key } ?? model.schedule.first
    }

    var body: some View {
        // 列表作为页面的主滚动视图, 导航栏据此使用滚动边缘效果 (没有底部分割线);
        // 日期条作为列表顶部的栏, 列表滚到它下方时同样由滚动边缘效果过渡
        List(currentDay?.items ?? [], id: \.episodeId) { item in
            NavigationLink(value: SubjectRoute(id: item.subjectId, name: item.subjectName, imageUrl: item.imageUrl)) {
                ScheduleRow(item: item)
            }
            .listRowInsets(ScheduleRow.insets)
            // 分隔线与行内容同宽: 起止于左右内边距处, 不随内容变化
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width }
        }
        .listStyle(.plain)
        // 底部悬浮的标签栏 (含最小化后的悬浮按钮) 之上再留出空间, 最后一项能完整滚动到它上方
        .contentMargins(.bottom, ScheduleRow.floatingBarClearance, for: .scrollContent)
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
        .task { await model.observeSchedule(core: services.core) }
        .safeAreaBar(edge: .top, spacing: 0) {
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
        }
    }
}

/// 时间表的一行: 放送时间、封面及剧集信息。
private struct ScheduleRow: View {
    let item: AniScheduleItem

    static let insets = EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
    static let floatingBarClearance: CGFloat = 72

    @ScaledMetric(relativeTo: .body) private var coverWidth: CGFloat = 48
    @ScaledMetric(relativeTo: .body) private var coverHeight: CGFloat = 68
    @ScaledMetric(relativeTo: .body) private var columnSpacing: CGFloat = 12

    var body: some View {
        HStack(alignment: .center, spacing: columnSpacing) {
            timeColumn
            CoverImage(url: item.imageUrl)
                .frame(width: coverWidth, height: coverHeight)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.subjectName)
                    .font(.body)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: coverHeight)
        .accessibilityElement(children: .combine)
    }

    private var timeColumn: some View {
        ZStack(alignment: .trailing) {
            // 只用于撑出固定列宽
            Text(verbatim: "88:88").hidden()
            Text(item.timeKnown ? ScheduleFormat.time(item.airingTimeMillis) : "--:--")
                .foregroundStyle(.secondary)
        }
        .font(.callout.monospacedDigit())
        .lineLimit(1)
        .fixedSize()
    }

    private var subtitle: String {
        item.episodeName.isEmpty ? "第 \(item.episodeSort) 话" : "\(item.episodeSort) · \(item.episodeName)"
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

    /// 固定 24 小时制 "HH:mm" (如 "00:05", "20:30"), 与系统 12/24 小时设置无关, 时间列宽度因此恒定.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func time(_ epochMillis: Int64) -> String {
        timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(epochMillis) / 1000))
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
