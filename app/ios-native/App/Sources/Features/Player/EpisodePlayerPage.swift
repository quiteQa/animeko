import AniCore
import AVKit
import Combine
import SwiftUI

/// 播放页: 顶部是内嵌的 16:9 视频, 下方切换「选集」与「评论」.
///
/// 页面持有 `PlayerModel` 与播放会话; 全屏只是同一个 `AVPlayer` 的另一个视图, 退出全屏后回到这里继续播放.
/// 离开页面 (返回) 时才结束播放. iPhone 横过来时自动进入全屏.
struct EpisodePlayerPage: View {
    fileprivate enum Tab: Hashable, CaseIterable {
        case episodes, comments

        var title: String {
            switch self {
            case .episodes: "选集"
            case .comments: "评论"
            }
        }
    }

    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var model: PlayerModel
    @State private var subject = SubjectModel()
    @State private var tab: Tab = .episodes
    @State private var showsFullscreen = false
    @State private var showsSourcePicker = false

    init(target: PlaybackTarget) {
        _model = State(initialValue: PlayerModel(target: target))
    }

    var body: some View {
        VStack(spacing: 0) {
            InlinePlayer(
                model: model,
                onBack: { dismiss() },
                onFullscreen: { showsFullscreen = true },
                onShowSources: { showsSourcePicker = true },
            )

            TabBar(selection: $tab)

            switch tab {
            case .episodes:
                EpisodesPanel(
                    model: model,
                    episodes: subject.detail?.episodes ?? [],
                    onShowSources: { showsSourcePicker = true },
                )
            case .comments:
                CommentsScreen(source: .episode(model.target.episode.id), title: "评论")
                    .scrollContentBackground(.hidden)
                    .id(model.target.episode.id)
            }
        }
        .background { AmbientBackground(imageUrl: model.target.subject.imageUrl) }
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

/// 以封面的模糊色调作为页面底色, 让播放页与番剧本身的配色呼应.
private struct AmbientBackground: View {
    let imageUrl: String

    var body: some View {
        ZStack {
            Color(.systemBackground)
            Color.clear
                .overlay {
                    AsyncImage(url: URL(string: imageUrl)) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                }
                .blur(radius: 70)
                .opacity(0.45)
                .clipped()
            LinearGradient(
                colors: [Color(.systemBackground).opacity(0.2), Color(.systemBackground).opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom,
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// 「选集 / 评论」标签: 选中项加粗, 下方指示条随切换滑动.
private struct TabBar: View {
    @Binding var selection: EpisodePlayerPage.Tab
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 28) {
            ForEach(EpisodePlayerPage.Tab.allCases, id: \.self) { tab in
                let selected = tab == selection
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = tab }
                } label: {
                    VStack(spacing: 6) {
                        Text(tab.title)
                            .font(.body.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? .primary : .secondary)
                        ZStack {
                            Capsule().fill(.clear).frame(height: 3)
                            if selected {
                                Capsule()
                                    .fill(.tint)
                                    .frame(width: 20, height: 3)
                                    .matchedGeometryEffect(id: "indicator", in: indicator)
                            }
                        }
                    }
                    .fixedSize()
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator.opacity(0.5)).frame(height: 0.5)
        }
    }
}

// MARK: - 内嵌视频

/// 页面顶部的 16:9 视频. 点按显示或隐藏控件; 控件隐藏时底部保留一条细进度线.
private struct InlinePlayer: View {
    let model: PlayerModel
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
            PlayerSurface(player: model.player)
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
            HStack(spacing: 4) {
                iconButton("chevron.backward", label: "返回", action: onBack)
                Text(episodeTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
            }

            Spacer()

            if model.phase == .playing {
                Button {
                    model.togglePlayback()
                    scheduleHide()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 60, height: 60)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(model.isPlaying ? "暂停" : "播放")
            }

            Spacer()

            HStack(spacing: 10) {
                Text("\(TimeText.format(scrubbing ?? model.currentTime)) / \(TimeText.format(model.duration))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize()
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
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
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
        return episode.displayName.isEmpty ? "第 \(episode.sort) 话" : "\(episode.sort) · \(episode.displayName)"
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

// MARK: - 选集

/// 「选集」: 番名与当前集, 一排快捷操作 (线路, 弹幕, 缓存, 下一集), 以及剧集网格.
private struct EpisodesPanel: View {
    let model: PlayerModel
    let episodes: [AniEpisode]
    let onShowSources: () -> Void

    @ScaledMetric(relativeTo: .title3) private var tileMinWidth: CGFloat = 68

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    actions
                    episodeSection(proxy: proxy)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .task(id: episodes.count) {
                // 剧集加载完成后定位到正在播放的一集
                guard !episodes.isEmpty else { return }
                proxy.scrollTo(model.target.episode.id, anchor: .center)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.target.subject.displayName)
                .font(.title2.weight(.bold))
                .lineLimit(2)
            HStack(spacing: 6) {
                Text("第 \(model.target.episode.sort) 话")
                    .foregroundStyle(.tint)
                    .fontWeight(.semibold)
                if !model.target.episode.displayName.isEmpty {
                    Text(model.target.episode.displayName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .font(.subheadline)
        }
    }

    private var actions: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    SourceMenu(model: model, onShowSources: onShowSources)

                    Button {
                        model.isDanmakuEnabled.toggle()
                    } label: {
                        Pill(
                            title: "弹幕",
                            systemImage: model.isDanmakuEnabled ? "text.bubble.fill" : "text.bubble",
                            isOn: model.isDanmakuEnabled,
                        )
                    }
                    .accessibilityValue(model.isDanmakuEnabled ? "开" : "关")

                    Button {
                        model.downloadSelected()
                    } label: {
                        Pill(title: "缓存", systemImage: "arrow.down.circle")
                    }
                    .disabled(model.selected == nil)

                    Button {
                        model.playNextEpisode()
                    } label: {
                        Pill(title: "下一集", systemImage: "forward.end")
                    }
                    .disabled(model.nextEpisode == nil)
                }
                .buttonStyle(.plain)
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private func episodeSection(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("选集")
                    .font(.headline)
                if !episodes.isEmpty {
                    Text("共 \(episodes.count) 话")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    withAnimation { proxy.scrollTo(model.target.episode.id, anchor: .center) }
                } label: {
                    Label("定位", systemImage: "scope")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
                .disabled(episodes.isEmpty)
                .accessibilityLabel("定位到正在播放")
            }

            if episodes.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: tileMinWidth), spacing: 10)], spacing: 10) {
                    ForEach(episodes, id: \.id) { episode in
                        EpisodeTile(
                            episode: episode,
                            isCurrent: episode.id == model.target.episode.id,
                            isPlaying: model.isPlaying,
                        ) {
                            model.play(episode: episode)
                        }
                        .id(episode.id)
                    }
                }
            }
        }
    }
}

/// 胶囊形快捷操作; [isOn] 时以强调色填充.
private struct Pill: View {
    let title: String
    let systemImage: String
    var isOn = false
    var trailingSystemImage: String?

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title).lineLimit(1)
            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(isOn ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .capsule)
        .opacity(isEnabled ? 1 : 0.4)
        .contentShape(.capsule)
    }
}

/// 「线路」: 列出符合偏好的资源, 选中即切换; 更多选项进入完整的选源面板.
private struct SourceMenu: View {
    let model: PlayerModel
    let onShowSources: () -> Void

    var body: some View {
        Menu {
            Section("播放线路") {
                ForEach(model.preferredCandidates, id: \.mediaId) { candidate in
                    Button {
                        model.select(candidate)
                    } label: {
                        if candidate.mediaId == model.selected?.mediaId {
                            Label(label(for: candidate), systemImage: "checkmark")
                        } else {
                            Text(label(for: candidate))
                        }
                    }
                    .disabled(!candidate.playable)
                }
            }
            Button("更多资源与手动查找…", systemImage: "square.stack", action: onShowSources)
        } label: {
            Pill(
                title: model.selected.map(label(for:)) ?? placeholder,
                systemImage: "antenna.radiowaves.left.and.right",
                trailingSystemImage: "chevron.down",
            )
            .frame(maxWidth: 220)
        }
        .accessibilityLabel("播放线路")
    }

    private var placeholder: String {
        model.phase == .fetching ? "正在查找…" : "选择线路"
    }

    private func label(for candidate: AniMediaCandidate) -> String {
        [model.sourceName(candidate.mediaSourceId), candidate.alliance]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// 剧集网格中的一格: 集数为主; 正在播放的一集以强调色填充并显示跳动的音波, 看过的集显示对勾.
private struct EpisodeTile: View {
    let episode: AniEpisode
    let isCurrent: Bool
    let isPlaying: Bool
    let action: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(episode.sort)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                indicator
                    .font(.caption2.weight(.semibold))
                    .frame(height: 12)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .foregroundStyle(isCurrent ? AnyShapeStyle(.white) : episode.watched ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .background {
                if isCurrent {
                    shape.fill(.tint)
                } else {
                    shape.fill(.background.opacity(0.6))
                    shape.strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !episode.displayName.isEmpty {
                Text(episode.displayName)
            }
            if !episode.airDate.isEmpty {
                Text(episode.airDate)
            }
        }
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    @ViewBuilder
    private var indicator: some View {
        if isCurrent {
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, isActive: isPlaying)
        } else if episode.watched {
            Image(systemName: "checkmark")
        } else {
            Color.clear
        }
    }

    private var accessibilityText: String {
        var parts = ["第 \(episode.sort) 话"]
        if !episode.displayName.isEmpty { parts.append(episode.displayName) }
        if isCurrent { parts.append("正在播放") } else if episode.watched { parts.append("已看过") }
        return parts.joined(separator: ", ")
    }
}
