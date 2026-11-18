import AVFoundation
import AVKit
import Foundation
import MediaPlayer
import Observation
import SwiftUI

/// AVPlayer 仅作为系统视频 AirPlay 传输器; 本地播放与画中画均由 mpv 提供.
@MainActor @Observable
final class AirPlaySession {
    enum State: Equatable { case idle, preparing, ready, connected, failed(String) }
    private(set) var state: State = .idle
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    var isConnected: Bool { state == .connected }
    var onConnection: ((Bool, Double) -> Void)?
    var onProgress: ((Double, Bool) -> Void)?
    let player = AVPlayer()
    @ObservationIgnored private var activeObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var periodic: Any?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var output: AirPlayHLSWriter?
    @ObservationIgnored private var encoding: Task<Void, Never>?
    @ObservationIgnored private var endpoint: MediaHTTPServer.Endpoint?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var source: (url: String, headers: [String: String], info: MediaInspection, compatible1080: Bool)?
    @ObservationIgnored private var commands: [(MPRemoteCommand, Any)] = []
    private var desiredRate: Float = 1
    private var changingItem = false

    init() {
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        player.isMuted = true
        activeObservation = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] player, _ in
            let active = player.isExternalPlaybackActive
            Task { @MainActor in self?.externalChanged(active) }
        }
        periodic = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }
    deinit { if let periodic { player.removeTimeObserver(periodic) } }

    func prepare(url: String, headers: [String: String], start: Double, compatible1080: Bool) async {
        guard state != .preparing else { return }
        stop(notify: false)
        state = .preparing; position = max(0, start)
        let expected = UUID(); generation = expected
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let info = try await MediaInspection.inspect(url: url, headers: headers)
                try Task.checkCancellation()
                guard generation == expected else { return }
                guard !info.isHDR else { throw MediaTransportError.failed("HDR / Dolby Vision 全保真投送不在此次实现范围内") }
                source = (url, headers, info, compatible1080); duration = info.duration
                try await startPipeline(at: start, expected: expected)
            } catch {
                guard !Task.isCancelled, generation == expected else { return }
                releasePipeline(); state = .failed((error as? MediaTransportError)?.errorDescription ?? "视频投送准备失败，请检查局域网和媒体格式")
            }
        }
        await task?.value
    }
    private func startPipeline(at start: Double, expected: UUID) async throws {
        guard let source, let host = MediaHTTPServer.localAddress() else { throw MediaTransportError.failed("请先连接与接收器相同的 Wi-Fi 局域网") }
        let writer = try AirPlayHLSWriter(url: source.url, headers: source.headers, info: source.info,
            start: start, compatible1080: source.compatible1080)
        output = writer
        encoding = Task { await writer.run() }
        let endpoint = try await MediaHTTPServer.shared.register { path in try await writer.resource(path) }
        guard generation == expected, !Task.isCancelled else { MediaHTTPServer.shared.remove(endpoint); throw CancellationError() }
        self.endpoint = endpoint
        try await writer.waitUntilReady()
        try Task.checkCancellation()
        guard generation == expected else { throw CancellationError() }
        let item = AVPlayerItem(url: endpoint.url(host: host, path: "index.m3u8"))
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in
                guard let self, self.generation == expected else { return }
                let connected = self.isConnected
                self.releasePipeline(); self.player.pause(); self.player.replaceCurrentItem(with: nil)
                self.state = .failed("接收器无法播放本机视频，请检查 Wi-Fi、局域网权限或尝试 1080p 兼容模式")
                if connected { self.onConnection?(false, self.position) }
            }
        }
        player.replaceCurrentItem(with: item)
        changingItem = false
        if player.isExternalPlaybackActive { externalChanged(true) }
        else { state = .ready; player.isMuted = true; player.playImmediately(atRate: desiredRate) }
    }
    private func externalChanged(_ active: Bool) {
        guard source != nil else { return }
        if active {
            let wasConnected = isConnected
            state = .connected; player.isMuted = false
            if !wasConnected { player.seek(to: .zero) }
            player.playImmediately(atRate: desiredRate)
            if !wasConnected { installRemoteCommands(); onConnection?(true, position) }
        } else if isConnected && !changingItem {
            let time = position
            stop(notify: false); onConnection?(false, time)
        }
    }
    private func tick(_ relative: Double) {
        guard relative.isFinite, let output else { return }
        output.setPlaybackPosition(relative)
        guard isConnected else { return }
        position = min(duration > 0 ? duration : .greatestFiniteMagnitude, output.sourceStart + max(0, relative))
        isPlaying = player.rate > 0
        onProgress?(position, isPlaying)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: "Animeko", MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPNowPlayingInfoPropertyPlaybackRate: player.rate]
    }
    func togglePlayback() { if player.rate > 0 { player.pause() } else { player.playImmediately(atRate: desiredRate) } }
    func setPlaying(_ value: Bool) { if value { player.playImmediately(atRate: desiredRate) } else { player.pause() } }
    func setRate(_ rate: Float) { desiredRate = rate; if player.rate > 0 { player.playImmediately(atRate: rate) } }
    func seek(to seconds: Double) {
        guard isConnected, seconds.isFinite else { return }
        position = max(0, min(duration, seconds)); changingItem = true
        task?.cancel(); releasePipeline()
        let expected = UUID(); generation = expected
        task = Task {
            do { try await startPipeline(at: position, expected: expected) }
            catch {
                guard !Task.isCancelled, generation == expected else { return }
                stop(notify: false); state = .failed("投送跳转失败，请重新准备投送"); onConnection?(false, position)
            }
        }
    }
    func stop(notify: Bool = true) {
        let connected = isConnected
        generation = UUID(); task?.cancel(); task = nil
        releasePipeline(); player.pause(); player.replaceCurrentItem(with: nil); player.isMuted = true
        source = nil; state = .idle; isPlaying = false; changingItem = false
        for (command, target) in commands { command.removeTarget(target) }; commands.removeAll()
        if connected { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
        if connected && notify { onConnection?(false, position) }
    }
    private func releasePipeline() {
        itemObservation = nil
        if let endpoint { MediaHTTPServer.shared.remove(endpoint) }; endpoint = nil
        if let output {
            output.cancel(); let encoding = encoding
            Task { await encoding?.value; output.cleanup() }
        }
        output = nil; encoding = nil
    }
    private func installRemoteCommands() {
        guard commands.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        commands.append((center.playCommand, center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.setPlaying(true) }; return .success }))
        commands.append((center.pauseCommand, center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.setPlaying(false) }; return .success }))
        center.changePlaybackPositionCommand.isEnabled = duration > 0
        commands.append((center.changePlaybackPositionCommand, center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime; Task { @MainActor in self?.seek(to: seconds) }; return .success
        }))
    }
}

struct AirPlayRouteButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { let view = AVRoutePickerView(); view.prioritizesVideoDevices = true; return view }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
private final class AirPlayTransportView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
struct AirPlayTransportSurface: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> UIView { let view = AirPlayTransportView(); view.playerLayer.player = player; return view }
    func updateUIView(_ view: UIView, context: Context) { (view as? AirPlayTransportView)?.playerLayer.player = player }
}
