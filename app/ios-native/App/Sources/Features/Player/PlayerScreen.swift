import AniCore
import SwiftUI

/// 全屏播放. 播放状态 (`PlayerModel`)、锁定与界面方向由播放页持有; 两种布局共用播放内核.
/// 切换到竖屏回到播放页继续播放, 关闭则连同播放页一起关闭.
struct PlayerScreen: View {
    @Environment(AppServices.self) private var services
    let model: PlayerModel
    let systemControls: PlayerSystemControls
    @Binding var isLocked: Bool
    /// 是否持有画面.
    var ownsVideo = true
    /// 退出全屏, 回到竖屏播放页.
    let onExitFullscreen: () -> Void
    /// 关闭播放页 (而不只是退出全屏).
    let onClosePage: () -> Void
    @State private var controlsVisible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsEpisodes = false
    @State private var isSeeking = false
    @State private var showsSourcePicker = false
    @State private var showsWatchTogether = false
    @State private var hideControlsTask: Task<Void, Never>?

    var body: some View {
        PlayerCinemaLayout(showsPanel: showsEpisodes) { isCompact, fitsPane in
            playbackPane(isCompact: isCompact, fitsPane: fitsPane)
        } panel: {
            CinemaEpisodePanel(model: model, onClose: { setEpisodesVisible(false) }) { episode in
                setEpisodesVisible(false)
                if episode.id != model.target.episode.id { model.play(episode: episode) }
            }
        }
        .sheet(isPresented: $showsSourcePicker) {
            SourcePickerSheet(model: model)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsWatchTogether) {
            WatchTogetherSheet()
        }
        .task { scheduleHideControls() }
        .onDisappear { hideControlsTask?.cancel() }
        .onChange(of: model.menuCloseCount) { scheduleHideControls() }
        .onChange(of: model.isPlaying) { _, playing in
            if playing { scheduleHideControls() }
        }
        .onChange(of: showsSourcePicker) { _, visible in
            if !visible { scheduleHideControls() }
        }
        .onChange(of: showsWatchTogether) { _, visible in
            if !visible { scheduleHideControls() }
        }
    }

    private func playbackPane(isCompact: Bool, fitsPane: Bool) -> some View {
        ZStack {
            PlayerSurface(player: model.player, isActive: ownsVideo, fitsContainer: fitsPane)
                .ignoresSafeArea(edges: showsEpisodes ? [] : .all)
                .allowsHitTesting(false)

            DanmakuOverlay(
                danmaku: model.visibleDanmaku(settings: services.settings),
                renderKey: model.danmakuRenderKey(settings: services.settings),
                isPlaybackAdvancing: model.isPlaying && ownsVideo,
                isEnabled: model.isDanmakuEnabled,
                showsColor: services.settings?.danmakuShowColor ?? true,
                currentTime: { [model] in model.playbackTime() },
            )
            .ignoresSafeArea(edges: showsEpisodes ? [] : .all)
            .allowsHitTesting(false)

            PlayerGestureSurface(
                controls: systemControls, isEnabled: !isLocked && ownsVideo && !showsEpisodes,
                topInset: controlsVisible ? 58 : 16, bottomInset: controlsVisible ? 106 : 16,
                onTap: {
                    if showsEpisodes { setEpisodesVisible(false); return }
                    withAnimation(controlAnimation) { controlsVisible.toggle() }
                    if controlsVisible { scheduleHideControls() }
                },
                onDoubleTap: {
                    guard !isLocked, !showsEpisodes, model.phase == .playing else { return }
                    model.togglePlayback()
                    scheduleHideControls()
                },
                onInteraction: scheduleHideControls
            )

            PlayerStatusView(phase: model.phase, progress: model.progress, selected: model.selected) {
                showsSourcePicker = true
            }

            if model.showsStats {
                PlayerStatsOverlay(model: model)
                    .padding(.top, controlsVisible && !isLocked ? 64 : 16)
                    .padding(.leading, 56)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }

            if controlsVisible {
                PlayerControls(
                    model: model, isLocked: $isLocked, isCompact: isCompact,
                    onClosePage: onClosePage, onExitFullscreen: onExitFullscreen,
                    onShowEpisodes: { setEpisodesVisible(!showsEpisodes) },
                    onShowSources: { showsSourcePicker = true },
                    onShowWatchTogether: { showsWatchTogether = true },
                    onInteraction: scheduleHideControls,
                    onSeekingChanged: { editing in
                        isSeeking = editing
                        scheduleHideControls()
                    }
                )
                .transition(.opacity)
            }
            if !isLocked && !showsEpisodes {
                PlayerAdjustmentHUD(controls: systemControls, usesSidePlacement: true)
            }
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .tint(cinemaAccent)
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if let navigation = services.watchTogether.pendingNavigation {
                    // 先退出全屏, 再由根视图打开房主正在看的剧集
                    WatchTogetherNavigationBanner(navigation: navigation) {
                        onExitFullscreen()
                        try? await Task.sleep(for: .milliseconds(450))
                    }
                }
                if let message = model.toastMessage ?? services.watchTogether.message {
                    Text(message)
                        .font(.subheadline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task(id: message) {
                            try? await Task.sleep(for: .seconds(2))
                            withAnimation {
                                if model.toastMessage == message { model.toastMessage = nil }
                                if services.watchTogether.message == message { services.watchTogether.message = nil }
                            }
                        }
                }
            }
            .padding(.top, controlsVisible ? 62 : 16)
        }
        .overlay(alignment: .bottomTrailing) {
            // 自动跳过提示与控件层是否显示无关, 始终可以取消
            if let segment = model.pendingSkip {
                HStack(spacing: 12) {
                    Text("即将跳过 \(segment.name)")
                        .font(.subheadline)
                    Button("取消") { model.cancelAutoSkip() }
                        .buttonStyle(.glass)
                }
                .padding(.leading, 16)
                .padding(4)
                .glassEffect(.regular, in: .capsule)
                .padding(.trailing, 16)
                .padding(.bottom, controlsVisible ? 106 : 24)
                .transition(.opacity)
            }
        }
        .animation(controlAnimation, value: model.pendingSkip?.name)
    }

    private var controlAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.22)
    }

    private func setEpisodesVisible(_ visible: Bool) {
        if visible { systemControls.dismissIndicator() }
        withAnimation(controlAnimation) { showsEpisodes = visible }
        scheduleHideControls()
    }

    private func scheduleHideControls() {
        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(for: .seconds(4))
            // 菜单展开时保持显示; 菜单关闭后重新计时
            guard !Task.isCancelled, !model.isMenuOpen, !showsEpisodes, !isSeeking,
                  !showsSourcePicker, !showsWatchTogether, model.isPlaying || isLocked else { return }
            withAnimation(controlAnimation) { controlsVisible = false }
        }
    }
}

/// 播放前的查询 / 解析状态与失败提示.
private struct PlayerStatusView: View {
    let phase: PlayerModel.Phase
    let progress: AniFetchProgress?
    let selected: AniMediaCandidate?
    let onShowSources: () -> Void

    var body: some View {
        switch phase {
        case .playing:
            EmptyView()
        case .fetching:
            status(title: "正在查找资源", detail: progress.map { "已查询 \($0.completed)/\($0.total) 个数据源 · 找到 \($0.candidateCount) 个资源" })
        case .resolving:
            status(title: "正在解析视频", detail: selected.map { $0.title })
        case .noSource:
            message(title: "没有找到可播放的资源", systemImage: "rectangle.slash")
        case .failed(let reason):
            message(title: reason, systemImage: "exclamationmark.triangle")
        }
    }

    private func status(title: String, detail: String?) -> some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text(title).font(.headline)
            if let detail {
                Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding()
    }

    private func message(title: String, systemImage: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.largeTitle)
            Text(title).font(.headline).multilineTextAlignment(.center)
            Button("选择其他资源", action: onShowSources)
                .buttonStyle(.glass)
        }
        .padding(24)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding()
    }
}
