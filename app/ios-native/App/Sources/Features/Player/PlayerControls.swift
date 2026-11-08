import AniCore
import SwiftUI

/// 播放器控件层: 叠在 `AVPlayerLayer` 之上的 SwiftUI 控件, 使用系统 Liquid Glass 材质.
struct PlayerControls: View {
    let model: PlayerModel
    let canStartPictureInPicture: Bool
    let onClose: () -> Void
    let onShowSources: () -> Void
    let onPictureInPicture: () -> Void
    let onInteraction: () -> Void

    @State private var scrubbing: Double?

    var body: some View {
        GlassEffectContainer(spacing: 16) {
            VStack {
                topBar
                Spacer()
                centerButtons
                Spacer()
                bottomBar
            }
            .padding()
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "chevron.down")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("关闭播放器")

            VStack(alignment: .leading, spacing: 2) {
                Text(model.target.subject.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(episodeTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)

            Spacer()

            if canStartPictureInPicture {
                Button(action: onPictureInPicture) {
                    Image(systemName: "pip.enter")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("画中画")
            }
        }
    }

    private var centerButtons: some View {
        HStack(spacing: 32) {
            Button { model.skip(by: -10); onInteraction() } label: {
                Image(systemName: "gobackward.10").font(.title2).frame(width: 56, height: 56)
            }
            .accessibilityLabel("后退 10 秒")
            Button { model.togglePlayback(); onInteraction() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.largeTitle).frame(width: 76, height: 76)
            }
            .accessibilityLabel(model.isPlaying ? "暂停" : "播放")
            Button { model.skip(by: 10); onInteraction() } label: {
                Image(systemName: "goforward.10").font(.title2).frame(width: 56, height: 56)
            }
            .accessibilityLabel("前进 10 秒")
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .disabled(model.phase != .playing)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack {
                Text(Self.format(scrubbing ?? model.currentTime))
                Slider(
                    value: Binding(
                        get: { scrubbing ?? model.currentTime },
                        set: { scrubbing = $0; onInteraction() },
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
                Text(Self.format(model.duration))
            }
            .font(.caption.monospacedDigit())

            HStack(spacing: 12) {
                Button {
                    model.isDanmakuEnabled.toggle()
                    onInteraction()
                } label: {
                    Label("弹幕", systemImage: model.isDanmakuEnabled ? "text.bubble.fill" : "text.bubble")
                }
                .accessibilityValue(model.isDanmakuEnabled ? "开" : "关")

                Spacer()

                Button(action: onShowSources) {
                    Label(model.selected.map { model.sourceName($0.mediaSourceId) } ?? "选择资源", systemImage: "square.stack")
                        .lineLimit(1)
                }
            }
            .buttonStyle(.glass)
        }
        .padding()
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private var episodeTitle: String {
        let episode = model.target.episode
        return episode.displayName.isEmpty ? "第 \(episode.sort) 话" : "\(episode.sort) · \(episode.displayName)"
    }

    private static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
