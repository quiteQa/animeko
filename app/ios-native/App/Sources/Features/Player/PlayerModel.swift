import AniCore
import AVFoundation
import Foundation
import Photos
import UIKit

/// 播放页状态. Swift 持有 mpv 播放内核 (`MPVPlayer`); Kotlin 会话只负责查询, 选择, 解析, 进度记录与标记看过.
///
/// 一个 `PlayerModel` 在播放页存续期间可以连续播放多集: 切换剧集时关闭旧的 Kotlin 会话, 为新剧集打开会话,
/// 播放内核与播放页保持不变.
@MainActor
@Observable
final class PlayerModel {
    enum Phase: Equatable {
        /// 正在查询数据源并等待自动选择
        case fetching
        /// 正在把选中的资源解析为可播放地址
        case resolving
        case playing
        /// 所有数据源都没有可用资源
        case noSource
        case failed(String)
    }

    private(set) var target: PlaybackTarget
    /// 播放内核. 首次使用时创建: SwiftUI 可能多次构造播放页的初始状态, 不应为每次构造都启动 libmpv.
    @ObservationIgnored private(set) lazy var player = MPVPlayer()

    private(set) var phase: Phase = .fetching
    /// 所有候选资源 (不按偏好过滤)
    private(set) var candidates: [AniMediaCandidate] = []
    /// 符合当前偏好的候选资源
    private(set) var preferredCandidates: [AniMediaCandidate] = []
    private(set) var selected: AniMediaCandidate?
    private(set) var progress: AniFetchProgress?
    private(set) var sources: [AniMediaSourceStatus] = []
    private(set) var preferences: [AniPreference] = []
    private(set) var danmaku: [AniDanmaku] = [] {
        didSet { danmakuRevision = UUID() }
    }
    private var danmakuRevision = UUID()
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false
    var isDanmakuEnabled = true
    /// 用户在本次播放中关闭的弹幕源 (`AniDanmaku.serviceId`).
    var disabledDanmakuSources: Set<String> = []
    /// 画质增强档位, 同时作用于内嵌与全屏画面.
    var enhancementMode: VideoEnhancementMode = .off {
        didSet { player.setEnhancement(enhancementMode.rawValue) }
    }
    /// 是否在画面上显示播放信息.
    var showsStats = false
    /// 已展开的控件菜单数量; 有菜单展开时控件保持显示.
    /// 不参与界面观察: 菜单展开时修改它不会让菜单所在的视图重绘.
    @ObservationIgnored private var openMenuCount = 0
    var isMenuOpen: Bool { openMenuCount > 0 }
    /// 每当所有菜单都关闭时加一; 控件据此重新开始自动隐藏的计时.
    private(set) var menuCloseCount = 0

    func menuDidOpen() { openMenuCount += 1 }

    func menuDidClose() {
        openMenuCount = max(0, openMenuCount - 1)
        if openMenuCount == 0 { menuCloseCount += 1 }
    }
    /// 当前正在播放的地址; 外部链接使用其中的原始播放地址.
    private(set) var playable: AniPlayable?
    /// 画面填充屏幕 (裁切边缘); 为 `false` 时完整显示画面.
    var fillsScreen = false {
        didSet { player.setFillsScreen(fillsScreen) }
    }
    /// 播放速度.
    private(set) var playbackRate: Float = 1
    /// 最近一秒的下载速度 (字节/秒).
    private(set) var networkSpeed: Double = 0
    /// 本条目的全部剧集, 由播放页提供. 用于选集, 上一集与一起看切换剧集.
    var episodes: [AniEpisode] = []
    /// 一次性的提示 (缓存结果, 自动下一集等), 显示后由视图清除.
    var toastMessage: String?

    /// 即将自动跳过的 OP/ED; 用户可以取消.
    private(set) var pendingSkip: AniSkipSegment?
    /// 下一集 (已播出); 没有时为 `nil`.
    private(set) var nextEpisode: AniEpisode?
    private(set) var previousEpisode: AniEpisode?
    /// 手动查找的状态, 关闭选源面板后保留.
    let manualBrowse = ManualBrowseModel()

    /// 当前剧集的 Kotlin 会话, 供手动查找使用.
    var currentSession: AniEpisodeSession? { session }

    @ObservationIgnored private var core: AniClient?
    @ObservationIgnored private var settings: () -> AniSettings? = { nil }
    @ObservationIgnored private var session: AniEpisodeSession?
    /// 随当前剧集会话存续的任务, 切换剧集时取消.
    @ObservationIgnored private let sessionWork = PlaybackTaskScope()
    @ObservationIgnored private let mediaWork = PlaybackTaskScope()
    @ObservationIgnored private var transitionTask: Task<Void, Never>?
    @ObservationIgnored private var closeTask: Task<Void, Never>?
    @ObservationIgnored private var isStopped = false
    @ObservationIgnored private var interruptionToken: PlaybackTaskScope.Token?
    @ObservationIgnored private var backgroundObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastReportedAt: TimeInterval = 0
    @ObservationIgnored private var progressWriter: CoalescingProgressWriter<ProgressSnapshot>?

    private struct ProgressSnapshot {
        let position: Int64
        let duration: Int64
        let playing: Bool
    }
    @ObservationIgnored private var skipTracker: AniSkipTracker?
    /// 为当前媒体加载过跳过片段 (成功或失败都不再重试)
    @ObservationIgnored private var skipSegmentsRequested = false
    @ObservationIgnored private var isSwitchingEpisode = false
    /// 一起看: 本集首次加载后是否已决定 "加载后暂停, 等待房主".
    @ObservationIgnored private var watchTogetherHoldDone = false
    @ObservationIgnored private var playerTasks: [Task<Void, Never>] = []

    /// 可选的播放速度.
    static let rateSteps: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]

    /// 播放中上报进度的间隔 (秒)
    private static let reportInterval: TimeInterval = 5
    /// 播放结束时距离结尾不足这个时长才自动下一集, 与上游一致
    private static let autoNextTolerance: TimeInterval = 5

    init(target: PlaybackTarget) {
        self.target = target
    }

    /// 开始播放. `settings` 每次读取时返回当前设置.
    func start(core: AniClient, settings: @escaping () -> AniSettings?) {
        guard self.core == nil, !isStopped else { return }
        Diagnostics.log("播放页: 开始 \(target.subject.displayName) 第 \(target.episode.sort) 话")
        self.core = core
        self.settings = settings
        if let current = settings() {
            isDanmakuEnabled = current.danmakuEnabled
            enhancementMode = VideoEnhancementMode(setting: current.videoEnhancementDefaultMode)
        }
        observePlayer()
        observeWatchTogether(core.watchTogether)
        openSession()
    }

    func select(_ candidate: AniMediaCandidate) {
        guard let session else { return }
        sessionWork.run { _ in _ = try? await session.select(mediaId: candidate.mediaId) }
    }

    /// 缓存正在播放的资源. 进度在 "我的 > 缓存管理" 查看.
    func downloadSelected() {
        guard let session else { return }
        sessionWork.run { [weak self] token in
            do {
                try await session.downloadSelected()
                guard let self, sessionWork.accepts(token) else { return }
                toastMessage = "已加入缓存"
            } catch {
                guard let self, sessionWork.accepts(token) else { return }
                toastMessage = "缓存失败, 请重试"
            }
        }
    }

    /// 按设置筛选要显示的弹幕类型.
    /// 本集的弹幕源及各自的弹幕数量, 按数量降序.
    var danmakuSources: [DanmakuSource] {
        Dictionary(grouping: danmaku, by: \.serviceId)
            .map { DanmakuSource(id: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    /// 已启用的弹幕源中的弹幕数量.
    var enabledDanmakuCount: Int {
        disabledDanmakuSources.isEmpty ? danmaku.count : danmaku.filter { !disabledDanmakuSources.contains($0.serviceId) }.count
    }

    func danmakuRenderKey(settings: AniSettings?) -> DanmakuRenderKey {
        DanmakuRenderKey(
            revision: danmakuRevision,
            disabledSources: disabledDanmakuSources,
            showsTop: settings?.danmakuShowTop ?? true,
            showsBottom: settings?.danmakuShowBottom ?? true,
            showsFloating: settings?.danmakuShowFloating ?? true,
        )
    }

    func visibleDanmaku(settings: AniSettings?) -> [AniDanmaku] {
        let danmaku = disabledDanmakuSources.isEmpty
            ? self.danmaku
            : self.danmaku.filter { !disabledDanmakuSources.contains($0.serviceId) }
        guard let settings else { return danmaku }
        if settings.danmakuShowTop, settings.danmakuShowBottom, settings.danmakuShowFloating { return danmaku }
        return danmaku.filter { item in
            switch item.location {
            case .top: settings.danmakuShowTop
            case .bottom: settings.danmakuShowBottom
            default: settings.danmakuShowFloating
            }
        }
    }

    /// 切换手动查找的 "记住选择"; 关闭时删除本条目的浏览记忆.
    func setRememberManualSelection(_ remember: Bool) {
        guard let session else { return }
        sessionWork.run { _ in try? await session.setRememberManualSelection(remember: remember) }
    }

    func retrySource(_ source: AniMediaSourceStatus) {
        session?.retrySource(instanceId: source.instanceId)
    }

    func setPreference(key: String, value: String?) {
        guard let session else { return }
        sessionWork.run { _ in try? await session.setPreference(key: key, value: value) }
    }

    /// 数据源 ID 对应的显示名称.
    func sourceName(_ mediaSourceId: String) -> String {
        sources.first { $0.mediaSourceId == mediaSourceId }?.displayName ?? mediaSourceId
    }

    func togglePlayback() {
        isPlaying ? player.pause() : player.play()
    }

    /// 是否已加载媒体.
    private var hasMedia: Bool { player.hasMedia }

    // MARK: - 速度, 截图

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        player.setSpeed(Double(rate))
    }

    /// 切换到相邻的速度档位. `step` 为 1 加速, -1 减速.
    func stepPlaybackRate(_ step: Int) {
        let steps = Self.rateSteps
        let index = steps.firstIndex { $0 >= playbackRate - 0.001 } ?? steps.count - 1
        let next = steps[max(0, min(steps.count - 1, index + step))]
        setPlaybackRate(next)
    }

    /// 截取当前画面并保存到相册.
    func saveScreenshot() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("screenshot-\(UUID().uuidString).png")
        guard hasMedia else { toastMessage = "暂时无法截图"; return }
        Task {
            defer { try? FileManager.default.removeItem(at: file) }
            guard await player.screenshot(to: file), let photo = UIImage(contentsOfFile: file.path) else {
                if !isStopped { toastMessage = "暂时无法截图" }
                return
            }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                toastMessage = "没有相册权限, 请在设置中允许 Animeko 添加照片"
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: photo)
                }
                toastMessage = "截图已保存到相册"
            } catch {
                toastMessage = "保存截图失败"
            }
        }
    }

    func seek(to seconds: TimeInterval) {
        guard !isStopped, seconds.isFinite else { return }
        player.seek(to: seconds)
    }

    func skip(by seconds: TimeInterval) {
        seek(to: max(0, min(currentTime + seconds, duration)))
    }

    /// 弹幕层按此读取播放器时间. 没有媒体时为 `nil`.
    func playbackTime() -> TimeInterval? {
        guard hasMedia else { return nil }
        let seconds = player.position
        return seconds.isFinite ? seconds : nil
    }

    // MARK: - OP/ED

    /// 手动跳过 OP/ED 按钮一次跳过的秒数.
    var manualSkipSeconds: Int {
        Int(settings()?.opEdSkipSeconds ?? 85)
    }

    /// 手动跳过 OP/ED: 前进 `manualSkipSeconds` 秒, 并上报跳过点帮助服务器统计.
    func skipOpEd() {
        let position = currentTime
        skip(by: TimeInterval(manualSkipSeconds))
        guard let session else { return }
        sessionWork.run { _ in try? await session.reportManualSkip(positionMillis: Int64(position * 1000)) }
    }

    /// 取消即将进行的自动跳过.
    func cancelAutoSkip() {
        skipTracker?.cancel()
        pendingSkip = nil
    }

    // MARK: - 剧集

    func playPreviousEpisode() {
        guard let previous = previousEpisode else { return }
        play(episode: previous)
    }

    /// 切换到下一集. `automatic` 表示播放结束时自动触发.
    func playNextEpisode(automatic: Bool = false) {
        guard let next = nextEpisode else { return }
        if automatic { toastMessage = "自动播放下一集: 第 \(next.sort) 话" }
        play(episode: next)
    }

    /// 在当前播放页内切换到 `episode`: 保存旧剧集的进度并关闭其会话, 再为新剧集查询资源.
    func play(episode: AniEpisode) {
        guard !isStopped, episode.id != target.episode.id, !isSwitchingEpisode else { return }
        isSwitchingEpisode = true
        transitionTask = Task { [weak self] in
            guard let self else { return }
            await closeSession()
            guard !isStopped, !Task.isCancelled else { return }
            resetEpisodeState()
            target = PlaybackTarget(subject: target.subject, episode: episode)
            isSwitchingEpisode = false
            openSession()
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        transitionTask?.cancel()
        playerTasks.forEach { $0.cancel() }
        playerTasks.removeAll()
        core?.watchTogether.clearWatching()
        backgroundObservers.forEach { NotificationCenter.default.removeObserver($0) }
        backgroundObservers.removeAll()
        player.onChange = nil
        player.onReady = nil
        player.onEndOfFile = nil
        player.onLoadFailed = nil
        player.pause()
        Task {
            await closeSession()
            player.destroy()
        }
    }

    // MARK: - 会话

    private func openSession() {
        guard let core, !isStopped else { return }
        let session = core.openEpisode(subjectId: target.subject.id, episodeId: target.episode.id)
        self.session = session
        progressWriter = CoalescingProgressWriter { snapshot in
            do {
                try await session.reportPlayback(positionMillis: snapshot.position, durationMillis: snapshot.duration, isPlaying: snapshot.playing)
            } catch {
                Diagnostics.log("播放进度本地保存失败, episode=\(session.episodeId)")
            }
        }

        sessionWork.run { [weak self] token in
            for await list in session.candidateUpdates(preferredOnly: false) {
                guard let self, sessionWork.accepts(token) else { return }
                candidates = list
            }
        }
        sessionWork.run { [weak self] token in
            for await list in session.candidateUpdates(preferredOnly: true) {
                guard let self, sessionWork.accepts(token) else { return }
                preferredCandidates = list
            }
        }
        sessionWork.run { [weak self] token in
            for await progress in session.fetchProgressUpdates {
                guard let self, sessionWork.accepts(token) else { return }
                self.progress = progress
            }
        }
        sessionWork.run { [weak self] token in
            for await sources in session.sourceUpdates {
                guard let self, sessionWork.accepts(token) else { return }
                self.sources = sources
            }
        }
        sessionWork.run { [weak self] token in
            for await preferences in session.preferenceUpdates {
                guard let self, sessionWork.accepts(token) else { return }
                self.preferences = preferences
            }
        }
        sessionWork.run { [weak self] token in
            for await candidate in session.selectionUpdates {
                guard let self, sessionWork.accepts(token) else { return }
                let changed = candidate?.mediaId != selected?.mediaId
                selected = candidate
                if changed, candidate != nil { play(session: session) }
            }
        }
        sessionWork.run { [weak self] token in
            do {
                let chosen = try await session.autoSelect()
                guard let self, sessionWork.accepts(token) else { return }
                if chosen == nil, selected == nil { phase = .noSource }
            } catch {
                guard let self, sessionWork.accepts(token) else { return }
                if selected == nil { phase = .failed(Self.describe(error)) }
            }
        }
        sessionWork.run { [weak self] token in
            guard let list = try? await session.fetchDanmaku(),
                  let self, sessionWork.accepts(token) else { return }
            danmaku = list
        }
        sessionWork.run { [weak self] token in
            let next = try? await session.nextEpisode()
            let previous = try? await session.previousEpisode()
            guard let self, sessionWork.accepts(token) else { return }
            nextEpisode = next
            previousEpisode = previous
        }
    }

    /// 最后一次本地保存完成后释放会话; 关闭期间禁止旧任务发布结果.
    private func closeSession() async {
        if let closeTask { await closeTask.value; return }
        reportProgress(force: true)
        let tasks = sessionWork.invalidate() + mediaWork.invalidate()
        manualBrowse.reset()
        let session = self.session
        let writer = progressWriter
        self.session = nil
        progressWriter = nil
        // 先停止读取当前代理资源, 再释放 Kotlin 解析会话.
        player.stop()
        let closing = Task {
            for task in tasks { await task.value }
            await writer?.flush()
            session?.close()
        }
        closeTask = closing
        await closing.value
        closeTask = nil
    }

    private func resetEpisodeState() {
        player.stop()
        phase = .fetching
        candidates = []
        preferredCandidates = []
        selected = nil
        progress = nil
        sources = []
        preferences = []
        danmaku = []
        playable = nil
        watchTogetherHoldDone = false
        currentTime = 0
        duration = 0
        nextEpisode = nil
        previousEpisode = nil
        isPlaying = false
        networkSpeed = 0
        manualBrowse.reset()
        lastReportedAt = 0
        resetSkipState()
    }

    private func resetSkipState() {
        skipTracker = nil
        skipSegmentsRequested = false
        pendingSkip = nil
    }

    // MARK: - 播放

    private func play(session: AniEpisodeSession) {
        let previousTasks = mediaWork.invalidate()
        reportProgress(force: true)
        let switchingAt = hasMedia ? currentTime : nil
        player.stop()
        phase = .resolving
        let sessionToken = sessionWork.token
        mediaWork.run { [weak self] token in
            // resolveSelected 会释放旧解析资源, 必须先等上一解析退出.
            for task in previousTasks { await task.value }
            guard let self, mediaWork.accepts(token), sessionWork.accepts(sessionToken) else { return }
            do {
                let resumeAt: TimeInterval
                if let switchingAt {
                    resumeAt = switchingAt
                } else {
                    resumeAt = TimeInterval((try? await session.resumePositionMillis()) ?? 0) / 1000
                }
                let playable = try await session.resolveSelected(startPositionMillis: Int64(resumeAt * 1000))
                guard mediaWork.accepts(token), sessionWork.accepts(sessionToken) else { return }
                self.playable = playable
                resetSkipState()
                player.setSpeed(Double(playbackRate))
                player.load(url: playable.url, headers: playable.headers, start: resumeAt, autoplay: !holdsForWatchTogether())
                currentTime = resumeAt
                // phase 由 mpv 的 PLAYBACK_RESTART 确认, 命令提交成功不代表媒体可播放.
            } catch {
                guard mediaWork.accepts(token), sessionWork.accepts(sessionToken) else { return }
                phase = .failed(Self.describe(error))
            }
        }
    }

    private func reportProgress(force: Bool = false) {
        guard session != nil, duration.isFinite, currentTime.isFinite, duration > 0, currentTime > 0 else { return }
        guard force || currentTime - lastReportedAt >= Self.reportInterval || currentTime < lastReportedAt else { return }
        lastReportedAt = currentTime
        progressWriter?.submit(ProgressSnapshot(
            position: Int64(min(currentTime, duration) * 1000),
            duration: Int64(duration * 1000),
            playing: isPlaying,
        ))
    }

    /// 时长已知后为当前媒体加载一次跳过片段 (需要开启自动跳过).
    private func loadSkipSegmentsIfNeeded() {
        guard !skipSegmentsRequested, duration > 0, let session, settings()?.autoSkipOpEd == true else { return }
        skipSegmentsRequested = true
        let durationMillis = Int64(duration * 1000)
        mediaWork.run { [weak self] token in
            guard let segments = try? await session.skipSegments(videoDurationMillis: durationMillis),
                  !segments.isEmpty, let self, mediaWork.accepts(token), self.session === session else { return }
            skipTracker = AniSkipTracker(segments: segments)
        }
    }

    private func updateAutoSkip() {
        guard let skipTracker, settings()?.autoSkipOpEd == true else {
            pendingSkip = nil
            return
        }
        let target = skipTracker.update(positionMillis: Int64(currentTime * 1000))
        pendingSkip = skipTracker.pendingSegment
        if target >= 0 {
            seek(to: TimeInterval(target) / 1000)
            toastMessage = "已跳过 OP/ED"
        }
    }

    private func observePlayer() {
        player.setEnhancement(enhancementMode.rawValue)
        player.onChange = { [weak self] in self?.onPlayerChanged() }
        player.onReady = { [weak self] in
            guard let self, !isStopped, session != nil, phase == .resolving else { return }
            phase = .playing
            startPlaybackAfterLoad()
        }
        player.onEndOfFile = { [weak self] in
            self?.onPlayedToEnd()
        }
        player.onLoadFailed = { [weak self] message in
            self?.onLoadFailed(message)
        }
        // 后台只保留声音; 回到前台恢复画面
        let center = NotificationCenter.default
        backgroundObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reportProgress(force: true)
                    self?.player.setVideoEnabled(false)
                }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.player.setVideoEnabled(true) }
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated { self?.handleAudioInterruption(notification) }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self,
                          let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                          reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                    interruptionToken = nil
                    player.pause()
                }
            },
        ]
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard !isStopped,
              let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            interruptionToken = isPlaying ? sessionWork.token : nil
            player.pause()
            reportProgress(force: true)
        case .ended:
            let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
            defer { interruptionToken = nil }
            guard shouldResume, let interruptionToken, sessionWork.accepts(interruptionToken) else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                player.play()
            } catch { toastMessage = "音频恢复失败, 请点按播放重试" }
        @unknown default: break
        }
    }

    private func onPlayerChanged() {
        let playing = player.hasMedia && !player.isPaused
        if playing != isPlaying { onPlayingChanged(playing) }
        guard phase == .playing, player.hasMedia else { return }
        // mpv 每帧都报告位置; 界面只显示到秒, 位置变化不足 0.25 秒时不更新, 避免控件 (包括展开中的菜单) 每帧重绘
        let position = player.position.isFinite ? player.position : 0
        if abs(position - currentTime) >= 0.25 { currentTime = position }
        let newDuration = player.duration.isFinite ? player.duration : 0
        if newDuration != duration { duration = newDuration }
        if player.cacheSpeed != networkSpeed { networkSpeed = player.cacheSpeed }
        if isPlaying {
            reportProgress()
            loadSkipSegmentsIfNeeded()
            updateAutoSkip()
        }
    }

    private func onPlayingChanged(_ playing: Bool) {
        let paused = isPlaying && !playing
        isPlaying = playing
        if paused { reportProgress(force: true) }
    }

    private func onLoadFailed(_ message: String) {
        guard !isStopped, phase == .playing || phase == .resolving else { return }
        phase = .failed("视频加载失败 (\(message)), 请换一个资源")
    }

    private func onPlayedToEnd() {
        let position = player.position
        currentTime = position.isFinite ? position : currentTime
        reportProgress(force: true)
        guard settings()?.autoPlayNext == true,
              duration > 0, duration - currentTime < Self.autoNextTolerance else { return }
        playNextEpisode(automatic: true)
    }

    // MARK: - 一起看

    /// 媒体加载完成后开始播放. 在一起看房间中 (房主或跟随房主) 首次加载后先暂停, 等房主开始播放;
    /// 跟随者随后同步到房主的位置与状态.
    private func startPlaybackAfterLoad() {
        guard holdsForWatchTogether(), let watchTogether = core?.watchTogether else { return }
        watchTogetherHoldDone = true
        if let target = watchTogether.initialTarget() { apply(target) }
    }

    /// 本集首次加载时是否应先暂停, 等待房主.
    private func holdsForWatchTogether() -> Bool {
        guard let watchTogether = core?.watchTogether else { return false }
        return !watchTogetherHoldDone && watchTogether.isSyncActive()
    }

    private func observeWatchTogether(_ watchTogether: AniWatchTogether) {
        playerTasks.append(Task { [weak self] in
            for await directive in watchTogether.directiveUpdates {
                self?.apply(directive)
            }
        })
        playerTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                self?.reportWatching(to: watchTogether)
                try? await Task.sleep(for: .seconds(1))
            }
        })
    }

    /// 应用房主的同步指令: 相差超过 3 秒 (或强制) 时跳转, 然后对齐速度与播放/暂停.
    private func apply(_ directive: AniPlaybackDirective) {
        guard directive.subjectId == target.subject.id else { return }
        if directive.kind == .switchEpisode {
            guard directive.episodeId != target.episode.id,
                  let episode = episodes.first(where: { $0.id == directive.episodeId }) else { return }
            play(episode: episode)
            return
        }
        guard directive.episodeId == target.episode.id, phase == .playing, hasMedia else { return }
        let local = player.position.isFinite ? player.position : currentTime
        let targetSeconds = TimeInterval(directive.positionMillis) / 1000
        var appliedDelta: Int64?
        if directive.forceSeek || abs(local - targetSeconds) > 3 {
            seek(to: targetSeconds)
            appliedDelta = Int64((targetSeconds - local) * 1000)
        }
        if abs(directive.playbackRate - playbackRate) > 0.001 { setPlaybackRate(directive.playbackRate) }
        if directive.paused {
            if !player.isPaused { player.pause() }
        } else if player.isPaused {
            player.play()
        }
        if let appliedDelta, !directive.forceSeek {
            core?.watchTogether.notifyCorrectionApplied(deltaMillis: appliedDelta)
        }
    }

    /// 每秒上报一次本地播放状态; 媒体加载前上报 "加载中", 让房间成员能同时打开这一集.
    private func reportWatching(to watchTogether: AniWatchTogether) {
        guard session != nil else { return }
        let loaded = phase == .playing && hasMedia
        let position = loaded && player.position.isFinite ? player.position : 0
        watchTogether.reportWatching(
            subjectId: target.subject.id,
            episodeId: target.episode.id,
            subjectName: target.subject.displayName,
            episodeSort: target.episode.sort,
            episodeName: target.episode.displayName,
            positionMillis: Int64(position * 1000),
            durationMillis: loaded ? Int64(duration * 1000) : 0,
            paused: !loaded || player.isPaused,
            buffering: loaded && player.isBuffering,
            playbackRate: playbackRate,
        )
    }

    private static func describe(_ error: Error) -> String {
        switch error.aniPlaybackReason {
        case "NO_MATCHING_RESOURCE": "这个资源里没有找到视频, 请换一个资源"
        case "NETWORK_ERROR": "网络错误, 请检查网络后重试"
        case "FETCH_TIMEOUT": "解析超时, 请换一个资源"
        case "UNSUPPORTED", "UNSUPPORTED_VIDEO_SOURCE", "ENGINE_DISABLED": "iOS 暂不支持播放这种资源"
        default: error.localizedDescription
        }
    }
}

/// 一个弹幕源及其弹幕数量.
struct DanmakuSource: Identifiable, Hashable {
    let id: String
    let count: Int

    var name: String {
        switch id {
        case "Dandanplay": "弹弹play"
        case "Bilibili": "哔哩哔哩"
        case "Baha": "巴哈姆特"
        case "Acfun": "AcFun"
        default: id
        }
    }
}
