import AniCore
import AVKit
import Combine
import SwiftUI

/// 全屏播放. 播放状态 (`PlayerModel`) 由播放页持有, 这里只是同一个 `AVPlayer` 的全屏视图:
/// 关闭全屏回到播放页, 播放继续. iPhone 上全屏期间界面横屏.
struct PlayerScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    let model: PlayerModel
    @State private var controlsVisible = true
    @State private var showsSourcePicker = false
    @State private var showsComments = false
    @State private var pictureInPicture: AVPictureInPictureController?
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var heldLandscape = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerSurface(
                player: model.player,
                enhancementMode: model.enhancementMode,
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
                    .padding(.top, controlsVisible ? 76 : 16)
                    .padding(.leading, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if controlsVisible {
                PlayerControls(
                    model: model,
                    canStartPictureInPicture: pictureInPicture != nil,
                    onClose: close,
                    onShowSources: { showsSourcePicker = true },
                    onShowComments: { showsComments = true },
                    onPictureInPicture: { pictureInPicture?.startPictureInPicture() },
                    onInteraction: scheduleHideControls,
                )
                .transition(.opacity)
            }
        }
        .contentShape(.rect)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
            if controlsVisible { scheduleHideControls() }
        }
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(controlsVisible ? .automatic : .hidden)
        .sheet(isPresented: $showsSourcePicker) {
            SourcePickerSheet(model: model)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsComments) {
            NavigationStack {
                CommentsScreen(source: .episode(model.target.episode.id), title: "评论")
            }
            .presentationDetents([.medium, .large])
        }
        .overlay(alignment: .top) {
            if let message = model.toastMessage {
                Text(message)
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation { model.toastMessage = nil }
                    }
            }
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
                .padding(.trailing, 24)
                .padding(.bottom, controlsVisible ? 150 : 40)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.pendingSkip?.name)
        .task { scheduleHideControls() }
        .onAppear { OrientationLock.enterLandscape() }
        .onDisappear { OrientationLock.restorePortrait() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            // 横持过手机之后再竖过来, 即退出全屏回到播放页
            switch UIDevice.current.orientation {
            case .landscapeLeft, .landscapeRight: heldLandscape = true
            case .portrait where heldLandscape: close()
            default: break
            }
        }
    }

    private func enhancementUnavailable() {
        guard model.enhancementMode != .off else { return }
        model.enhancementMode = .off
        model.toastMessage = "当前视频无法使用画质增强"
    }

    private func close() {
        dismiss()
    }

    private func scheduleHideControls() {
        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, model.isPlaying else { return }
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
