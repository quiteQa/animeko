import AniCore
import AVFoundation
import Foundation

/// 播放页状态. Swift 持有 `AVPlayer`; Kotlin 会话只负责查询, 选择, 解析, 进度记录与标记看过.
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

    let target: PlaybackTarget
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

    @ObservationIgnored private var session: AniEpisodeSession?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var resolveTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var rateObservation: NSKeyValueObservation?
    @ObservationIgnored private var lastReportedAt: TimeInterval = 0
    /// 最近一次进度上报. 上报按顺序执行, 关闭会话前等待它完成.
    @ObservationIgnored private var pendingReport: Task<Void, Never>?

    /// 播放中上报进度的间隔 (秒)
    private static let reportInterval: TimeInterval = 5

    init(target: PlaybackTarget) {
        self.target = target
    }

    func start(core: AniCore) {
        guard session == nil else { return }
        let session = core.openEpisode(subjectId: target.subject.id, episodeId: target.episode.id)
        self.session = session
        observePlayer()

        tasks.append(Task { [weak self] in
            for await list in session.candidateUpdates(preferredOnly: false) { self?.candidates = list }
        })
        tasks.append(Task { [weak self] in
            for await list in session.candidateUpdates(preferredOnly: true) { self?.preferredCandidates = list }
        })
        tasks.append(Task { [weak self] in
            for await progress in session.fetchProgressUpdates { self?.progress = progress }
        })
        tasks.append(Task { [weak self] in
            for await sources in session.sourceUpdates { self?.sources = sources }
        })
        tasks.append(Task { [weak self] in
            for await preferences in session.preferenceUpdates { self?.preferences = preferences }
        })
        tasks.append(Task { [weak self] in
            for await candidate in session.selectionUpdates {
                guard let self else { return }
                let changed = candidate?.mediaId != selected?.mediaId
                selected = candidate
                if changed, candidate != nil { play(session: session) }
            }
        })
        tasks.append(Task { [weak self] in
            do {
                let chosen = try await session.autoSelect()
                if chosen == nil, self?.selected == nil { self?.phase = .noSource }
            } catch {
                if self?.selected == nil { self?.phase = .failed(error.localizedDescription) }
            }
        })
        tasks.append(Task { [weak self] in
            // 弹幕失败不影响播放
            if let list = try? await session.fetchDanmaku() { self?.danmaku = list }
        })
    }

    func select(_ candidate: AniMediaCandidate) {
        guard let session else { return }
        Task { _ = try? await session.select(mediaId: candidate.mediaId) }
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

    func stop() {
        reportProgress(force: true)
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        resolveTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        rateObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        // 最后一次进度上报在关闭会话前完成
        let session = self.session
        let pending = pendingReport
        self.session = nil
        Task {
            await pending?.value
            session?.close()
        }
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
                player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
                if resumeAt > 0 { await player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600)) }
                player.play()
                phase = .playing
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

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main,
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                currentTime = time.seconds.isFinite ? time.seconds : 0
                let itemDuration = player.currentItem?.duration.seconds ?? 0
                duration = itemDuration.isFinite ? itemDuration : 0
                if isPlaying { reportProgress() }
            }
        }
        rateObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in
                guard let self else { return }
                let paused = isPlaying && !playing
                isPlaying = playing
                if paused { reportProgress(force: true) }
            }
        }
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
