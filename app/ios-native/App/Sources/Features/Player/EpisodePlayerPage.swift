import AniCore
import AVKit
import Combine
import SwiftUI

/// 播放页. 自上而下: 视频, 标题, 播放源, 弹幕源, 评论 (折叠), 剧集列表, 相关推荐.
///
/// 评论展开后占据弹幕源以下的全部空间, 单独滚动, 底部显示评论框; 剧集列表与相关推荐在收起评论后显示.
///
/// 视频固定在顶部, 其余内容在下方滚动. 页面持有 `PlayerModel` 与播放会话; 全屏是叠在页面之上的同一个 `AVPlayer`
/// 的另一个视图, 与界面旋转一起淡入淡出, 退出全屏后回到这里继续播放. 离开页面 (返回) 时结束播放.
/// iPhone 横过来时自动进入全屏.
struct EpisodePlayerPage: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var model: PlayerModel
    @State private var subject = SubjectModel()
    @State private var recommendations: [AniRecommendation] = []
    @State private var showsFullscreen = false
    @State private var showsSourcePicker = false
    @State private var showsDanmakuSources = false
    /// 本集评论; 切换剧集时重新创建.
    @State private var comments: CommentsModel?
    @State private var commentsExpanded = false

    init(target: PlaybackTarget) {
        _model = State(initialValue: PlayerModel(target: target))
    }

    private var currentSubject: AniSubject { subject.detail?.subject ?? model.target.subject }

    var body: some View {
        VStack(spacing: 0) {
            InlinePlayer(
                model: model,
                isCovered: showsFullscreen,
                onBack: { dismiss() },
                onFullscreen: enterFullscreen,
                onShowSources: { showsSourcePicker = true },
            )

            if commentsExpanded, let comments {
                // 评论展开: 上方信息固定, 评论列表占满其余高度并单独滚动, 底部是评论框
                details
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 10)
                EpisodeCommentList(model: comments)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        details
                        episodesAndRelated
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(Color(.systemGroupedBackground))
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .overlay {
            if showsFullscreen {
                PlayerScreen(model: model, onExitFullscreen: exitFullscreen) {
                    // 先转回竖屏, 再关闭播放页
                    OrientationLock.restorePortrait()
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        dismiss()
                    }
                }
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $showsSourcePicker) {
            SourcePickerSheet(model: model)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsDanmakuSources) {
            DanmakuSourcesSheet(model: model)
                .presentationDetents([.medium])
        }
        .overlay(alignment: .top) {
            if let message = model.toastMessage, !showsFullscreen {
                Text(message)
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation { model.toastMessage = nil }
                    }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            // 界面锁定竖屏, 设备方向通知仍会到达: 横过手机即进入全屏
            guard UIDevice.current.userInterfaceIdiom == .phone, !showsFullscreen, model.phase == .playing,
                  UIDevice.current.orientation.isLandscape else { return }
            enterFullscreen()
        }
        .onAppear { UIDevice.current.beginGeneratingDeviceOrientationNotifications() }
        .task {
            let services = services
            model.start(core: services.core, settings: { services.settings })
        }
        .task { await subject.observe(subjectId: model.target.subject.id, core: services.core) }
        .task(id: model.target.episode.id) {
            let episodeComments = CommentsModel(source: .episode(model.target.episode.id))
            comments = episodeComments
            await episodeComments.reload(core: services.core)
        }
        .onChange(of: subject.detail, initial: true) {
            model.episodes = subject.detail?.episodes ?? []
        }
        .task {
            recommendations = (try? await services.core.subjectRecommendations(subjectId: model.target.subject.id)) ?? []
        }
        .onDisappear {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            OrientationLock.restorePortrait()
            model.stop()
        }
    }

    /// 全屏画面淡入, 同时界面转为横屏; 两者在系统旋转动画中一起完成.
    private func enterFullscreen() {
        guard !showsFullscreen else { return }
        withAnimation(.easeInOut(duration: 0.25)) { showsFullscreen = true }
        OrientationLock.enterLandscape()
    }

    /// 界面先转回竖屏, 旋转期间仍显示全屏画面, 转完后再淡出, 避免页面在横屏尺寸下闪现.
    private func exitFullscreen() {
        guard showsFullscreen else { return }
        OrientationLock.restorePortrait()
        Task {
            try? await Task.sleep(for: .milliseconds(UIDevice.current.userInterfaceIdiom == .phone ? 350 : 0))
            withAnimation(.easeInOut(duration: 0.25)) { showsFullscreen = false }
        }
    }

    /// 标题, 播放源, 弹幕源与评论入口.
    private var details: some View {
        VStack(alignment: .leading, spacing: 24) {
            TitleSection(model: model, subject: subject, info: currentSubject)
            VStack(spacing: 10) {
                SourceRow(model: model) { showsSourcePicker = true }
                DanmakuRow(model: model) { showsDanmakuSources = true }
                CommentsRow(model: comments, isExpanded: commentsExpanded) {
                    withAnimation(.smooth(duration: 0.35)) { commentsExpanded.toggle() }
                }
            }
        }
    }

    @ViewBuilder
    private var episodesAndRelated: some View {
        EpisodeListSection(
            model: model,
            subject: currentSubject,
            episodes: subject.detail?.episodes ?? [],
            canEditWatched: services.isLoggedIn,
            onSetWatched: setWatched,
        )
        if !recommendations.isEmpty {
            RelatedSection(items: recommendations)
        }
    }

    private func setWatched(_ episode: AniEpisode, _ watched: Bool) {
        Task {
            await subject.setWatched(watched, episode: episode, subjectId: model.target.subject.id, core: services.core)
        }
    }
}

// MARK: - 视频

/// 页面顶部的 16:9 视频. 点按显示或隐藏控件.
///
/// 左上角返回; 右上角是更多选项; 中间播放/暂停; 底部进度, 弹幕开关与全屏.
/// 点按画面空白处显示或隐藏控件; 点按手势放在控件之下, 不与按钮争夺触摸.
/// 控件隐藏时底部保留一条细进度线.
private struct InlinePlayer: View {
    @Bindable var model: PlayerModel
    /// 全屏覆盖在上方时为 `true`; 此时内嵌画面不可见, 不做画质增强.
    let isCovered: Bool
    let onBack: () -> Void
    let onFullscreen: () -> Void
    let onShowSources: () -> Void

    @Environment(AppServices.self) private var services
    @State private var controlsVisible = true
    @State private var scrubbing: Double?
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black
            PlayerSurface(
                player: model.player,
                enhancementMode: isCovered ? .off : model.enhancementMode,
                onEnhancementUnavailable: enhancementUnavailable,
            )
            DanmakuOverlay(
                danmaku: model.visibleDanmaku(settings: services.settings),
                isEnabled: model.isDanmakuEnabled,
                showsColor: services.settings?.danmakuShowColor ?? true,
                currentTime: { [model] in model.playbackTime() },
            )
            Color.clear
                .contentShape(.rect)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
                    if controlsVisible { scheduleHide() }
                }
            status
            if controlsVisible {
                controls.transition(.opacity)
            } else {
                progressLine.transition(.opacity)
            }
            if model.showsStats {
                PlayerStatsOverlay(model: model)
                    .scaleEffect(0.85, anchor: .topLeading)
                    .padding(.top, controlsVisible ? 52 : 8)
                    .padding(.leading, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
        .background(Color.black.ignoresSafeArea(edges: .top))
        .environment(\.colorScheme, .dark)
        .onChange(of: model.isPlaying) { _, playing in
            if playing { scheduleHide() }
        }
    }

    private func enhancementUnavailable() {
        guard model.enhancementMode != .off else { return }
        model.enhancementMode = .off
        model.toastMessage = "当前视频无法使用画质增强"
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .playing:
            EmptyView()
        case .fetching, .resolving:
            VStack(spacing: 10) {
                ProgressView().controlSize(.large).tint(.white)
                Text(model.phase == .fetching ? "正在查找资源" : "正在解析视频")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
            }
        case .noSource, .failed:
            VStack(spacing: 10) {
                Image(systemName: model.phase == .noSource ? "rectangle.slash" : "exclamationmark.triangle")
                    .font(.title2)
                Text(model.phase == .noSource ? "没有找到可播放的资源" : failureMessage)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Button("选择其他资源", action: onShowSources)
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 32)
        }
    }

    private var failureMessage: String {
        if case .failed(let message) = model.phase { return message }
        return ""
    }

    private var progressFraction: Double {
        guard model.duration > 0 else { return 0 }
        return min(max(model.currentTime / model.duration, 0), 1)
    }

    private var progressLine: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(.tint)
                .frame(width: proxy.size.width * progressFraction, height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .allowsHitTesting(false)
    }

    private var controls: some View {
        VStack(spacing: 0) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.backward")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 34, height: 34)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular, in: .circle)
                    .accessibilityLabel("返回")

                    Spacer()

                    PlayerMoreMenu(model: model) {
                        Image(systemName: "ellipsis")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 34, height: 34)
                            .contentShape(.circle)
                            .glassEffect(.regular, in: .circle)
                    }
                }
            }

            Spacer()

            if model.phase == .playing {
                Button {
                    model.togglePlayback()
                    scheduleHide()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 56, height: 56)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: .circle)
                .accessibilityLabel(model.isPlaying ? "暂停" : "播放")
            }

            Spacer()

            HStack(spacing: 10) {
                Text(TimeText.format(scrubbing ?? model.currentTime))
                    .font(.caption2.monospacedDigit())
                Slider(
                    value: Binding(
                        get: { scrubbing ?? model.currentTime },
                        set: { scrubbing = $0; scheduleHide() },
                    ),
                    in: 0...max(model.duration, 1),
                    onEditingChanged: { editing in
                        if !editing, let target = scrubbing {
                            model.seek(to: target)
                            scrubbing = nil
                        }
                    },
                )
                .controlSize(.small)
                .disabled(model.duration <= 0)
                .accessibilityLabel("播放进度")
                Text(TimeText.format(model.duration))
                    .font(.caption2.monospacedDigit())
                    .opacity(0.75)
                iconButton(
                    model.isDanmakuEnabled ? "captions.bubble.fill" : "captions.bubble",
                    label: model.isDanmakuEnabled ? "关闭弹幕" : "开启弹幕",
                ) {
                    model.isDanmakuEnabled.toggle()
                    scheduleHide()
                }
                iconButton("arrow.up.left.and.arrow.down.right", label: "全屏", action: onFullscreen)
            }
            .padding(.leading, 4)
        }
        .foregroundStyle(.white)
        .tint(.white)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .background {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.4), location: 0),
                    .init(color: .clear, location: 0.28),
                    .init(color: .clear, location: 0.68),
                    .init(color: .black.opacity(0.55), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom,
            )
            .allowsHitTesting(false)
        }
    }

    private func iconButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .frame(width: 36, height: 40)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, model.isPlaying else { return }
            withAnimation(.easeInOut(duration: 0.3)) { controlsVisible = false }
        }
    }
}

enum TimeText {
    static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - 标题

/// 番剧名 (点按进入条目详情), 当前剧集, 收藏按钮, 以及评分 / 开播时间 / 集数标签.
private struct TitleSection: View {
    let model: PlayerModel
    let subject: SubjectModel
    let info: AniSubject

    @Environment(AppServices.self) private var services

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                NavigationLink(value: SubjectRoute(info)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(info.displayName)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 6) {
                            Text("第 \(model.target.episode.sort) 话")
                                .fontWeight(.semibold)
                                .foregroundStyle(.tint)
                            Text(model.target.episode.displayName)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                if services.isLoggedIn {
                    FavoriteButton(subject: subject, subjectId: info.id)
                }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if !info.score.isEmpty {
                        MetaChip {
                            Image(systemName: "star.fill").foregroundStyle(.orange)
                            Text(info.score).fontWeight(.semibold).foregroundStyle(.primary)
                        }
                        .accessibilityLabel("评分 \(info.score)")
                    }
                    if let date = AirDateText.yearMonth(info.airDate) {
                        MetaChip { Text(date) }
                    }
                    if info.totalEpisodes > 0 {
                        MetaChip { Text("全 \(info.totalEpisodes) 话") }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct MetaChip<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 3) { content }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 7))
    }
}

enum AirDateText {
    /// `2023-10-6` → `2023 年 10 月`; 无法解析时返回 `nil`.
    static func yearMonth(_ date: String) -> String? {
        let parts = date.split(separator: "-")
        guard parts.count >= 2, let year = Int(parts[0]), let month = Int(parts[1]) else { return nil }
        return "\(year) 年 \(month) 月"
    }
}

/// 收藏按钮: 未收藏时显示「收藏」, 已收藏时显示收藏类型; 点按选择收藏类型.
private struct FavoriteButton: View {
    let subject: SubjectModel
    let subjectId: Int32

    @Environment(AppServices.self) private var services

    var body: some View {
        let current = subject.detail?.collectionType ?? .notCollected
        let collected = current != .notCollected
        Menu {
            Picker("收藏", selection: Binding(
                get: { current },
                set: { type in
                    Task { await subject.setCollectionType(type, subjectId: subjectId, core: services.core) }
                },
            )) {
                ForEach(AniCollectionType.selectable, id: \.self) { type in
                    Label(type.title, systemImage: type.systemImage).tag(type)
                }
            }
            if collected {
                Divider()
                Button("取消收藏", systemImage: "heart.slash", role: .destructive) {
                    Task { await subject.setCollectionType(.notCollected, subjectId: subjectId, core: services.core) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: collected ? "heart.fill" : "heart")
                Text(collected ? current.title : "收藏")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.12), in: .capsule)
            .contentShape(.capsule)
        }
        .disabled(subject.detail == nil)
        .accessibilityLabel(collected ? "收藏状态: \(current.title)" : "收藏")
    }
}

// MARK: - 播放源与弹幕源

/// 折叠的一行卡片: 左侧图标, 小字说明在上, 主文字在下, 右侧附加内容.
private struct SelectorRow<Leading: View, Trailing: View>: View {
    let caption: String
    let title: String
    let action: () -> Void
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                leading
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .padding(.vertical, 11)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

/// 播放源: 显示当前数据源与清晰度; 点按打开选源面板.
private struct SourceRow: View {
    let model: PlayerModel
    let action: () -> Void

    var body: some View {
        SelectorRow(caption: "播放源", title: title, action: action) {
            if let selected = model.selected {
                SourceBadge(name: model.sourceName(selected.mediaSourceId))
            } else if model.phase == .fetching {
                ProgressView()
            } else {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
            }
        } trailing: {
            HStack(spacing: 2) {
                Text("切换")
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold))
            }
            .font(.subheadline)
            .foregroundStyle(.tint)
        }
    }

    private var title: String {
        guard let selected = model.selected else {
            if model.phase == .fetching {
                return model.progress.map { "正在查询数据源 \($0.completed)/\($0.total)" } ?? "正在查询数据源"
            }
            return "请选择播放源"
        }
        return ([model.sourceName(selected.mediaSourceId), selected.resolution] + selected.subtitleLanguages.prefix(1))
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// 数据源没有统一的图标地址, 用名称首字加上由名称决定的颜色作为标识.
private struct SourceBadge: View {
    let name: String

    private static let palette: [Color] = [.pink, .orange, .teal, .indigo, .purple, .blue, .green]

    var body: some View {
        let seed = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        Circle()
            .fill(Self.palette[seed % Self.palette.count].gradient)
            .overlay {
                Text(String(name.prefix(1)).uppercased())
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// 弹幕源: 显示已启用的弹幕源数量与弹幕总数; 点按选择弹幕源.
private struct DanmakuRow: View {
    let model: PlayerModel
    let action: () -> Void

    var body: some View {
        let sources = model.danmakuSources
        let enabled = sources.filter { !model.disabledDanmakuSources.contains($0.id) }
        SelectorRow(caption: caption(enabled), title: title(sources: sources, enabled: enabled), action: action) {
            Circle()
                .fill(Color.accentColor.opacity(0.12))
                .overlay {
                    Image(systemName: model.isDanmakuEnabled ? "captions.bubble" : "captions.bubble.slash")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.tint)
                }
        } trailing: {
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private func caption(_ enabled: [DanmakuSource]) -> String {
        enabled.isEmpty ? "弹幕源" : "弹幕源 · " + enabled.map(\.name).joined(separator: "、")
    }

    private func title(sources: [DanmakuSource], enabled: [DanmakuSource]) -> String {
        if !model.isDanmakuEnabled { return "弹幕已关闭" }
        if sources.isEmpty { return model.phase == .playing ? "暂无弹幕" : "弹幕加载中" }
        return "\(enabled.count) 个弹幕源，共 \(model.enabledDanmakuCount.formatted()) 条"
    }
}

/// 弹幕源选择: 弹幕总开关, 以及每个弹幕源的开关与弹幕数量.
private struct DanmakuSourcesSheet: View {
    @Bindable var model: PlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("显示弹幕", isOn: $model.isDanmakuEnabled)
                }
                Section {
                    if model.danmakuSources.isEmpty {
                        Text("本集暂无弹幕").foregroundStyle(.secondary)
                    }
                    ForEach(model.danmakuSources) { source in
                        Toggle(isOn: binding(for: source)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name)
                                Text("\(source.count.formatted()) 条")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("弹幕源")
                } footer: {
                    Text("关闭的弹幕源只在本次播放中不显示。")
                }
                .disabled(!model.isDanmakuEnabled)
            }
            .navigationTitle("弹幕源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func binding(for source: DanmakuSource) -> Binding<Bool> {
        Binding(
            get: { !model.disabledDanmakuSources.contains(source.id) },
            set: { enabled in
                if enabled {
                    model.disabledDanmakuSources.remove(source.id)
                } else {
                    model.disabledDanmakuSources.insert(source.id)
                }
            },
        )
    }
}

// MARK: - 剧集列表

private struct SectionHeader: View {
    let title: String
    var trailing: String?
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Text(title)
                .font(.title3.weight(.bold))
            Spacer()
            if let trailing, let action {
                Button(action: action) {
                    HStack(spacing: 2) {
                        Text(trailing)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .font(.subheadline)
                }
            }
        }
    }
}

/// 「剧集列表」: 横向滚动的剧照卡片; 右上进入全部剧集.
private struct EpisodeListSection: View {
    let model: PlayerModel
    let subject: AniSubject
    let episodes: [AniEpisode]
    let canEditWatched: Bool
    let onSetWatched: (AniEpisode, Bool) -> Void

    @State private var showsAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(
                title: "剧集列表",
                trailing: episodes.isEmpty ? nil : "全 \(episodes.count) 话",
                action: { showsAll = true },
            )
            if episodes.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 79)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 10) {
                            ForEach(episodes, id: \.id) { episode in
                                EpisodeThumb(
                                    episode: episode,
                                    fallbackImageUrl: subject.imageUrl,
                                    isPlaying: episode.id == model.target.episode.id,
                                    animating: model.isPlaying,
                                    action: { model.play(episode: episode) },
                                )
                                .contextMenu { watchedMenu(for: episode) }
                                .id(episode.id)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .scrollClipDisabled()
                    .task(id: model.target.episode.id) {
                        proxy.scrollTo(model.target.episode.id, anchor: .leading)
                    }
                }
            }
        }
        .sheet(isPresented: $showsAll) {
            EpisodeGridSheet(
                episodes: episodes,
                playingId: model.target.episode.id,
                onSelect: { episode in
                    showsAll = false
                    model.play(episode: episode)
                },
            )
            .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private func watchedMenu(for episode: AniEpisode) -> some View {
        if !episode.displayName.isEmpty {
            Text(episode.displayName)
        }
        if canEditWatched {
            Button(
                episode.watched ? "取消看过" : "标记看过",
                systemImage: episode.watched ? "arrow.uturn.backward.circle" : "checkmark.circle",
            ) {
                onSetWatched(episode, !episode.watched)
            }
        }
    }
}

/// 剧集卡片 (16:9): 剧照为底 (没有剧照时用番剧封面), 底部渐变上叠集号与集名.
/// 正在播放的一集有强调色描边与跳动的音量条; 看过的集压暗并在右上角显示对勾.
private struct EpisodeThumb: View {
    let episode: AniEpisode
    let fallbackImageUrl: String
    let isPlaying: Bool
    let animating: Bool
    let action: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        Button(action: action) {
            Color(.tertiarySystemFill)
                .overlay {
                    AsyncImage(url: URL(string: episode.imageUrl.isEmpty ? fallbackImageUrl : episode.imageUrl)) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                }
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
                }
                .overlay {
                    if episode.watched, !isPlaying { Color.black.opacity(0.38) }
                }
                .overlay(alignment: .topTrailing) {
                    if episode.watched {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 5) {
                        if isPlaying {
                            Image(systemName: "chart.bar.fill")
                                .font(.caption2)
                                .foregroundStyle(.tint)
                                .symbolEffect(.variableColor.iterative, isActive: animating)
                        }
                        Text(episode.sort)
                            .font(.footnote.weight(.semibold).monospacedDigit())
                        Text(episode.displayName)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.bottom, 7)
                }
                .frame(width: 140, height: 79)
                .clipShape(shape)
                .overlay {
                    if isPlaying { shape.strokeBorder(.tint, lineWidth: 2.5) }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isPlaying ? .isSelected : [])
    }

    private var accessibilityText: String {
        var parts = ["第 \(episode.sort) 话"]
        if !episode.displayName.isEmpty { parts.append(episode.displayName) }
        if isPlaying { parts.append("正在播放") } else if episode.watched { parts.append("已看过") }
        return parts.joined(separator: ", ")
    }
}

/// 「选择剧集」: 全部剧集的网格.
private struct EpisodeGridSheet: View {
    let episodes: [AniEpisode]
    let playingId: Int32
    let onSelect: (AniEpisode) -> Void

    @ScaledMetric(relativeTo: .body) private var tileMinWidth: CGFloat = 64

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: tileMinWidth), spacing: 10)], spacing: 10) {
                        ForEach(episodes, id: \.id) { episode in
                            let playing = episode.id == playingId
                            Button {
                                onSelect(episode)
                            } label: {
                                Text(episode.sort)
                                    .font(.body.weight(.semibold).monospacedDigit())
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                    .frame(maxWidth: .infinity, minHeight: 48)
                                    .foregroundStyle(
                                        playing ? AnyShapeStyle(.white)
                                            : episode.watched ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary),
                                    )
                                    .background(
                                        playing ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.secondarySystemBackground)),
                                        in: .rect(cornerRadius: 10),
                                    )
                            }
                            .buttonStyle(.plain)
                            .id(episode.id)
                            .accessibilityLabel(episode.displayName.isEmpty ? "第 \(episode.sort) 话" : "第 \(episode.sort) 话, \(episode.displayName)")
                            .accessibilityAddTraits(playing ? .isSelected : [])
                        }
                    }
                    .padding(16)
                }
                .onAppear { proxy.scrollTo(playingId, anchor: .center) }
            }
            .navigationTitle("选择剧集")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - 相关推荐

/// 「相关推荐」: 横向滚动的竖版封面. 站内条目进入条目详情, 其他推荐打开外部链接.
private struct RelatedSection: View {
    let items: [AniRecommendation]

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "相关推荐")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        if let id = item.subjectId?.int32Value {
                            NavigationLink(value: SubjectRoute(id: id, name: item.name, imageUrl: item.imageUrl)) {
                                poster(item)
                            }
                            .buttonStyle(.plain)
                        } else if let uri = item.uri, let url = URL(string: uri) {
                            Button { openURL(url) } label: { poster(item) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    private func poster(_ item: AniRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverImage(url: item.imageUrl, cornerRadius: 12)
                .frame(width: 108, height: 152)
                .shadow(color: .black.opacity(0.12), radius: 5, y: 4)
            Text(item.name)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text([item.desc1, item.desc2].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 108, alignment: .leading)
        .contentShape(.rect)
    }
}

// MARK: - 评论

/// 评论入口: 收起时显示最新一条评论的摘要, 点按展开; 展开时点按收起.
private struct CommentsRow: View {
    let model: CommentsModel?
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        SelectorRow(caption: caption, title: title, action: action) {
            Circle()
                .fill(Color.accentColor.opacity(0.12))
                .overlay {
                    Image(systemName: "text.bubble")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.tint)
                }
        } trailing: {
            Image(systemName: "chevron.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
        .accessibilityHint(isExpanded ? "收起评论" : "展开评论")
    }

    private var caption: String {
        guard let model, !model.items.isEmpty else { return "评论" }
        return model.reachedEnd ? "评论 · \(model.items.count) 条" : "评论 · \(model.items.count)+ 条"
    }

    private var title: String {
        if isExpanded { return "收起评论" }
        guard let model else { return "加载中" }
        if let first = model.items.first {
            let name = first.authorName.isEmpty ? "匿名" : first.authorName
            return "\(name): \(first.text.replacingOccurrences(of: "\n", with: " "))"
        }
        if model.isLoading { return "加载中" }
        return model.errorMessage == nil ? "还没有评论, 来说两句" : "评论加载失败, 点按重试"
    }
}

/// 展开后的评论列表: 占满剩余高度, 滚动到底部时加载更多; 底部是评论框 (未登录时提示登录).
private struct EpisodeCommentList: View {
    let model: CommentsModel
    @Environment(AppServices.self) private var services

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.items, id: \.id) { comment in
                    CommentRow(comment: comment)
                        .padding(.vertical, 12)
                        .onAppear {
                            if comment.id == model.items.last?.id {
                                Task { await model.loadMore(core: services.core) }
                            }
                        }
                    Divider()
                }
                if model.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                if let message = model.errorMessage {
                    Button {
                        Task { await model.reload(core: services.core) }
                    } label: {
                        Label("\(message) · 点按重试", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 16)
                }
                if model.items.isEmpty, !model.isLoading, model.errorMessage == nil {
                    ContentUnavailableView("还没有评论", systemImage: "text.bubble", description: Text("来发表第一条评论吧"))
                        .padding(.top, 24)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.automatic)
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await model.reload(core: services.core) }
        .safeAreaInset(edge: .bottom) {
            if services.isLoggedIn {
                CommentComposer(model: model)
                    .padding(.top, -8)
                    .background(.bar)
            } else {
                Label("登录后可以发表评论", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.bar)
            }
        }
    }
}
