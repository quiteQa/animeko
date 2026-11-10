import AniCore
import AVKit
import Combine
import SwiftUI

/// 全屏播放. 播放状态 (`PlayerModel`) 由播放页持有, 这里只是同一个 `AVPlayer` 的全屏视图:
/// 切换到竖屏回到播放页, 播放继续; 关闭则连同播放页一起关闭. iPhone 上全屏期间界面横屏.
struct PlayerScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    let model: PlayerModel
    /// 关闭播放页 (而不只是退出全屏).
    let onClosePage: () -> Void
    @State private var controlsVisible = true
    @State private var isLocked = false
    @State private var showsSourcePicker = false
    @State private var showsWatchTogether = false
    @State private var pictureInPicture: AVPictureInPictureController?
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var heldLandscape = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerSurface(
                player: model.player,
                enhancementMode: model.enhancementMode,
                fillsScreen: model.fillsScreen,
                onEnhancementUnavailable: enhancementUnavailable,
                onPictureInPictureReady: { pictureInPicture = $0 },
            )
            .ignoresSafeArea()

            DanmakuOverlay(
                danmaku: model.visibleDanmaku(settings: services.settings),
                isEnabled: model.isDanmakuEnabled,
                showsColor: services.settings?.danmakuShowColor ?? true,
                currentTime: { [model] in model.playbackTime() },
            )
            .ignoresSafeArea()

            PlayerStatusView(phase: model.phase, progress: model.progress, selected: model.selected) {
                showsSourcePicker = true
            }

            if model.showsStats {
                PlayerStatsOverlay(model: model)
                    .padding(.top, controlsVisible && !isLocked ? 96 : 16)
                    .padding(.leading, 72)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if controlsVisible {
                PlayerControls(
                    model: model,
                    canStartPictureInPicture: pictureInPicture != nil,
                    isLocked: $isLocked,
                    onClosePage: onClosePage,
                    onExitFullscreen: { dismiss() },
                    onShowSources: { showsSourcePicker = true },
                    onShowWatchTogether: { showsWatchTogether = true },
                    onPictureInPicture: { pictureInPicture?.startPictureInPicture() },
                    onInteraction: scheduleHideControls,
                )
                .environment(\.colorScheme, .dark)
                .transition(.opacity)
            }
        }
        .contentShape(.rect)
        .onTapGesture(count: 2) {
            guard !isLocked, model.phase == .playing else { return }
            model.togglePlayback()
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
            if controlsVisible { scheduleHideControls() }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showsSourcePicker) {
            SourcePickerSheet(model: model)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsWatchTogether) {
            WatchTogetherSheet()
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if let navigation = services.watchTogether.pendingNavigation {
                    // 先退出全屏, 再由根视图打开房主正在看的剧集
                    WatchTogetherNavigationBanner(navigation: navigation) {
                        dismiss()
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
            .padding(.top, controlsVisible ? 100 : 16)
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
                .padding(.trailing, 72)
                .padding(.bottom, controlsVisible ? 80 : 24)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.pendingSkip?.name)
        .task { scheduleHideControls() }
        .onAppear { OrientationLock.enterLandscape() }
        .onDisappear { OrientationLock.restorePortrait() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            // 横持过手机之后再竖过来, 即退出全屏回到播放页; 锁定时不响应
            guard !isLocked else { return }
            switch UIDevice.current.orientation {
            case .landscapeLeft, .landscapeRight: heldLandscape = true
            case .portrait where heldLandscape: dismiss()
            default: break
            }
        }
    }

    private func enhancementUnavailable() {
        guard model.enhancementMode != .off else { return }
        model.enhancementMode = .off
        model.toastMessage = "当前视频无法使用画质增强"
    }

    private func scheduleHideControls() {
        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, model.isPlaying || isLocked else { return }
            withAnimation(.easeInOut(duration: 0.3)) { controlsVisible = false }
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
