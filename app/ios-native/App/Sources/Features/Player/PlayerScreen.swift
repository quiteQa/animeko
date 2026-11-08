import AniCore
import AVKit
import SwiftUI

struct PlayerScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var model: PlayerModel
    @State private var controlsVisible = true
    @State private var showsSourcePicker = false
    @State private var pictureInPicture: AVPictureInPictureController?
    @State private var hideControlsTask: Task<Void, Never>?

    init(target: PlaybackTarget) {
        _model = State(initialValue: PlayerModel(target: target))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerSurface(player: model.player) { pictureInPicture = $0 }
                .ignoresSafeArea()

            DanmakuOverlay(
                danmaku: model.danmaku,
                isEnabled: model.isDanmakuEnabled,
                currentTime: { [model] in model.playbackTime() },
            )
            .ignoresSafeArea()

            PlayerStatusView(phase: model.phase, progress: model.progress, selected: model.selected) {
                showsSourcePicker = true
            }

            if controlsVisible {
                PlayerControls(
                    model: model,
                    canStartPictureInPicture: pictureInPicture != nil,
                    onClose: close,
                    onShowSources: { showsSourcePicker = true },
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
        .task {
            model.start(core: services.core)
            scheduleHideControls()
        }
    }

    private func close() {
        model.stop()
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
            status(title: "正在解析视频", detail: selected.map { "\($0.mediaSourceId) · \($0.title)" })
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
