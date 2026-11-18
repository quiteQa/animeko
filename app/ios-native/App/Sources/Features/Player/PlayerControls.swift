import AniCore
import SwiftUI

/// 横屏播放控件。顶部用于导航，底部将拖动进度与播放操作分为两行。
struct PlayerControls: View {
    @Bindable var model: PlayerModel
    @Binding var isLocked: Bool
    let isCompact: Bool
    let onClosePage: () -> Void
    let onExitFullscreen: () -> Void
    let onShowEpisodes: () -> Void
    let onShowSources: () -> Void
    let onShowWatchTogether: () -> Void
    let onInteraction: () -> Void
    let onSeekingChanged: (Bool) -> Void

    var body: some View {
        if isLocked {
            icon("lock.fill", label: "解锁") { isLocked = false }
                .background(.black.opacity(0.7), in: .circle)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, 12)
        } else {
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .background(alignment: .top) {
                        LinearGradient(colors: [.black.opacity(0.82), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 96)
                            .ignoresSafeArea(edges: [.top, .horizontal])
                            .allowsHitTesting(false)
                    }
                Spacer(minLength: 0)
                bottomBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    .background(alignment: .bottom) {
                        LinearGradient(
                            colors: [.clear, Color(red: 0.045, green: 0.06, blue: 0.10).opacity(0.9), .black.opacity(0.95)],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: 132)
                        .ignoresSafeArea(edges: [.bottom, .horizontal])
                        .allowsHitTesting(false)
                    }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 2) {
            icon("chevron.left", label: "退出全屏", action: onExitFullscreen)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.target.subject.displayName)
                    .font(.headline)
                Text("第 \(model.target.episode.sort) 话")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            if model.canStartPictureInPicture, !isCompact {
                icon("pip.enter", label: "画中画") { model.startPictureInPicture() }
            }
            icon("rectangle.grid.1x2", label: "选集", action: onShowEpisodes)
                .accessibilityIdentifier("cinema-episodes")
            PlayerSettingsMenu(model: model, onShowSources: onShowSources, onShowWatchTogether: onShowWatchTogether,
                               onClosePage: onClosePage) {
                controlSymbol("ellipsis")
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            CinemaTimeline(
                position: model.currentTime, duration: model.phase == .playing ? model.duration : 0,
                markers: model.skipSegments.map { Double($0.startMillis) / 1000 }, accent: cinemaAccent,
                onSeek: { model.seek(to: $0) }, onEditingChanged: onSeekingChanged
            )
            .id(model.target.episode.id)
            ZStack {
                HStack(spacing: 2) {
                    icon("lock.open", label: "锁定") { isLocked = true }
                    if !isCompact {
                        Button {
                            model.skipOpEd()
                            onInteraction()
                        } label: {
                            Text("跳过 OP/ED")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .overlay { Capsule().strokeBorder(.white.opacity(0.35)) }
                                .frame(minHeight: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.phase != .playing)
                    }
                    Spacer()
                    rateMenu
                    if !isCompact {
                        icon(model.isDanmakuEnabled ? "text.bubble.fill" : "text.bubble", label: "弹幕") {
                            model.isDanmakuEnabled.toggle()
                        }
                        .accessibilityAddTraits(model.isDanmakuEnabled ? .isSelected : [])
                        Menu {
                            PlayerTrackMenuContent(model: model, kind: "sub")
                                .reportsMenuPresence(to: model)
                        } label: {
                            controlSymbol("captions.bubble")
                        }
                        .disabled(model.subtitleTracks.isEmpty || model.airPlay.isConnected)
                        .accessibilityLabel("字幕")
                    }
                }
                HStack(spacing: 4) {
                    icon("backward.end.fill", label: "上一集") { model.playPreviousEpisode() }
                        .disabled(model.previousEpisode == nil)
                    Button {
                        model.togglePlayback()
                        onInteraction()
                    } label: {
                        controlSymbol(model.isPlaying ? "pause.fill" : "play.fill", size: 21, width: 48)
                            .background(.white.opacity(0.16), in: .circle)
                            .overlay { Circle().strokeBorder(.white.opacity(0.16)).allowsHitTesting(false) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.isPlaying ? "暂停" : "播放")
                    .disabled(model.phase != .playing)
                    icon("forward.end.fill", label: "下一集") { model.playNextEpisode() }
                        .disabled(model.nextEpisode == nil)
                }
            }
        }
        .foregroundStyle(.white)
    }

    private var rateMenu: some View {
        Menu {
            Picker("播放速度", selection: Binding(
                get: { model.playbackRate },
                set: { model.setPlaybackRate($0); onInteraction() }
            )) {
                ForEach(PlayerModel.rateSteps, id: \.self) { rate in
                    Text(Self.rateText(rate)).tag(rate)
                }
            }
            .reportsMenuPresence(to: model)
        } label: {
            Text(Self.rateText(model.playbackRate))
                .font(.footnote.weight(.semibold).monospacedDigit())
                .frame(width: 52, height: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel("播放速度 \(Self.rateText(model.playbackRate))")
    }

    private func icon(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            onInteraction()
        } label: {
            controlSymbol(symbol)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func controlSymbol(_ symbol: String, size: CGFloat = 17, width: CGFloat = 44) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: width, height: 44)
            .contentShape(.rect)
    }

    private static func rateText(_ rate: Float) -> String {
        "\(String(format: "%g", rate))×"
    }
}

// MARK: - 设置菜单

/// 横屏更多操作。
struct PlayerSettingsMenu<Label: View>: View {
    @Bindable var model: PlayerModel
    let onShowSources: () -> Void
    let onShowWatchTogether: () -> Void
    let onClosePage: () -> Void
    @ViewBuilder let label: Label

    @Environment(AppServices.self) private var services

    var body: some View {
        Menu {
            Section {
                Button(model.fillsScreen ? "完整显示画面" : "画面填充屏幕",
                       systemImage: model.fillsScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                    model.fillsScreen.toggle()
                }
                Button("截图", systemImage: "camera") { model.saveScreenshot() }
                Button("跳过片头或片尾", systemImage: "forward.frame.fill") { model.skipOpEd() }
                    .disabled(model.phase != .playing)
                if model.canStartPictureInPicture {
                    Button("画中画", systemImage: "pip.enter") { model.startPictureInPicture() }
                }
            }

            watchTogetherMenu

            if !model.audioTracks.isEmpty {
                Menu("音轨", systemImage: "waveform") { PlayerTrackMenuContent(model: model, kind: "audio") }
                    .disabled(model.airPlay.isConnected)
            }
            if !model.subtitleTracks.isEmpty {
                Menu("字幕", systemImage: "captions.bubble") { PlayerTrackMenuContent(model: model, kind: "sub") }
                    .disabled(model.airPlay.isConnected)
            }
            Button("AirPlay 视频投送", systemImage: "airplay.video") { model.showsAirPlay = true }
                .disabled(model.playbackURL == nil)
            Button("导出性能报告", systemImage: "square.and.arrow.up") { model.exportPerformanceReport() }

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
            .reportsMenuPresence(to: model)

            Menu {
                ExternalLinksMenuContent(model: model)
            } label: {
                SwiftUI.Label("外部链接", systemImage: "arrow.up.forward.app")
            }

            Button("下载", systemImage: "arrow.down.circle") {
                model.downloadSelected()
            }
            .disabled(model.selected == nil)
            Button("关闭播放页", systemImage: "xmark", action: onClosePage)
        } label: {
            label
        }
        .accessibilityLabel("更多选项")
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

/// 加在控件菜单的一个菜单项上: 菜单展开期间向 `PlayerModel` 报告, 使控件在菜单关闭之前保持显示.
extension View {
    func reportsMenuPresence(to model: PlayerModel) -> some View {
        onAppear { model.menuDidOpen() }
            .onDisappear { model.menuDidClose() }
    }
}
