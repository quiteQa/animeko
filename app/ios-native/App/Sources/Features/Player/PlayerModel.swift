import AniCore
import AVFoundation
import Foundation

/// 播放页状态. Swift 持有 `AVPlayer`; Kotlin 会话只负责查询, 选择和解析可播放地址.
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
    private(set) var candidates: [AniMediaCandidate] = []
    private(set) var selected: AniMediaCandidate?
    private(set) var progress: AniFetchProgress?
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

    init(target: PlaybackTarget) {
        self.target = target
    }

    func start(core: AniCore) {
        guard session == nil else { return }
        let session = core.openEpisode(subjectId: target.subject.id, episodeId: target.episode.id)
        self.session = session
        observePlayer()

        tasks.append(Task { [weak self] in
            for await list in session.candidateUpdates { self?.candidates = list }
        })
        tasks.append(Task { [weak self] in
            for await progress in session.fetchProgressUpdates { self?.progress = progress }
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
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        resolveTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        rateObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        session?.close()
        session = nil
    }

    private func play(session: AniEpisodeSession) {
        resolveTask?.cancel()
        phase = .resolving
        let resumeAt = player.currentItem == nil ? 0 : currentTime
        resolveTask = Task { [weak self] in
            do {
                let playable = try await session.resolveSelected()
                guard let self, !Task.isCancelled else { return }
                let asset = AVURLAsset(
                    url: URL(string: playable.url)!,
                    options: ["AVURLAssetHTTPHeaderFieldsKey": playable.headers],
                )
                let item = AVPlayerItem(asset: asset)
                player.replaceCurrentItem(with: item)
                if resumeAt > 0 { await player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600)) }
                player.play()
                phase = .playing
            } catch {
                guard let self, !Task.isCancelled else { return }
                phase = .failed(Self.describe(error))
            }
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
            }
        }
        rateObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.isPlaying = playing }
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
