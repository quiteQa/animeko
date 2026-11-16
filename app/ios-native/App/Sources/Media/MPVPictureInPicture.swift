import AVFoundation
import AVKit
import CoreMedia
import UIKit

final class MPVSampleBufferView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

/// 系统窗口只接收 mpv 输出帧; 媒体时钟与控制始终由同一个 mpv 会话提供.
@MainActor
final class MPVPictureInPicture: NSObject {
    let view = MPVSampleBufferView()
    var generation = UUID()
    var epoch = UUID()
    var setPlaying: ((Bool) -> Void)?
    var skip: ((Double) async -> Void)?
    var restoreUI: (() async -> Bool)?
    var onState: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    var onFirstFrame: (() -> Void)?
    private(set) var active = false
    private(set) var starting = false
    private(set) var controller: AVPictureInPictureController?
    private var format: CMVideoFormatDescription?
    private var timeline = PlaybackTimeline()
    private var delegate: MPVPictureInPictureDelegate!
    private var hasFrame = false
    private var startRequested = false

    override init() {
        super.init()
        view.backgroundColor = .black
        view.displayLayer.videoGravity = .resizeAspect
        var timebase: CMTimebase?
        if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase) == noErr {
            view.displayLayer.controlTimebase = timebase
        }
        delegate = MPVPictureInPictureDelegate(
            onPlaying: { [weak self] in self?.setPlaying?($0) },
            onSkip: { [weak self] in await self?.skip?($0) },
            onState: { [weak self] active in
                guard let self else { return }; self.active = active; starting = false; onState?(active)
            },
            onFailure: { [weak self] message in
                guard let self else { return }; starting = false; startRequested = false; onFailure?(message); onState?(false)
            },
            restore: { [weak self] in await self?.restoreUI?() ?? false })
        if AVPictureInPictureController.isPictureInPictureSupported() {
            controller = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: view.displayLayer, playbackDelegate: delegate))
            controller?.delegate = delegate
            controller?.canStartPictureInPictureAutomaticallyFromInline = false
        }
    }

    func update(position: Double, duration: Double, speed: Double, paused: Bool) {
        let host = CMClockGetTime(CMClockGetHostTimeClock())
        if timeline.update(position: position, duration: duration, speed: speed, paused: paused, hostTime: host.seconds),
           let timebase = view.displayLayer.controlTimebase {
            CMTimebaseSetRateAndAnchorTime(timebase, rate: timeline.rate,
                anchorTime: CMTime(seconds: timeline.mediaAnchor, preferredTimescale: 1_000_000), immediateSourceTime: host)
        }
        delegate.update(paused: paused, duration: timeline.duration)
        controller?.invalidatePlaybackState()
        startIfPossible()
    }
    func enqueue(_ frame: VideoFrame) {
        guard frame.generation == generation, frame.epoch == epoch else { return }
        let layer = view.displayLayer
        if layer.status == .failed { layer.flush(); format = nil }
        guard layer.isReadyForMoreMediaData else { return }
        if let existing = format, !CMVideoFormatDescriptionMatchesImageBuffer(existing, imageBuffer: frame.buffer) { layer.flush(); format = nil }
        if format == nil {
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame.buffer, formatDescriptionOut: &format) == noErr else { return }
        }
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(seconds: timeline.mediaTime(at: frame.hostTime.seconds), preferredTimescale: 1_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame.buffer,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        layer.enqueue(sample)
        if !hasFrame { hasFrame = true; onFirstFrame?() }
        startIfPossible()
    }
    func start() { startRequested = true; starting = true; onState?(true); startIfPossible() }
    private func startIfPossible() {
        guard startRequested, hasFrame, controller?.isPictureInPicturePossible == true else { return }
        startRequested = false; controller?.startPictureInPicture()
    }
    func flush(generation: UUID, epoch: UUID) {
        self.generation = generation; self.epoch = epoch
        view.displayLayer.flushAndRemoveImage(); format = nil; hasFrame = false
    }
    func reset() {
        startRequested = false; starting = false; active = false
        controller?.stopPictureInPicture()
        flush(generation: UUID(), epoch: UUID())
    }
}

final class MPVPictureInPictureDelegate: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var paused = true
    private var duration = 0.0
    private let onPlaying: @MainActor (Bool) -> Void
    private let onSkip: @MainActor (Double) async -> Void
    private let onState: @MainActor (Bool) -> Void
    private let onFailure: @MainActor (String) -> Void
    private let restore: @MainActor () async -> Bool
    init(onPlaying: @escaping @MainActor (Bool) -> Void, onSkip: @escaping @MainActor (Double) async -> Void,
         onState: @escaping @MainActor (Bool) -> Void, onFailure: @escaping @MainActor (String) -> Void,
         restore: @escaping @MainActor () async -> Bool) {
        self.onPlaying = onPlaying; self.onSkip = onSkip; self.onState = onState; self.onFailure = onFailure; self.restore = restore
    }
    func update(paused: Bool, duration: Double) { lock.lock(); self.paused = paused; self.duration = duration; lock.unlock() }
    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) { Task { @MainActor in onPlaying(playing) } }
    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { lock.lock(); defer { lock.unlock() }; return paused }
    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        lock.lock(); defer { lock.unlock() }
        return CMTimeRange(start: .zero, duration: CMTime(seconds: max(0, duration), preferredTimescale: 600))
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval interval: CMTime, completion completionHandler: @escaping @Sendable () -> Void) {
        Task { @MainActor in if interval.seconds.isFinite { await onSkip(interval.seconds) }; completionHandler() }
    }
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) { Task { @MainActor in onState(true) } }
    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) { Task { @MainActor in onState(false) } }
    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in onFailure("系统无法启动画中画，请保持播放后重试") }
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping @Sendable (Bool) -> Void) {
        Task { @MainActor in completionHandler(await restore()) }
    }
}
