import AVFoundation
import AVKit
import CoreMedia
import UIKit

final class ProbeSampleBufferView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

/// 使用系统采样缓冲画中画; 解码与播放时钟由 mpv 驱动.
@MainActor
final class ProbePictureInPicture: NSObject {
    let view = ProbeSampleBufferView()
    var generation = UUID()
    var paused = true { didSet { systemDelegate?.updatePaused(paused) } }
    var setPlaying: ((Bool) -> Void)?
    var skip: ((Double) -> Void)?
    var onFailure: ((String) -> Void)?
    private(set) var controller: AVPictureInPictureController?
    private var format: CMVideoFormatDescription?
    private var systemDelegate: ProbeSystemDelegate?

    override init() {
        super.init()
        view.backgroundColor = .black
        view.displayLayer.videoGravity = .resizeAspect
        var timebase: CMTimebase?
        if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase) == noErr,
           let timebase {
            CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(timebase, rate: 1)
            view.displayLayer.controlTimebase = timebase
        }
        let delegate = ProbeSystemDelegate(
            onPlaying: { [weak self] in self?.setPlaying?($0) },
            onSkip: { [weak self] in self?.skip?($0) },
            onFailure: { [weak self] in self?.onFailure?($0) },
            restoreUI: { [weak self] in self?.view.window != nil }
        )
        systemDelegate = delegate
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: view.displayLayer, playbackDelegate: delegate)
            controller = AVPictureInPictureController(contentSource: source)
            controller?.delegate = delegate
            controller?.canStartPictureInPictureAutomaticallyFromInline = false
        }
    }

    var possible: Bool { controller?.isPictureInPicturePossible == true }

    func enqueue(_ frame: ProbeFrame) {
        guard frame.generation == generation else { return }
        let layer = view.displayLayer
        if layer.status == .failed { layer.flush() }
        guard layer.isReadyForMoreMediaData else { return }
        if format == nil {
            let status = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame.buffer, formatDescriptionOut: &format)
            guard status == noErr else { onFailure?("创建视频格式失败 (\(status))"); return }
        }
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: frame.hostTime, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: frame.buffer, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { onFailure?("创建视频采样失败 (\(status))"); return }
        layer.enqueue(sample)
    }

    func start() {
        guard possible else { onFailure?("系统画中画尚不可用, 请先播放一段 SDR 样本"); return }
        controller?.startPictureInPicture()
    }

    func reset() {
        generation = UUID()
        controller?.stopPictureInPicture()
        view.displayLayer.flushAndRemoveImage()
        format = nil
    }

}

/// 系统代理允许来自任意线程的查询; 状态使用锁, 界面操作显式转交主线程.
final class ProbeSystemDelegate: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var paused = true
    private let onPlaying: @MainActor (Bool) -> Void
    private let onSkip: @MainActor (Double) -> Void
    private let onFailure: @MainActor (String) -> Void
    private let restoreUI: @MainActor () -> Bool

    init(onPlaying: @escaping @MainActor (Bool) -> Void, onSkip: @escaping @MainActor (Double) -> Void,
         onFailure: @escaping @MainActor (String) -> Void, restoreUI: @escaping @MainActor () -> Bool) {
        self.onPlaying = onPlaying
        self.onSkip = onSkip
        self.onFailure = onFailure
        self.restoreUI = restoreUI
    }

    func updatePaused(_ value: Bool) { lock.lock(); paused = value; lock.unlock() }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor in onPlaying(playing) }
    }
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        lock.lock(); defer { lock.unlock() }; return paused
    }
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // 帧输出实验以 host-clock 驱动显示, 不宣称已具备 VOD 时间轴映射.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping @Sendable () -> Void) {
        let seconds = skipInterval.seconds
        Task { @MainActor in
            if seconds.isFinite { onSkip(seconds) }
            completionHandler()
        }
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in onFailure("系统画中画启动失败: \(message)") }
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping @Sendable (Bool) -> Void) {
        Task { @MainActor in completionHandler(restoreUI()) }
    }
}
