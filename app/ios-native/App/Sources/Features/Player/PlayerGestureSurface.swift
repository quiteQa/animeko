import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

/// 亮度作用于当前窗口的屏幕, 离开播放页后恢复; 音量通过系统 MPVolumeView 的公开滑块调节.
@MainActor
final class PlayerSystemControls: ObservableObject {
    struct Indicator {
        let target: PlayerVerticalAdjustment.Target
        let value: Double
        let unavailable: Bool
    }
    @Published private(set) var indicator: Indicator?
    weak var volumeSlider: UISlider?
    weak var screen: UIScreen?
    private var originalBrightness: CGFloat?
    private var hideTask: Task<Void, Never>?

    var brightness: Double { Double(screen?.brightness ?? 0.5) }
    var volume: Double { Double(AVAudioSession.sharedInstance().outputVolume) }

    func adjust(_ target: PlayerVerticalAdjustment.Target, to value: Double) {
        hideTask?.cancel()
        let available: Bool
        switch target {
        case .brightness:
            available = screen != nil
            if let screen {
                if originalBrightness == nil { originalBrightness = screen.brightness }
                screen.brightness = CGFloat(value)
            }
        case .volume:
            available = volumeSlider?.isEnabled == true
            if available, let volumeSlider {
                volumeSlider.setValue(Float(value), animated: false)
                volumeSlider.sendActions(for: .valueChanged)
            }
        }
        indicator = Indicator(target: target, value: value, unavailable: !available)
    }

    func finishAdjustment() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.indicator = nil
        }
    }

    func restoreBrightness() {
        if let originalBrightness { screen?.brightness = originalBrightness }
        originalBrightness = nil
        hideTask?.cancel()
        indicator = nil
    }
}

struct PlayerSystemVolumeBridge: UIViewRepresentable {
    let controls: PlayerSystemControls

    func makeUIView(context: Context) -> VolumeHost {
        let view = VolumeHost()
        view.controls = controls
        return view
    }
    func updateUIView(_ view: VolumeHost, context: Context) { view.bindControls() }

    final class VolumeHost: UIView {
        weak var controls: PlayerSystemControls?
        private let volumeView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 120, height: 32))
        override init(frame: CGRect) {
            super.init(frame: frame)
            volumeView.showsRouteButton = false
            volumeView.alpha = 0.01
            addSubview(volumeView)
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func didMoveToWindow() { super.didMoveToWindow(); bindControls() }
        override func layoutSubviews() { super.layoutSubviews(); bindControls() }
        func bindControls() {
            controls?.screen = window?.windowScene?.screen
            controls?.volumeSlider = volumeView.subviews.compactMap { $0 as? UISlider }.first
        }
    }
}

/// 手势层位于按钮之下, 只识别视频空白区域的纵向拖动.
struct PlayerGestureSurface: View {
    @ObservedObject var controls: PlayerSystemControls
    var isEnabled = true
    var topInset: Double = 48
    var bottomInset: Double = 48
    var onTap: () -> Void
    var onDoubleTap: (() -> Void)?
    var onInteraction: () -> Void
    @State private var adjustment = PlayerVerticalAdjustment()

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(.rect)
                .onTapGesture(count: 2) { onDoubleTap?() }
                .onTapGesture(perform: onTap)
                .gesture(DragGesture(minimumDistance: 12)
                    .onChanged { drag in
                        guard isEnabled else { return }
                        if let value = adjustment.update(
                            startX: drag.startLocation.x, startY: drag.startLocation.y,
                            translationX: drag.translation.width, translationY: drag.translation.height,
                            width: geometry.size.width, height: geometry.size.height,
                            topInset: topInset, bottomInset: bottomInset,
                            brightness: controls.brightness, volume: controls.volume
                        ), let target = adjustment.target {
                            controls.adjust(target, to: value)
                            onInteraction()
                        }
                    }
                    .onEnded { _ in reset() }
                )
        }
        .accessibilityHidden(true)
        .onChange(of: isEnabled) { if !isEnabled { reset() } }
        .onDisappear { reset() }
    }

    private func reset() {
        adjustment = PlayerVerticalAdjustment()
        controls.finishAdjustment()
    }
}

struct PlayerAdjustmentHUD: View {
    @ObservedObject var controls: PlayerSystemControls
    var body: some View {
        if let indicator = controls.indicator {
            HStack(spacing: 10) {
                Image(systemName: indicator.target == .brightness ? "sun.max.fill" : "speaker.wave.2.fill")
                if indicator.unavailable {
                    Text("当前输出不支持调节").font(.footnote)
                } else {
                    Text(indicator.target == .brightness ? "亮度" : "音量")
                    ProgressView(value: indicator.value).frame(width: 72).tint(.white)
                    Text("\(Int((indicator.value * 100).rounded()))%")
                        .monospacedDigit().frame(minWidth: 36, alignment: .trailing)
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.black.opacity(0.75), in: .capsule)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
