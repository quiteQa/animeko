import AniCore
import AVKit
import SwiftUI

/// 播放页: 顶部是内嵌的 16:9 视频, 下方切换「选集」与「评论」.
///
/// 页面持有 `PlayerModel` 与播放会话; 全屏只是同一个 `AVPlayer` 的另一个视图, 退出全屏后回到这里继续播放.
/// 离开页面 (返回) 时才结束播放.
struct EpisodePlayerPage: View {
    private enum Tab: Hashable { case episodes, comments }

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

            Picker("内容", selection: $tab) {
                Text("选集").tag(Tab.episodes)
                Text("评论").tag(Tab.comments)
            }
            .pickerStyle(.segmented)
            .controlSize(.large)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            switch tab {
            case .episodes:
                EpisodesPanel(
                    model: model,
                    episodes: subject.detail?.episodes ?? [],
                    onShowSources: { showsSourcePicker = true },
                )
            case .comments:
                CommentsScreen(source: .episode(model.target.episode.id), title: "评论")
                    .id(model.target.episode.id)
            }
        }
        .background(Color(.systemGroupedBackground))
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
        .task {
            let services = services
            model.start(core: services.core, settings: { services.settings })
        }
        .task { await subject.observe(subjectId: model.target.subject.id, core: services.core) }
        .onDisappear {
            // 全屏覆盖也会触发 onDisappear; 只有真正离开播放页时才结束播放
            if !showsFullscreen { model.stop() }
        }
    }
}

// MARK: - 内嵌视频

/// 页面顶部的 16:9 视频. 点按显示或隐藏控件; 控件包括返回, 播放/暂停, 进度, 弹幕开关与全屏.
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
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.black.ignoresSafeArea(edges: .top))
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
            VStack(spacing: 8) {
                ProgressView().tint(.white)
                Text(model.phase == .fetching ? "正在查找资源" : "正在解析视频")
                    .font(.footnote)
                    .foregroundStyle(.white)
            }
        case .noSource, .failed:
            VStack(spacing: 8) {
                Text(model.phase == .noSource ? "没有找到可播放的资源" : failureMessage)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Button("选择其他资源", action: onShowSources)
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            .padding()
        }
    }

    private var failureMessage: String {
        if case .failed(let message) = model.phase { return message }
        return ""
    }

    private var controls: some View {
        VStack {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").frame(width: 32, height: 32)
                }
                .accessibilityLabel("返回")
                Spacer()
            }
            Spacer()
            if model.phase == .playing {
                Button {
                    model.togglePlayback()
                    scheduleHide()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 48, height: 48)
                }
                .accessibilityLabel(model.isPlaying ? "暂停" : "播放")
            }
            Spacer()
            HStack(spacing: 8) {
                Text(TimeText.format(scrubbing ?? model.currentTime))
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
                .disabled(model.duration <= 0)
                .accessibilityLabel("播放进度")
                Text(TimeText.format(model.duration))
                Button {
                    model.isDanmakuEnabled.toggle()
                } label: {
                    Image(systemName: model.isDanmakuEnabled ? "text.bubble.fill" : "text.bubble")
                }
                .accessibilityLabel("弹幕")
                .accessibilityValue(model.isDanmakuEnabled ? "开" : "关")
                Button(action: onFullscreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityLabel("全屏")
            }
            .font(.caption.monospacedDigit())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .foregroundStyle(.white)
        .tint(.white)
        .padding(10)
        .background {
            LinearGradient(
                colors: [.black.opacity(0.45), .clear, .clear, .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom,
            )
            .allowsHitTesting(false)
        }
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

/// 「选集」: 番名, 播放线路, 剧集列表 (当前集高亮为「正在播放」).
private struct EpisodesPanel: View {
    let model: PlayerModel
    let episodes: [AniEpisode]
    let onShowSources: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(model.target.subject.displayName)
                        .font(.title2.bold())
                        .lineLimit(2)

                    SourceMenu(model: model, onShowSources: onShowSources)

                    HStack {
                        Text(episodes.isEmpty ? "全部剧集" : "全部剧集 · \(episodes.count) 集")
                            .font(.subheadline)
                        Spacer()
                        Button {
                            withAnimation { proxy.scrollTo(model.target.episode.id, anchor: .center) }
                        } label: {
                            Image(systemName: "scope").frame(width: 28, height: 28)
                        }
                        .accessibilityLabel("定位到正在播放")
                        Button {
                            model.downloadSelected()
                        } label: {
                            Image(systemName: "arrow.down.to.line").frame(width: 28, height: 28)
                        }
                        .disabled(model.selected == nil)
                        .accessibilityLabel("缓存本集")
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)

                    LazyVStack(spacing: 10) {
                        ForEach(episodes, id: \.id) { episode in
                            EpisodeCell(
                                episode: episode,
                                isCurrent: episode.id == model.target.episode.id,
                            ) {
                                model.play(episode: episode)
                            }
                            .id(episode.id)
                        }
                    }
                    if episodes.isEmpty {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .task(id: episodes.count) {
                // 剧集加载完成后定位到正在播放的一集
                guard !episodes.isEmpty else { return }
                proxy.scrollTo(model.target.episode.id, anchor: .center)
            }
        }
    }
}

/// 「播放线路」: 列出符合偏好的资源, 选中即切换; 更多选项进入完整的选源面板.
private struct SourceMenu: View {
    let model: PlayerModel
    let onShowSources: () -> Void

    var body: some View {
        Menu {
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
            Divider()
            Button("更多资源与手动查找…", systemImage: "square.stack", action: onShowSources)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("播放线路")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.selected.map(label(for:)) ?? placeholder)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
        }
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

private struct EpisodeCell: View {
    let episode: AniEpisode
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.sort)
                    .font(.title3.monospacedDigit().weight(isCurrent ? .semibold : .regular))
                Text(isCurrent ? "正在播放" : episode.displayName)
                    .font(.footnote)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .opacity(isCurrent || !episode.displayName.isEmpty ? 1 : 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .foregroundStyle(isCurrent ? .white : .primary)
            .background {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.tint)
                }
            }
            .glassEffect(isCurrent ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                         in: .rect(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
