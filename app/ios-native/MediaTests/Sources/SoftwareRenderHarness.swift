import Foundation
import Libmpv

/// 测试宿主持有 C 符号; 测试 bundle 通过宿主调用, 避免重复链接静态 mpv.
@MainActor
final class SoftwareRenderHarness {
    let state: VideoFrameState
    private var handle: OpaquePointer?
    private let output: MPVSampleBufferOutput
    init(generation: UUID, epoch: UUID, receive: @escaping @MainActor (VideoFrame) -> Void, failure: @escaping @MainActor (String) -> Void) throws {
        let state = VideoFrameState(); self.state = state
        guard let handle = mpv_create() else { throw MediaTransportError.unavailable }
        self.handle = handle
        for (key, value) in [("vo", "libmpv"), ("ao", "null"), ("hwdec", "no"), ("keep-open", "yes")] {
            guard mpv_set_option_string(handle, key, value) >= 0 else { mpv_terminate_destroy(handle); self.handle = nil; throw MediaTransportError.unavailable }
        }
        guard mpv_initialize(handle) >= 0 else { mpv_terminate_destroy(handle); self.handle = nil; throw MediaTransportError.unavailable }
        state.update { $0.generation = generation; $0.epoch = epoch; $0.metadataReady = true; $0.width = 640; $0.height = 360; $0.color = FrameProbeColor(primaries: "bt.709", transfer: "bt.709", dolbyVisionProfile: nil) }
        output = MPVSampleBufferOutput(state: state, receive: receive, failure: { message in Task { @MainActor in failure(message) } })
    }
    func open(_ url: URL) async throws {
        guard let handle else { throw MediaTransportError.unavailable }
        let error: String? = await withCheckedContinuation { continuation in output.initialize(handle: handle) { continuation.resume(returning: $0) } }
        if let error { throw MediaTransportError.failed(error) }
        let command = "loadfile \"\(url.path)\" replace"
        guard command.withCString({ mpv_command_string(handle, $0) }) >= 0 else { throw MediaTransportError.unavailable }
    }
    func requestFrame() { output.requestFrame(force: true) }
    func close() async {
        state.update { $0.metadataReady = false }
        await withCheckedContinuation { continuation in output.close { continuation.resume() } }
        if let handle { mpv_terminate_destroy(handle) }; handle = nil
    }
}
