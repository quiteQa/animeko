import AniCore
import AVFoundation
import CoreImage
import Foundation
import Photos
import UIKit

/// 播放页状态. Swift 持有 `AVPlayer`; Kotlin 会话只负责查询, 选择, 解析, 进度记录与标记看过.
///
/// 一个 `PlayerModel` 在播放页存续期间可以连续播放多集: 切换剧集时关闭旧的 Kotlin 会话, 为新剧集打开会话,
/// `AVPlayer` 与播放页保持不变.
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
    let player = AVPlayer()

    private(set) var phase: Phase = .fetching
    /// 所有候选资源 (不按偏好过滤)
    private(set) var candidates: [AniMediaCandidate] = []
    /// 符合当前偏好的候选资源
    private(set) var preferredCandidates: [AniMediaCandidate] = []
    private(set) var selected: AniMediaCandidate?
    private(set) var progress: AniFetchProgress?
    private(set) var sources: [AniMediaSourceStatus] = []
    private(set) var preferences: [AniPreference] = []
    private(set) var danmaku: [AniDanmaku] = []
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false
    var isDanmakuEnabled = true
    /// 用户在本次播放中关闭的弹幕源 (`AniDanmaku.serviceId`).
    var disabledDanmakuSources: Set<String> = []
    /// 画质增强档位, 同时作用于内嵌与全屏画面.
    var enhancementMode: VideoEnhancementMode = .off
    /// 是否在画面上显示播放信息.
    var showsStats = false
    /// 当前正在播放的地址; 外部链接使用其中的原始播放地址.
    private(set) var playable: AniPlayable?
    /// 画面填充屏幕 (裁切边缘); 为 `false` 时完整显示画面.
    var fillsScreen = false
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
    /// 手动查找的状态, 关闭选源面板后保留.
    let manualBrowse = ManualBrowseModel()

    /// 当前剧集的 Kotlin 会话, 供手动查找使用.
    var currentSession: AniEpisodeSession? { session }

    @ObservationIgnored private var core: AniCore?
    @ObservationIgnored private var settings: () -> AniSettings? = { nil }
    @ObservationIgnored private var session: AniEpisodeSession?
    /// 随当前剧集会话存续的任务, 切换剧集时取消.
    @ObservationIgnored private var sessionTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var resolveTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var rateObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var lastReportedAt: TimeInterval = 0
    /// 最近一次进度上报. 上报按顺序执行, 关闭会话前等待它完成.
    @ObservationIgnored private var pendingReport: Task<Void, Never>?
    @ObservationIgnored private var skipTracker: AniSkipTracker?
    /// 为当前媒体加载过跳过片段 (成功或失败都不再重试)
    @ObservationIgnored private var skipSegmentsRequested = false
    @ObservationIgnored private var isSwitchingEpisode = false
    /// 截图读取当前帧.
    @ObservationIgnored private var videoOutput: AVPlayerItemVideoOutput?
    @ObservationIgnored private var lastTransferredBytes: Int64 = 0
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
    func start(core: AniCore, settings: @escaping () -> AniSettings?) {
        guard self.core == nil else { return }
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
        Task { _ = try? await session.select(mediaId: candidate.mediaId) }
    }

    /// 缓存正在播放的资源. 进度在 "我的 > 缓存管理" 查看.
    func downloadSelected() {
        guard let session else { return }
        Task {
            do {
                try await session.downloadSelected()
                toastMessage = "已加入缓存"
            } catch {
                toastMessage = "缓存失败: \(error.localizedDescription)"
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
        Task { try? await session.setRememberManualSelection(remember: remember) }
    }

    func retrySource(_ source: AniMediaSourceStatus) {
        session?.retrySource(instanceId: source.instanceId)
    }

    func setPreference(key: String, value: String?) {
        guard let session else { return }
        Task { try? await session.setPreference(key: key, value: value) }
    }

    /// 数据源 ID 对应的显示名称.
    func sourceName(_ mediaSourceId: String) -> String {
        sources.first { $0.mediaSourceId == mediaSourceId }?.displayName ?? mediaSourceId
    }

    func togglePlayback() {
        isPlaying ? player.pause() : player.play()
    }

    // MARK: - 速度, 截图

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        player.defaultRate = rate
        if isPlaying { player.rate = rate }
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
        guard let output = videoOutput,
              let buffer = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) else {
            toastMessage = "暂时无法截图"
            return
        }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = CIContext().createCGImage(image, from: image.extent) else {
            toastMessage = "暂时无法截图"
            return
        }
        let photo = UIImage(cgImage: cgImage)
        Task {
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
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(by seconds: TimeInterval) {
        seek(to: max(0, min(currentTime + seconds, duration)))
    }

    /// 弹幕层按此读取播放器时间. 没有媒体时为 `nil`.
    func playbackTime() -> TimeInterval? {
        guard player.currentItem != nil else { return nil }
        let seconds = player.currentTime().seconds
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
        Task { try? await session.reportManualSkip(positionMillis: Int64(position * 1000)) }
    }

    /// 取消即将进行的自动跳过.
    func cancelAutoSkip() {
        skipTracker?.cancel()
        pendingSkip = nil
    }

    // MARK: - 剧集

    /// 上一集; 当前是第一集或剧集未加载时为 `nil`.
    var previousEpisode: AniEpisode? {
        guard let index = episodes.firstIndex(where: { $0.id == target.episode.id }), index > 0 else { return nil }
        return episodes[index - 1]
    }

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
        guard episode.id != target.episode.id, !isSwitchingEpisode else { return }
        isSwitchingEpisode = true
        Task {
            await closeSession()
            resetEpisodeState()
            target = PlaybackTarget(subject: target.subject, episode: episode)
            isSwitchingEpisode = false
            openSession()
        }
    }

    func stop() {
        playerTasks.forEach { $0.cancel() }
        playerTasks.removeAll()
        core?.watchTogether.clearWatching()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        rateObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.pause()
        Task {
            await closeSession()
            player.replaceCurrentItem(with: nil)
        }
    }

    // MARK: - 会话

    private func openSession() {
        guard let core else { return }
        let session = core.openEpisode(subjectId: target.subject.id, episodeId: target.episode.id)
        self.session = session

        sessionTasks.append(Task { [weak self] in
            for await list in session.candidateUpdates(preferredOnly: false) { self?.candidates = list }
        })
        sessionTasks.append(Task { [weak self] in
            for await list in session.candidateUpdates(preferredOnly: true) { self?.preferredCandidates = list }
        })
        sessionTasks.append(Task { [weak self] in
            for await progress in session.fetchProgressUpdates { self?.progress = progress }
        })
        sessionTasks.append(Task { [weak self] in
            for await sources in session.sourceUpdates { self?.sources = sources }
        })
        sessionTasks.append(Task { [weak self] in
            for await preferences in session.preferenceUpdates { self?.preferences = preferences }
        })
        sessionTasks.append(Task { [weak self] in
            for await candidate in session.selectionUpdates {
                guard let self else { return }
                let changed = candidate?.mediaId != selected?.mediaId
                selected = candidate
                if changed, candidate != nil { play(session: session) }
            }
        })
        sessionTasks.append(Task { [weak self] in
            do {
                let chosen = try await session.autoSelect()
                if chosen == nil, self?.selected == nil { self?.phase = .noSource }
            } catch {
                if self?.selected == nil { self?.phase = .failed(error.localizedDescription) }
            }
        })
        sessionTasks.append(Task { [weak self] in
            // 弹幕失败不影响播放
            if let list = try? await session.fetchDanmaku() { self?.danmaku = list }
        })
        sessionTasks.append(Task { [weak self] in
            self?.nextEpisode = try? await session.nextEpisode()
        })
    }

    /// 上报最后的进度, 停止本集的任务并关闭 Kotlin 会话.
    private func closeSession() async {
        reportProgress(force: true)
        sessionTasks.forEach { $0.cancel() }
        sessionTasks.removeAll()
        resolveTask?.cancel()
        resolveTask = nil
        let session = self.session
        self.session = nil
        await pendingReport?.value
        session?.close()
    }

    private func resetEpisodeState() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        phase = .fetching
        candidates = []
        preferredCandidates = []
        selected = nil
        progress = nil
        sources = []
        preferences = []
        danmaku = []
        playable = nil
        videoOutput = nil
        watchTogetherHoldDone = false
        currentTime = 0
        duration = 0
        nextEpisode = nil
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
        resolveTask?.cancel()
        reportProgress(force: true)
        phase = .resolving
        // 换源时从当前位置继续; 首次播放从上次记录的位置开始
        let switchingAt = player.currentItem == nil ? nil : currentTime
        resolveTask = Task { [weak self] in
            do {
                let resumeAt: TimeInterval
                if let switchingAt {
                    resumeAt = switchingAt
                } else {
                    resumeAt = TimeInterval((try? await session.resumePositionMillis()) ?? 0) / 1000
                }
                let playable = try await session.resolveSelected(startPositionMillis: Int64(resumeAt * 1000))
                guard let self, !Task.isCancelled else { return }
                let asset = AVURLAsset(
                    url: URL(string: playable.url)!,
                    options: ["AVURLAssetHTTPHeaderFieldsKey": playable.headers],
                )
                let item = AVPlayerItem(asset: asset)
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                ])
                item.add(output)
                videoOutput = output
                lastTransferredBytes = 0
                player.replaceCurrentItem(with: item)
                self.playable = playable
                observeEnd(of: item)
                // 换源后时间轴可能不同, 重新加载跳过片段
                resetSkipState()
                if resumeAt > 0 { await player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600)) }
                phase = .playing
                startPlaybackAfterLoad()
            } catch {
                guard let self, !Task.isCancelled else { return }
                phase = .failed(Self.describe(error))
            }
        }
    }

    /// 上报进度给 Kotlin 侧保存, 并在看到 90% 时标记看过. 播放中每 `reportInterval` 秒一次; `force` 时立即上报.
    private func reportProgress(force: Bool = false) {
        guard let session, duration > 0, currentTime > 0 else { return }
        guard force || currentTime - lastReportedAt >= Self.reportInterval || currentTime < lastReportedAt else { return }
        lastReportedAt = currentTime
        let position = Int64(currentTime * 1000)
        let total = Int64(duration * 1000)
        let playing = isPlaying
        let previous = pendingReport
        pendingReport = Task {
            await previous?.value
            try? await session.reportPlayback(positionMillis: position, durationMillis: total, isPlaying: playing)
        }
    }

    /// 时长已知后为当前媒体加载一次跳过片段 (需要开启自动跳过).
    private func loadSkipSegmentsIfNeeded() {
        guard !skipSegmentsRequested, duration > 0, let session, settings()?.autoSkipOpEd == true else { return }
        skipSegmentsRequested = true
        let durationMillis = Int64(duration * 1000)
        Task { [weak self] in
            guard let segments = try? await session.skipSegments(videoDurationMillis: durationMillis),
                  !segments.isEmpty, let self, self.session === session else { return }
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
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main,
        ) { [weak self] time in
            // 回调在主队列上; 闭包体放进方法里, 避免在嵌套闭包里隐式使用 self
            MainActor.assumeIsolated { self?.onPeriodicTime(time) }
        }
        rateObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor [weak self] in self?.onPlayingChanged(playing) }
        }
    }

    private func onPeriodicTime(_ time: CMTime) {
        guard phase == .playing else { return }
        currentTime = time.seconds.isFinite ? time.seconds : 0
        let itemDuration = player.currentItem?.duration.seconds ?? 0
        duration = itemDuration.isFinite ? itemDuration : 0
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

    /// 播放自然结束且离结尾足够近时, 按设置自动播放下一集.
    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onPlayedToEnd() }
        }
    }

    private func onPlayedToEnd() {
        let position = player.currentTime().seconds
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
        player.defaultRate = playbackRate
        guard let watchTogether = core?.watchTogether, !watchTogetherHoldDone, watchTogether.isSyncActive() else {
            player.play()
            return
        }
        watchTogetherHoldDone = true
        player.pause()
        if let target = watchTogether.initialTarget() { apply(target) }
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
                self?.sampleNetworkSpeed()
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
        guard directive.episodeId == target.episode.id, phase == .playing, player.currentItem != nil else { return }
        let local = player.currentTime().seconds.isFinite ? player.currentTime().seconds : currentTime
        let targetSeconds = TimeInterval(directive.positionMillis) / 1000
        var appliedDelta: Int64?
        if directive.forceSeek || abs(local - targetSeconds) > 3 {
            seek(to: targetSeconds)
            appliedDelta = Int64((targetSeconds - local) * 1000)
        }
        if abs(directive.playbackRate - playbackRate) > 0.001 { setPlaybackRate(directive.playbackRate) }
        if directive.paused {
            if player.timeControlStatus != .paused { player.pause() }
        } else if player.timeControlStatus == .paused {
            player.play()
        }
        if let appliedDelta, !directive.forceSeek {
            core?.watchTogether.notifyCorrectionApplied(deltaMillis: appliedDelta)
        }
    }

    /// 每秒上报一次本地播放状态; 媒体加载前上报 "加载中", 让房间成员能同时打开这一集.
    private func reportWatching(to watchTogether: AniWatchTogether) {
        guard session != nil else { return }
        let loaded = phase == .playing && player.currentItem != nil
        let position = loaded && player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0
        watchTogether.reportWatching(
            subjectId: target.subject.id,
            episodeId: target.episode.id,
            subjectName: target.subject.displayName,
            episodeSort: target.episode.sort,
            episodeName: target.episode.displayName,
            positionMillis: Int64(position * 1000),
            durationMillis: loaded ? Int64(duration * 1000) : 0,
            paused: !loaded || player.timeControlStatus == .paused,
            buffering: loaded && player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
            playbackRate: playbackRate,
        )
    }

    private func sampleNetworkSpeed() {
        guard let events = player.currentItem?.accessLog()?.events else {
            networkSpeed = 0
            return
        }
        let total = events.reduce(Int64(0)) { $0 + max(0, $1.numberOfBytesTransferred) }
        networkSpeed = lastTransferredBytes > 0 ? Double(max(0, total - lastTransferredBytes)) : 0
        lastTransferredBytes = total
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
