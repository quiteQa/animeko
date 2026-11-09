import AniCore
import AVKit
import Combine
import SwiftUI

/// 播放页, 布局与上游 Animeko 的竖屏剧集页一致: 顶部 16:9 视频, 下方「详情 / 评论」两页.
///
/// 「详情」依次是番剧名与收藏按钮, 数据源摘要, 弹幕摘要和横向的剧集列表.
/// 页面持有 `PlayerModel` 与播放会话; 全屏只是同一个 `AVPlayer` 的另一个视图, 退出全屏后回到这里继续播放.
/// 离开页面 (返回) 时才结束播放. iPhone 横过来时自动进入全屏.
struct EpisodePlayerPage: View {
    fileprivate enum Tab: Hashable, CaseIterable {
        case details, comments

        var title: String {
            switch self {
            case .details: "详情"
            case .comments: "评论"
            }
        }
    }

    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var model: PlayerModel
    @State private var subject = SubjectModel()
    @State private var tab: Tab = .details
    @State private var showsFullscreen = false
    @State private var showsSourcePicker = false

    init(target: PlaybackTarget) {
        _model = State(initialValue: PlayerModel(target: target))
    }

    var body: some View {
        VStack(spacing: 0) {
            InlinePlayer(
                model: model,
                isCovered: showsFullscreen,
                onBack: { dismiss() },
                onFullscreen: { showsFullscreen = true },
                onShowSources: { showsSourcePicker = true },
            )

            TabBar(selection: $tab)

            TabView(selection: $tab) {
                EpisodeDetails(
                    model: model,
                    subject: subject,
                    onShowSources: { showsSourcePicker = true },
                )
                .tag(Tab.details)

                CommentsScreen(source: .episode(model.target.episode.id), title: "评论")
                    .id(model.target.episode.id)
                    .tag(Tab.comments)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(Color(.systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .fullScreenCover(isPresented: $showsFullscreen) {
            PlayerScreen(model: model)
        }
        .sheet(isPresented: $showsSourcePicker) {
            SourcePickerSheet(model: model)
                .presentationDetents([.medium, .large])
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
            showsFullscreen = true
        }
        .onAppear { UIDevice.current.beginGeneratingDeviceOrientationNotifications() }
        .task {
            let services = services
            model.start(core: services.core, settings: { services.settings })
        }
        .task { await subject.observe(subjectId: model.target.subject.id, core: services.core) }
        .onDisappear {
            // 全屏覆盖也会触发 onDisappear; 只有真正离开播放页时才结束播放
            if !showsFullscreen {
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
                model.stop()
            }
        }
    }
}

/// 「详情 / 评论」标签行: 选中项为强调色, 下方指示条随切换滑动.
private struct TabBar: View {
    @Binding var selection: EpisodePlayerPage.Tab
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 0) {
            ForEach(EpisodePlayerPage.Tab.allCases, id: \.self) { tab in
                let selected = tab == selection
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = tab }
                } label: {
                    Text(tab.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .overlay(alignment: .bottom) {
                            if selected {
                                Capsule()
                                    .fill(.tint)
                                    .frame(height: 3)
                                    .padding(.horizontal, 12)
                                    .matchedGeometryEffect(id: "indicator", in: indicator)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer()
        }
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

// MARK: - 内嵌视频

/// 页面顶部的 16:9 视频. 点按显示或隐藏控件.
///
/// 顶栏: 返回, 剧集标题, 跳过 OP/ED, 更多选项 (画质增强, 播放信息, 外部链接, 下载).
/// 底栏: 播放/暂停, 进度, 弹幕开关, 全屏. 控件隐藏时底部保留一条细进度线.
private struct InlinePlayer: View {
    let model: PlayerModel
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
            status
            if controlsVisible {
                controls.transition(.opacity)
            } else {
                progressLine.transition(.opacity)
            }
            if model.showsStats {
                PlayerStatsOverlay(model: model)
                    .scaleEffect(0.85, anchor: .topLeading)
                    .padding(.top, controlsVisible ? 48 : 8)
                    .padding(.leading, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
        .background(Color.black.ignoresSafeArea(edges: .top))
        .environment(\.colorScheme, .dark)
        .contentShape(.rect)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
            if controlsVisible { scheduleHide() }
        }
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
            HStack(spacing: 2) {
                iconButton("chevron.backward", label: "返回", action: onBack)
                Text(episodeTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    model.skipOpEd()
                    scheduleHide()
                } label: {
                    Label("\(model.manualSkipSeconds)", systemImage: "goforward")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .frame(height: 40)
                        .padding(.horizontal, 6)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(model.phase != .playing)
                .accessibilityLabel("快进 \(model.manualSkipSeconds) 秒")
                PlayerMoreMenu(model: model) {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .contentShape(.rect)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                iconButton(model.isPlaying ? "pause.fill" : "play.fill", label: model.isPlaying ? "暂停" : "播放") {
                    model.togglePlayback()
                    scheduleHide()
                }
                .disabled(model.phase != .playing)
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
                Text("\(TimeText.format(scrubbing ?? model.currentTime)) / \(TimeText.format(model.duration))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize()
                iconButton(
                    model.isDanmakuEnabled ? "text.bubble.fill" : "text.bubble",
                    label: model.isDanmakuEnabled ? "关闭弹幕" : "开启弹幕",
                ) {
                    model.isDanmakuEnabled.toggle()
                    scheduleHide()
                }
                iconButton("arrow.up.left.and.arrow.down.right", label: "全屏", action: onFullscreen)
            }
        }
        .foregroundStyle(.white)
        .tint(.white)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.55), location: 0),
                    .init(color: .clear, location: 0.3),
                    .init(color: .clear, location: 0.6),
                    .init(color: .black.opacity(0.65), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom,
            )
            .allowsHitTesting(false)
        }
    }

    private var episodeTitle: String {
        let episode = model.target.episode
        return episode.displayName.isEmpty ? "第 \(episode.sort) 话" : "\(episode.sort)  \(episode.displayName)"
    }

    private func iconButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 40, height: 40)
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

// MARK: - 详情

/// 「详情」页, 对应上游 `EpisodeDetails` 的窄屏布局.
private struct EpisodeDetails: View {
    let model: PlayerModel
    let subject: SubjectModel
    let onShowSources: () -> Void

    @Environment(AppServices.self) private var services

    private var episodes: [AniEpisode] { subject.detail?.episodes ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                    .padding(.bottom, 4)
                MediaSourceBanner(model: model, onTap: onShowSources)
                DanmakuBanner(model: model)
                EpisodeListSection(
                    model: model,
                    episodes: episodes,
                    canEditWatched: services.isLoggedIn,
                    onSetWatched: { episode, watched in
                        Task {
                            await subject.setWatched(
                                watched,
                                episode: episode,
                                subjectId: model.target.subject.id,
                                core: services.core,
                            )
                        }
                    },
                )
                .padding(.top, 4)
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
    }

    /// 番剧名 (点按进入条目详情) 与收藏按钮.
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            NavigationLink(value: SubjectRoute(subject.detail?.subject ?? model.target.subject)) {
                Text((subject.detail?.subject ?? model.target.subject).displayName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
            .buttonStyle(.plain)
            if services.isLoggedIn {
                FavoriteButton(subject: subject, subjectId: model.target.subject.id)
            }
        }
    }
}

/// 收藏按钮: 未收藏时为空心爱心, 已收藏时为实心并显示收藏类型; 点按选择收藏类型.
private struct FavoriteButton: View {
    let subject: SubjectModel
    let subjectId: Int32

    @Environment(AppServices.self) private var services

    var body: some View {
        let current = subject.detail?.collectionType ?? .notCollected
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
            if current != .notCollected {
                Divider()
                Button("取消收藏", systemImage: "heart.slash", role: .destructive) {
                    Task { await subject.setCollectionType(.notCollected, subjectId: subjectId, core: services.core) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: current == .notCollected ? "heart" : "heart.fill")
                if current != .notCollected {
                    Text(current.title).font(.subheadline.weight(.medium))
                }
            }
            .foregroundStyle(current == .notCollected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            .frame(minWidth: 40, minHeight: 40)
            .contentShape(.rect)
        }
        .disabled(subject.detail == nil)
        .accessibilityLabel(current == .notCollected ? "收藏" : "收藏状态: \(current.title)")
    }
}

/// 上游 `MediaSelectorSummaryBanner`: 查询中, 需要手动选择, 或已选的数据源与资源标题; 点按切换数据源.
private struct MediaSourceBanner: View {
    let model: PlayerModel
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.left.arrow.right")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("切换数据源")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        if let selected = model.selected {
            HStack(spacing: 12) {
                Image(systemName: "play.tv")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.sourceName(selected.mediaSourceId))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(selected.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else if model.phase == .fetching {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("正在查询数据源")
                    .font(.subheadline.weight(.semibold))
                if let progress = model.progress {
                    Text("\(progress.completed)/\(progress.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Label("请选择数据源", systemImage: "exclamationmark.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
        }
    }
}

/// 上游 `DanmakuMatchInfoSummaryBanner`: 弹幕加载状态与数量.
private struct DanmakuBanner: View {
    let model: PlayerModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "captions.bubble")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        if !model.isDanmakuEnabled { return "弹幕已关闭，可在播放器内开启" }
        if !model.danmaku.isEmpty { return "共计 \(model.danmaku.count) 条弹幕" }
        return model.phase == .playing ? "暂无弹幕" : "弹幕加载中"
    }
}

/// 上游窄屏 `EpisodeListSection`: 「剧集列表」标题, 右侧进入全部剧集; 下方横向滚动的剧集卡片.
private struct EpisodeListSection: View {
    let model: PlayerModel
    let episodes: [AniEpisode]
    let canEditWatched: Bool
    let onSetWatched: (AniEpisode, Bool) -> Void

    @State private var showsAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("剧集列表")
                    .font(.headline)
                Spacer()
                Button {
                    showsAll = true
                } label: {
                    HStack(spacing: 2) {
                        Text(episodes.isEmpty ? "全部" : "全 \(episodes.count) 话")
                        Image(systemName: "chevron.right")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(episodes.isEmpty)
                .accessibilityLabel("查看全部剧集")
            }

            if episodes.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 72)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 12) {
                            ForEach(episodes, id: \.id) { episode in
                                EpisodeCard(
                                    episode: episode,
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

/// 剧集卡片: 72pt 高, 16:9. 集号与集名在左下角; 正在播放时以强调色显示并带跳动的音波, 看过的集右上角显示「已看」.
private struct EpisodeCard: View {
    let episode: AniEpisode
    let isPlaying: Bool
    let animating: Bool
    let action: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                shape.fill(background)
                if episode.watched {
                    Text("已看")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.thinMaterial, in: .capsule)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if isPlaying {
                        Image(systemName: "waveform")
                            .font(.caption.weight(.semibold))
                            .symbolEffect(.variableColor.iterative, isActive: animating)
                    }
                    Text(episode.sort)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    Text(episode.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .foregroundStyle(isPlaying ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .frame(width: 128, height: 72)
            .opacity(episode.watched && !isPlaying ? 0.6 : 1)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isPlaying ? .isSelected : [])
    }

    private var background: Color {
        isPlaying ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground)
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
