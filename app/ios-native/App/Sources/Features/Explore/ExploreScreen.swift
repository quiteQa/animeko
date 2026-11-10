import AniCore
import SwiftUI

@MainActor
@Observable
final class ExploreModel {
    private(set) var trending: [AniSubject] = []
    private(set) var trendingError: String?
    private(set) var schedule: [AniScheduleDay] = []
    private(set) var scheduleError: String?

    func loadTrending(core: AniClient) async {
        trendingError = nil
        do {
            trending = try await core.trendingSubjects()
        } catch {
            trendingError = error.localizedDescription
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
        // 不绘制导航栏背景, 也就没有底部的分割线; 内容滚到栏下时由系统的滚动边缘效果过渡
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
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

    /// 固定三列, 行列间距相同.
    private static let spacing: CGFloat = 12
    private static let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: 3)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Self.columns, spacing: Self.spacing) {
                ForEach(model.trending, id: \.id) { subject in
                    NavigationLink(value: SubjectRoute(subject)) {
                        PosterCard(title: subject.displayName, imageUrl: subject.imageUrl)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
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
        }
    }
}

/// 时间表的一行: 「时间 | 封面 | 标题与副标题 | (系统) 右箭头」四列.
///
/// 时间列宽由隐藏的模板文字 "88:88" 决定 (等宽数字, 随动态字体缩放), 不随实际时间文字长短变化;
/// 封面固定尺寸; 文字列占满剩余宽度. 各列在行内垂直居中, 行高至少为封面高度, 因此各行等高.
/// 标题嵌入封面的番剧卡片.
///
/// 卡片尺寸只由列宽和固定宽高比决定: 图片在占位底色上按比例填满并裁剪, 渐变与标题都是叠加层,
/// 因此标题行数不影响卡片尺寸. 封面, 渐变和标题一起裁切在圆角内.
private struct PosterCard: View {
    let title: String
    let imageUrl: String

    static let aspectRatio: CGFloat = 0.7
    static let cornerRadius: CGFloat = 16

    @ScaledMetric(relativeTo: .subheadline) private var titleInset: CGFloat = 10

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(Self.aspectRatio, contentMode: .fit)
            .overlay {
                AsyncImage(url: URL(string: imageUrl)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            }
            .overlay { Self.bottomScrim }
            .overlay(alignment: .bottomLeading) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .padding(titleInset)
            }
            .clipShape(.rect(cornerRadius: Self.cornerRadius, style: .continuous))
            .contentShape(.rect(cornerRadius: Self.cornerRadius, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
    }

    /// 覆盖卡片下方约三分之一的渐变: 从完全透明缓慢加深到半透明黑色, 多个色标让上缘没有明显分界.
    private static let bottomScrim = LinearGradient(
        stops: [
            .init(color: .black.opacity(0), location: 0.62),
            .init(color: .black.opacity(0.08), location: 0.70),
            .init(color: .black.opacity(0.22), location: 0.79),
            .init(color: .black.opacity(0.40), location: 0.88),
            .init(color: .black.opacity(0.58), location: 1.0),
        ],
        startPoint: .top,
        endPoint: .bottom,
    )
}

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
