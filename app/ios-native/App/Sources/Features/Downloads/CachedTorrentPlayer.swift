import AniCore
import SwiftUI

/// 缓存播放使用持久化的磁力标识与本机验证分片, 不依赖重新搜索或下载种子文件.
@MainActor @Observable
final class CachedTorrentPlayback: Identifiable {
    let id = UUID()
    let entry: NativeTorrentManager.Entry
    let player = MPVPlayer()
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var paused = true
    private(set) var ready = false
    private(set) var pictureInPictureAvailable = false
    var error: String?
    private var lease: TorrentPlaybackLease?
    private var loading: Task<Void, Never>?
    private weak var services: AppServices?
    private var visible = false
    private var closed = false
    private var lastSaved = 0.0
    private var session: AniEpisodeSession?
    private var writer: CoalescingProgressWriter<Snapshot>?
    private struct Snapshot { let position: Int64; let duration: Int64; let playing: Bool }
    init(entry: NativeTorrentManager.Entry) { self.entry = entry }

    func appear(services: AppServices) {
        visible = true; self.services = services
        if services.backgroundCachePlayback !== self { services.backgroundCachePlayback?.stop() }
        services.backgroundPlayback?.stop()
        guard loading == nil, !closed else { return }
        let session = services.core.openEpisode(subjectId: entry.record.subjectID, episodeId: entry.record.episodeID)
        self.session = session
        writer = CoalescingProgressWriter { snapshot in
            try? await session.reportPlayback(positionMillis: snapshot.position, durationMillis: snapshot.duration, isPlaying: snapshot.playing)
        }
        player.onChange = { [weak self] in
            guard let self else { return }
            if abs(position - player.position) >= 0.25 { position = player.position }
            if duration != player.duration { duration = player.duration }
            if paused != player.isPaused { paused = player.isPaused }
            if ready != player.hasMedia { ready = player.hasMedia }
            let available = player.canStartPictureInPicture
            if pictureInPictureAvailable != available { pictureInPictureAvailable = available }
            if abs(position - lastSaved) >= 5 { saveProgress() }
        }
        player.onLoadFailed = { [weak self] in self?.error = $0 }
        player.onPictureInPictureFailure = { [weak self] in self?.error = $0 }
        player.onPictureInPictureChanged = { [weak self] active in
            guard let self else { return }
            if active { self.services?.backgroundCachePlayback = self }
            else { self.services?.backgroundCachePlayback = nil; if !visible { stop() } }
        }
        player.onRestorePictureInPicture = { [weak self] in
            guard let self, let services = self.services else { return false }
            if !visible { services.cachedPlayback = self }
            for _ in 0..<30 {
                if visible && player.videoView.window != nil { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return false
        }
        loading = Task {
            do {
                let lease = try await NativeTorrentManager.shared.openSaved(entry.id)
                guard !Task.isCancelled, !closed else { lease.release(); return }
                self.lease = lease
                let start = Double((try? await session.resumePositionMillis()) ?? 0) / 1000
                guard !Task.isCancelled, !closed else { lease.release(); return }
                player.load(url: lease.url.absoluteString, headers: [:], start: start, autoplay: true)
            } catch { if !Task.isCancelled && !closed { self.error = "缓存暂时无法播放，请继续下载后重试" } }
        }
    }
    private func saveProgress() {
        guard duration > 0, position.isFinite, duration.isFinite, let session else { return }
        lastSaved = position
        let snapshot = Snapshot(position: Int64(max(0, min(duration, position)) * 1000), duration: Int64(duration * 1000), playing: !paused)
        session.notePlayback(positionMillis: snapshot.position, durationMillis: snapshot.duration, isPlaying: snapshot.playing)
        writer?.submit(snapshot)
    }
    func disappear() {
        visible = false
        if !player.retainsPlayback { stop() }
    }
    func stop() {
        guard !closed else { return }; closed = true
        loading?.cancel(); saveProgress(); player.stop()
        let lease = lease; self.lease = nil
        let session = session; self.session = nil
        let writer = writer; self.writer = nil
        if services?.backgroundCachePlayback === self { services?.backgroundCachePlayback = nil }
        Task {
            await loading?.value
            await player.flushCommands(); lease?.release()
            await writer?.flush(); session?.close(); player.destroy()
        }
    }
}

struct CachedTorrentPlayer: View {
    let model: CachedTorrentPlayback
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var scrubbing: Double?
    var body: some View {
        VStack(spacing: 20) {
            PlayerSurface(player: model.player).aspectRatio(16 / 9, contentMode: .fit)
            Text(model.entry.record.title).font(.headline).lineLimit(2).padding(.horizontal)
            if let error = model.error { Text(error).foregroundStyle(.red).padding(.horizontal) }
            if !model.ready, model.error == nil { ProgressView("正在读取本机分片…") }
            HStack {
                Text(TimeText.format(scrubbing ?? model.position))
                Slider(value: Binding(get: { scrubbing ?? model.position }, set: { scrubbing = $0 }), in: 0...max(1, model.duration), onEditingChanged: { editing in
                    if !editing, let target = scrubbing { model.player.seek(to: target); scrubbing = nil }
                }).disabled(model.duration <= 0)
                Text(TimeText.format(model.duration))
            }.font(.caption.monospacedDigit()).padding(.horizontal)
            HStack(spacing: 36) {
                Button { model.player.seek(to: max(0, model.position - 15)) } label: { Image(systemName: "gobackward.15") }
                Button { model.paused ? model.player.play() : model.player.pause() } label: { Image(systemName: model.paused ? "play.fill" : "pause.fill") }
                Button { model.player.seek(to: min(model.duration, model.position + 15)) } label: { Image(systemName: "goforward.15") }
                if model.pictureInPictureAvailable { Button { model.player.startPictureInPicture() } label: { Image(systemName: "pip.enter") } }
            }.font(.title2)
            Spacer()
        }
        .navigationTitle("本机 BT 缓存").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        .onAppear { model.appear(services: services) }
        .onDisappear { model.disappear() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background && !model.player.pictureInPicture.active { model.player.setVideoEnabled(false) }
            if phase == .active { model.player.setVideoEnabled(true) }
        }
    }
}
