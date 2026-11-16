import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@main
struct FrameLabApp: App {
    var body: some Scene {
        WindowGroup { FrameLabScreen() }
    }
}

@MainActor
@Observable
final class FrameLabModel {
    let presenter = ProbePictureInPicture()
    var status = "选择本地 SDR 视频样本"
    var frameCount = 0
    var position: Double = 0
    var duration: Double = 0
    var paused = true
    private var engine: FrameProbeEngine?
    private var generation = UUID()
    private var sourceURL: URL?
    private var sourceAccess = false
    private var outputFailure = false

    init() {
        presenter.setPlaying = { [weak self] playing in self?.pause(!playing) }
        presenter.skip = { [weak self] offset in
            guard let self else { return }
            engine?.seek(to: position + offset)
        }
        presenter.onFailure = { [weak self] message in self?.status = message }
    }

    func open(_ url: URL) async {
        generation = UUID()
        let generation = generation
        await releaseSession()
        guard self.generation == generation else { return }
        presenter.generation = generation
        sourceURL = url
        sourceAccess = url.startAccessingSecurityScopedResource()
        frameCount = 0
        outputFailure = false
        status = "初始化 mpv 帧输出"
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            status = "无法启动音频会话"
            await releaseSession()
            return
        }
        let engine = FrameProbeEngine(receive: { [weak self] token, event in
            guard let self, self.generation == token else { return }
            switch event {
            case .metadata(let color):
                guard !outputFailure else { return }
                switch color.verdict {
                case .sdr: if frameCount == 0 { status = "SDR 元数据已确认, 等待视频帧" }
                case .blocked(let reason): status = reason
                }
            case .position(let position, let duration, let paused):
                self.position = position
                self.duration = duration
                self.paused = paused
                presenter.paused = paused
                presenter.controller?.invalidatePlaybackState()
            case .failed(let message): outputFailure = true; status = message
            }
        }, frames: { [weak self] frame in
            guard let self, self.generation == frame.generation, !outputFailure else { return }
            if frameCount == 0 { status = "SDR 帧输出中" }
            frameCount += 1
            presenter.enqueue(frame)
        })
        self.engine = engine
        engine.open(url, generation: generation)
    }

    func pause(_ paused: Bool) { engine?.pause(paused) }

    func openSample(_ name: String) async {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp4") else {
            status = "内置样本不可用"
            return
        }
        await open(url)
    }

    func close() async {
        generation = UUID()
        await releaseSession()
    }

    private func releaseSession() async {
        presenter.reset()
        let engine = engine
        let sourceURL = sourceURL
        let sourceAccess = sourceAccess
        self.engine = nil
        self.sourceURL = nil
        self.sourceAccess = false
        paused = true
        if let engine {
            await withCheckedContinuation { continuation in engine.close { continuation.resume() } }
        }
        if sourceAccess, let sourceURL { sourceURL.stopAccessingSecurityScopedResource() }
    }
}

private struct FrameLabScreen: View {
    @State private var model = FrameLabModel()
    @State private var importing = false
    var body: some View {
        VStack(spacing: 20) {
            Text("mpv 帧输出实验").font(.title2)
            Text("仅验证 SDR。HDR 与 Dolby Vision 会被拦截；本实验不代表全格式首版已完成。")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button("内置 SDR 样本") { Task { await model.openSample("pip-sdr") } }
                Button("验证 HDR 拦截") { Task { await model.openSample("test-hdr10") } }
            }.buttonStyle(.bordered)
            ProbeSurface(view: model.presenter.view).aspectRatio(16 / 9, contentMode: .fit)
            Text(model.status).font(.callout).accessibilityIdentifier("probe-status")
            Text("已接收 \(model.frameCount) 帧 · \(Int(model.position)) / \(Int(model.duration)) 秒")
                .monospacedDigit().accessibilityIdentifier("probe-frame-count")
            HStack {
                Button("打开样本") { importing = true }
                Button(model.paused ? "播放" : "暂停") { model.pause(!model.paused) }
                Button("画中画") { model.presenter.start() }
                    .disabled(model.frameCount == 0)
                Button("停止") { Task { await model.close() } }
            }.buttonStyle(.bordered)
        }
        .padding()
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .data]) { result in
            if case .success(let url) = result { Task { await model.open(url) } }
        }
        .onDisappear { Task { await model.close() } }
    }
}

private struct ProbeSurface: UIViewRepresentable {
    let view: ProbeSampleBufferView
    func makeUIView(context: Context) -> ProbeSampleBufferView { view }
    func updateUIView(_ uiView: ProbeSampleBufferView, context: Context) {}
}
