import Combine
import SwiftUI

@main
struct PlayerInteractionHost: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { WindowGroup { InteractionHarness() } }
}

/// 使用生产视口、方向策略和手势层, 不依赖账户、网络资源或解码器.
private struct InteractionHarness: View {
    @State private var presentation = PlayerPresentationState()
    @StateObject private var controls = PlayerSystemControls()
    @State private var paused = false
    @State private var showsSources = false
    @State private var progress = 0.25
    @State private var showsEpisodes = false
    @State private var episode = 1
    @State private var lastIndicator = "none"

    var body: some View {
        PlayerViewport(isFullscreen: presentation.isFullscreen) {
            VStack(spacing: 20) {
                Color.black.aspectRatio(16 / 9, contentMode: .fit)
                    .accessibilityLabel("内嵌视频").accessibilityIdentifier("inline-video")
                Text("详情").accessibilityIdentifier("details")
                Button("全屏", action: enter).accessibilityIdentifier("enter-fullscreen")
                playbackButton
                Button("切换源") { showsSources.toggle() }.accessibilityIdentifier("sources")
                if showsSources { Text("资源列表").accessibilityIdentifier("source-list") }
                Spacer()
            }
        } fullscreen: {
            PlayerCinemaLayout(showsPanel: showsEpisodes) { _, _ in
                ZStack {
                    Color.black
                    PlayerGestureSurface(controls: controls, isEnabled: !presentation.isLocked && !showsEpisodes,
                                         topInset: 80, bottomInset: 80, onTap: {}, onInteraction: {})
                    VStack {
                        HStack {
                            Button("竖屏", action: exit).accessibilityIdentifier("exit-fullscreen")
                            Spacer()
                            Button("选集") { showsEpisodes.toggle() }.accessibilityIdentifier("episodes")
                            Button(presentation.isLocked ? "解锁" : "锁定") { presentation.isLocked.toggle() }
                                .accessibilityIdentifier("lock")
                        }
                        Spacer()
                        Text(indicatorText).accessibilityIdentifier("indicator")
                        Text("第 \(episode) 话").accessibilityIdentifier("current-episode")
                        Slider(value: $progress).accessibilityIdentifier("progress")
                        playbackButton
                    }
                    .padding(24)
                    PlayerAdjustmentHUD(controls: controls, usesSidePlacement: true)
                }
                .foregroundStyle(.white)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("fullscreen")
            } panel: {
                VStack {
                    Button("关闭选集") { showsEpisodes = false }.accessibilityIdentifier("dismiss-episodes")
                    Button("第 2 话") {
                        episode = 2
                        showsEpisodes = false
                    }
                    .accessibilityIdentifier("episode-2")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(.white)
            }
        }
        .background { PlayerSystemVolumeBridge(controls: controls).frame(width: 1, height: 1) }
        .onAppear { UIDevice.current.beginGeneratingDeviceOrientationNotifications() }
        .onDisappear { controls.restoreBrightness(); UIDevice.current.endGeneratingDeviceOrientationNotifications() }
        .onReceive(controls.$indicator) { value in
            if let value { lastIndicator = value.target == .brightness ? "brightness" : "volume" }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            let previous = presentation.isFullscreen
            let orientation = UIDevice.current.orientation
            presentation.deviceRotated(to: orientation == .portrait ? .portrait : orientation.isLandscape ? .landscape : .unknown,
                                       canAutoEnter: true)
            if previous != presentation.isFullscreen {
                if presentation.isFullscreen { OrientationLock.enterLandscape() }
                else { OrientationLock.restorePortrait() }
            }
        }
    }

    private var indicatorText: String {
        lastIndicator
    }
    private var playbackButton: some View {
        Button(paused ? "播放" : "暂停") { paused.toggle() }.accessibilityIdentifier("playback")
    }
    private func enter() { presentation.enterFullscreen(); OrientationLock.enterLandscape() }
    private func exit() { presentation.exitFullscreen(); OrientationLock.restorePortrait() }
}
