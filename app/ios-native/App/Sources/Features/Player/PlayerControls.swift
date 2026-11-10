import AniCore
import SwiftUI

/// 全屏播放的控件层, 叠在画面之上, 使用 Liquid Glass 材质.
///
/// 布局: 顶部是网速, 标题, 时间与电量; 左上角关闭播放页, 切换填充/适应, 切换横竖屏; 右上角画中画与选集;
/// 左侧截图与锁定; 右侧调节速度; 底部上一集, 播放/暂停, 下一集, 跳过 OP/ED, 进度与设置菜单.
/// 锁定后只显示解锁按钮.
struct PlayerControls: View {
    @Bindable var model: PlayerModel
    let canStartPictureInPicture: Bool
    @Binding var isLocked: Bool
    /// 关闭播放页, 回到上一页.
    let onClosePage: () -> Void
    /// 回到竖屏播放页.
    let onExitFullscreen: () -> Void
    let onShowSources: () -> Void
    let onShowWatchTogether: () -> Void
    let onPictureInPicture: () -> Void
    /// 用户操作了控件; 用于推迟自动隐藏.
    let onInteraction: () -> Void

    var body: some View {
        if isLocked {
            lockButton
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
        } else {
            GlassEffectContainer(spacing: 12) {
                ZStack {
                    VStack(spacing: 10) {
                        PlayerStatusRow(model: model)
                        topRow
                        Spacer()
                        PlayerBottomBar(
                            model: model,
                            onShowSources: onShowSources,
                            onShowWatchTogether: onShowWatchTogether,
                            onInteraction: onInteraction,
                        )
                    }
                    HStack {
                        VStack(spacing: 0) {
                            iconButton("camera", label: "截图") { model.saveScreenshot() }
                            lockToggle
                        }
                        .glassEffect(.regular.interactive(), in: .capsule)
                        Spacer()
                        speedControl
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    // MARK: - 顶部

    private var topRow: some View {
        HStack {
            HStack(spacing: 0) {
                iconButton("xmark", label: "关闭播放页", action: onClosePage)
                iconButton(
                    model.fillsScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    label: model.fillsScreen ? "完整显示画面" : "画面填充屏幕",
                ) {
                    model.fillsScreen.toggle()
                }
                iconButton("iphone", label: "切换到竖屏", action: onExitFullscreen)
            }
            .glassEffect(.regular.interactive(), in: .capsule)

            Spacer()

            HStack(spacing: 0) {
                if canStartPictureInPicture {
                    iconButton("pip.enter", label: "画中画", action: onPictureInPicture)
                }
                EpisodeListMenu(model: model) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 46, height: 40)
                        .contentShape(.rect)
                }
                .accessibilityLabel("选集")
            }
            .glassEffect(.regular.interactive(), in: .capsule)
        }
    }

    // MARK: - 两侧

    private var lockToggle: some View {
        iconButton(isLocked ? "lock.fill" : "lock.open", label: isLocked ? "解锁" : "锁定") {
            withAnimation(.easeInOut(duration: 0.2)) { isLocked.toggle() }
        }
    }

    private var lockButton: some View {
        lockToggle.glassEffect(.regular.interactive(), in: .capsule)
    }

    private var speedControl: some View {
        VStack(spacing: 0) {
            iconButton("plus", label: "加速") { model.stepPlaybackRate(1) }
                .disabled(model.playbackRate >= PlayerModel.rateSteps.last ?? 3)
            Button {
                model.setPlaybackRate(1)
                onInteraction()
            } label: {
                Text(Self.rateText(model.playbackRate))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .frame(width: 46, height: 32)
                    .contentShape(.rect)
            }
            .accessibilityLabel("播放速度 \(Self.rateText(model.playbackRate)), 点按恢复正常速度")
            iconButton("minus", label: "减速") { model.stepPlaybackRate(-1) }
                .disabled(model.playbackRate <= PlayerModel.rateSteps.first ?? 0.5)
        }
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func iconButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            onInteraction()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 46, height: 40)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    static func rateText(_ rate: Float) -> String {
        let text = rate == rate.rounded() ? String(Int(rate)) : String(format: "%g", rate)
        return "\(text)x"
    }
}

// MARK: - 状态行

/// 顶部一行: 网速, 标题, 时间与电量. 全屏时代替系统状态栏.
private struct PlayerStatusRow: View {
    let model: PlayerModel

    var body: some View {
        ZStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 120)
            HStack {
                Text(Self.speedText(model.networkSpeed))
                    .monospacedDigit()
                Spacer()
                TimelineView(.everyMinute) { context in
                    Text(context.date, format: .dateTime.hour().minute())
                }
                BatteryIndicator()
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.4), radius: 3)
    }

    private var title: String {
        let episode = model.target.episode
        let name = episode.displayName.isEmpty ? "" : " \(episode.displayName)"
        return "\(model.target.subject.displayName) 第 \(episode.sort) 话\(name)"
    }

    static func speedText(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_000_000 { return String(format: "%.1fMB/s", bytesPerSecond / 1_000_000) }
        return "\(Int(bytesPerSecond / 1000))KB/s"
    }
}

private struct BatteryIndicator: View {
    @State private var level: Float = UIDevice.current.batteryLevel
    @State private var state: UIDevice.BatteryState = UIDevice.current.batteryState

    var body: some View {
        HStack(spacing: 3) {
            if level >= 0 {
                Text("\(Int((level * 100).rounded()))")
                    .monospacedDigit()
            }
            Image(systemName: symbol)
        }
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in refresh() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(level >= 0 ? "电量 \(Int(level * 100))%" : "电量")
    }

    private var symbol: String {
        if state == .charging || state == .full { return "battery.100percent.bolt" }
        guard level >= 0 else { return "battery.100percent" }
        switch level {
        case ..<0.13: return "battery.0percent"
        case ..<0.38: return "battery.25percent"
        case ..<0.63: return "battery.50percent"
        case ..<0.88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func refresh() {
        level = UIDevice.current.batteryLevel
        state = UIDevice.current.batteryState
    }
}

// MARK: - 底栏

/// 底部玻璃栏: 上一集, 播放/暂停, 下一集, 跳过 OP/ED, 进度与设置.
private struct PlayerBottomBar: View {
    @Bindable var model: PlayerModel
    let onShowSources: () -> Void
    let onShowWatchTogether: () -> Void
    let onInteraction: () -> Void

    @State private var scrubbing: Double?

    var body: some View {
        HStack(spacing: 4) {
            button("backward.end.fill", label: "上一集") { model.playPreviousEpisode() }
                .disabled(model.previousEpisode == nil)
            button(model.isPlaying ? "pause.fill" : "play.fill", label: model.isPlaying ? "暂停" : "播放", size: 22) {
                model.togglePlayback()
            }
            .disabled(model.phase != .playing)
            button("forward.end.fill", label: "下一集") { model.playNextEpisode() }
                .disabled(model.nextEpisode == nil)
            button("forward.frame.fill", label: "跳过 OP/ED (\(model.manualSkipSeconds) 秒)") { model.skipOpEd() }
                .disabled(model.phase != .playing)

            Text(TimeText.format(scrubbing ?? model.currentTime))
                .padding(.leading, 6)
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
            .tint(.white)
            .disabled(model.duration <= 0)
            .accessibilityLabel("播放进度")
            Text(TimeText.format(model.duration))

            PlayerSettingsMenu(
                model: model,
                onShowSources: onShowSources,
                onShowWatchTogether: onShowWatchTogether,
            ) {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .glassEffect(.regular, in: .capsule)
    }

    private func button(
        _ systemImage: String,
        label: String,
        size: CGFloat = 18,
        action: @escaping () -> Void,
    ) -> some View {
        Button {
            action()
            onInteraction()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 42, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - 选集

/// 选集菜单; 当前剧集带勾选.
struct EpisodeListMenu<Label: View>: View {
    let model: PlayerModel
    @ViewBuilder let label: Label

    var body: some View {
        Menu {
            Picker("选集", selection: Binding(
                get: { model.target.episode.id },
                set: { id in
                    if let episode = model.episodes.first(where: { $0.id == id }) { model.play(episode: episode) }
                },
            )) {
                ForEach(model.episodes.isEmpty ? [model.target.episode] : model.episodes, id: \.id) { episode in
                    Text(Self.title(episode)).tag(episode.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            label
        }
    }

    static func title(_ episode: AniEpisode) -> String {
        episode.displayName.isEmpty ? "第 \(episode.sort) 话" : "\(episode.sort)  \(episode.displayName)"
    }
}

// MARK: - 设置菜单

/// 全屏底栏右侧的设置菜单: 一起看, 画质增强, 弹幕设置, 播放源, 播放信息, 外部链接, 下载.
struct PlayerSettingsMenu<Label: View>: View {
    @Bindable var model: PlayerModel
    let onShowSources: () -> Void
    let onShowWatchTogether: () -> Void
    @ViewBuilder let label: Label

    @Environment(AppServices.self) private var services

    var body: some View {
        Menu {
            watchTogetherMenu

            Menu {
                Picker("画质增强", selection: $model.enhancementMode) {
                    ForEach(VideoEnhancementMode.menuOrder) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                SwiftUI.Label("画质增强", systemImage: "sparkles")
            }

            danmakuMenu

            Button("切换播放源", systemImage: "square.stack", action: onShowSources)

            Button(
                model.showsStats ? "隐藏播放信息" : "显示播放信息",
                systemImage: "chart.bar.xaxis",
            ) {
                model.showsStats.toggle()
            }

            Menu {
                ExternalLinksMenuContent(model: model)
            } label: {
                SwiftUI.Label("外部链接", systemImage: "arrow.up.forward.app")
            }

            Button("下载", systemImage: "arrow.down.circle") {
                model.downloadSelected()
            }
            .disabled(model.selected == nil)
        } label: {
            label
        }
        .accessibilityLabel("设置")
    }

    @ViewBuilder
    private var watchTogetherMenu: some View {
        let room = services.watchTogether.room
        Menu {
            if room?.status == .inRoom, let room {
                Section("\(room.roomName) · \(room.members.count) 人") {
                    if !room.isHost {
                        Toggle("跟随房主", isOn: Binding(
                            get: { room.following },
                            set: { following in
                                Task { try? await services.core.watchTogether.setFollowing(following: following) }
                            },
                        ))
                    }
                    Button("房间详情", systemImage: "person.2", action: onShowWatchTogether)
                    Button("离开房间", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        Task { try? await services.core.watchTogether.leave() }
                    }
                }
            } else {
                Button("加入或创建房间", systemImage: "person.badge.plus", action: onShowWatchTogether)
            }
        } label: {
            SwiftUI.Label("一起看", systemImage: "person.2")
        }
    }

    private var danmakuMenu: some View {
        let settings = services.settings
        return Menu {
            Toggle("显示弹幕", isOn: $model.isDanmakuEnabled)

            if !model.danmakuSources.isEmpty {
                Section("弹幕源") {
                    ForEach(model.danmakuSources) { source in
                        Toggle("\(source.name) (\(source.count))", isOn: Binding(
                            get: { !model.disabledDanmakuSources.contains(source.id) },
                            set: { enabled in
                                if enabled {
                                    model.disabledDanmakuSources.remove(source.id)
                                } else {
                                    model.disabledDanmakuSources.insert(source.id)
                                }
                            },
                        ))
                    }
                }
            }

            if let settings {
                Section("弹幕类型") {
                    Toggle("顶部", isOn: visibility(settings, \.danmakuShowTop))
                    Toggle("底部", isOn: visibility(settings, \.danmakuShowBottom))
                    Toggle("滚动", isOn: visibility(settings, \.danmakuShowFloating))
                    Toggle("彩色", isOn: visibility(settings, \.danmakuShowColor))
                }
            }
        } label: {
            SwiftUI.Label("弹幕设置", systemImage: model.isDanmakuEnabled ? "text.bubble.fill" : "text.bubble")
        }
    }

    /// 弹幕显示类型的开关, 修改后写回设置.
    private func visibility(_ settings: AniSettings, _ keyPath: KeyPath<AniSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                func pick(_ path: KeyPath<AniSettings, Bool>) -> Bool { path == keyPath ? value : settings[keyPath: path] }
                let store = services.core.settings
                Task {
                    try? await store.setDanmakuVisibility(
                        top: pick(\.danmakuShowTop),
                        bottom: pick(\.danmakuShowBottom),
                        floating: pick(\.danmakuShowFloating),
                        color: pick(\.danmakuShowColor),
                    )
                }
            },
        )
    }
}
