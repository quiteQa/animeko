import SwiftUI

let cinemaAccent = Color(red: 0.52, green: 0.72, blue: 1)

/// 选集侧栏与视频各自占用空间。紧凑窗口使用全宽面板，保留同一个视频视图。
struct PlayerCinemaLayout<Video: View, Panel: View>: View {
    let showsPanel: Bool
    @ViewBuilder var video: (_ isCompact: Bool, _ fitsPane: Bool) -> Video
    @ViewBuilder var panel: () -> Panel

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let split = showsPanel && width >= 640
            let panelWidth = split ? min(340, max(244, width * 0.32)) : width
            let videoWidth = split ? width - panelWidth : width
            ZStack(alignment: .trailing) {
                video(videoWidth < 470, split)
                    .frame(width: videoWidth, height: geometry.size.height)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(!showsPanel || split)
                    .accessibilityHidden(showsPanel && !split)
                if showsPanel {
                    panel()
                        .frame(width: panelWidth, height: geometry.size.height)
                        .background {
                            Color(red: 0.075, green: 0.088, blue: 0.12)
                                .ignoresSafeArea(edges: split ? [.top, .bottom, .trailing] : .all)
                        }
                        .transition(.opacity)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
    }
}

/// 进度条使用 44pt 触摸区，拖动中只预览时间，松手后执行一次跳转。
struct CinemaTimeline: View {
    let position: Double
    let duration: Double
    let markers: [Double]
    let accent: Color
    let onSeek: (Double) -> Void
    let onEditingChanged: (Bool) -> Void

    @GestureState private var dragPosition: Double?
    @ScaledMetric(relativeTo: .caption) private var timeWidth = 52.0
    private var canSeek: Bool { duration.isFinite && duration > 0 }
    private var displayedPosition: Double { dragPosition ?? position }

    var body: some View {
        HStack(spacing: 6) {
            Text(TimeText.format(displayedPosition))
                .frame(minWidth: timeWidth, alignment: .leading)
            GeometryReader { geometry in
                let inset = 7.0
                let trackWidth = max(1, geometry.size.width - inset * 2)
                let center = geometry.size.height / 2
                let progress = fraction(displayedPosition)
                ZStack(alignment: .topLeading) {
                    Capsule()
                        .fill(.white.opacity(0.28))
                        .frame(width: trackWidth, height: 3)
                        .position(x: inset + trackWidth / 2, y: center)
                    if progress > 0 {
                        let played = trackWidth * progress
                        Capsule()
                            .fill(accent)
                            .frame(width: played, height: 3)
                            .position(x: inset + played / 2, y: center)
                    }
                    Canvas { context, size in
                        var path = Path()
                        for marker in markers where marker.isFinite && marker > 0 && marker < duration {
                            let x = inset + trackWidth * fraction(marker)
                            path.move(to: CGPoint(x: x, y: size.height / 2 - 4))
                            path.addLine(to: CGPoint(x: x, y: size.height / 2 + 4))
                        }
                        context.stroke(path, with: .color(.white.opacity(0.65)), lineWidth: 1)
                    }
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                        .position(x: inset + trackWidth * progress, y: center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($dragPosition) { drag, state, _ in
                            state = seconds(at: drag.location.x, inset: inset, trackWidth: trackWidth)
                        }
                        .onEnded { drag in
                            guard canSeek else { return }
                            onSeek(seconds(at: drag.location.x, inset: inset, trackWidth: trackWidth))
                        },
                    including: canSeek ? .all : .none
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("播放进度")
                .accessibilityValue("\(TimeText.format(displayedPosition)) / \(TimeText.format(duration))")
                .accessibilityAdjustableAction { direction in
                    guard canSeek else { return }
                    switch direction {
                    case .increment: onSeek(min(duration, position + 10))
                    case .decrement: onSeek(max(0, position - 10))
                    @unknown default: break
                    }
                }
                .disabled(!canSeek)
            }
            .frame(height: 44)
            Text(TimeText.format(duration))
                .foregroundStyle(.white.opacity(0.75))
                .frame(minWidth: timeWidth, alignment: .trailing)
        }
        .font(.caption.weight(.medium).monospacedDigit())
        .lineLimit(1)
        .onChange(of: dragPosition != nil) { _, editing in onEditingChanged(editing) }
        .onDisappear {
            if dragPosition != nil { onEditingChanged(false) }
        }
    }

    private func fraction(_ seconds: Double) -> Double {
        guard canSeek, seconds.isFinite else { return 0 }
        return min(1, max(0, seconds / duration))
    }

    private func seconds(at x: Double, inset: Double, trackWidth: Double) -> Double {
        duration * min(1, max(0, (x - inset) / trackWidth))
    }
}
