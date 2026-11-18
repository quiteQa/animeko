import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

@MainActor
protocol PlayerBrightnessScreen: AnyObject {
    var brightness: CGFloat { get set }
}

extension UIScreen: PlayerBrightnessScreen {}

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
    weak var screen: (any PlayerBrightnessScreen)?
    private var originalBrightness: (screen: any PlayerBrightnessScreen, value: CGFloat)?
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
                if originalBrightness == nil { originalBrightness = (screen, screen.brightness) }
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
        if let originalBrightness { originalBrightness.screen.brightness = originalBrightness.value }
        originalBrightness = nil
        dismissIndicator()
    }

    func dismissIndicator() {
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
            controls?.volumeSlider = findSlider(in: volumeView)
        }
        private func findSlider(in view: UIView) -> UISlider? {
            if let slider = view as? UISlider { return slider }
            for child in view.subviews {
                if let slider = findSlider(in: child) { return slider }
            }
            return nil
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
    var usesSidePlacement = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let indicator = controls.indicator {
                let label = indicator.target == .brightness ? "亮度" : "音量"
                let symbol = indicator.target == .brightness ? "sun.max.fill" : "speaker.wave.2.fill"
                if usesSidePlacement {
                    sideIndicator(indicator, symbol: symbol)
                } else {
                    inlineIndicator(indicator, label: label, symbol: symbol)
                }
            }
        }
        .foregroundStyle(.white)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: controls.indicator != nil)
    }

    private func sideIndicator(_ indicator: PlayerSystemControls.Indicator, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.subheadline.weight(.semibold))
            if indicator.unavailable {
                Text("音量不可调")
                    .font(.caption2.weight(.medium))
            } else {
                Capsule().fill(.white.opacity(0.22))
                    .frame(width: 4, height: 48)
                    .overlay(alignment: .bottom) {
                        Capsule().fill(.white)
                            .frame(width: 4, height: 48 * indicator.value)
                    }
                Text(percent(indicator.value))
                    .font(.caption2.weight(.semibold).monospacedDigit())
            }
        }
        .padding(.vertical, 10)
        .frame(minWidth: 48)
        .padding(.horizontal, indicator.unavailable ? 8 : 0)
        .background(.black.opacity(0.73), in: .rect(cornerRadius: 15))
        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(.white.opacity(0.15)) }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: indicator.target == .brightness ? .leading : .trailing)
        .transition(.opacity)
    }

    private func inlineIndicator(_ indicator: PlayerSystemControls.Indicator, label: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
            if indicator.unavailable {
                Text("当前输出不支持调节").font(.footnote)
            } else {
                Text(label)
                ProgressView(value: indicator.value).frame(width: 72).tint(.white)
                Text(percent(indicator.value))
                    .monospacedDigit().frame(minWidth: 36, alignment: .trailing)
            }
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.black.opacity(0.75), in: .capsule)
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
