import Foundation
import Observation

final class NativeTorrentEngine: @unchecked Sendable {
    let pointer: OpaquePointer
    private init(_ pointer: OpaquePointer) { self.pointer = pointer }
    static func create() async throws -> NativeTorrentEngine {
        try await MediaIO.run {
            var error = [CChar](repeating: 0, count: 256)
            guard let pointer = ANITCreateEngine(&error, error.count) else {
                throw MediaTransportError.failed("BT 引擎启动失败")
            }
            return NativeTorrentEngine(pointer)
        }
    }
    deinit { ANITDestroyEngine(pointer) }
    func add(_ uri: String, headers: [String: String], directory: URL) async throws -> NativeTorrent {
        var metadata: Data?
        if !uri.lowercased().hasPrefix("magnet:") {
            guard let url = URL(string: uri), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
                throw MediaTransportError.invalidRequest
            }
            var request = URLRequest(url: url); request.timeoutInterval = 30
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                  response.expectedContentLength <= 32 * 1024 * 1024 else { throw MediaTransportError.unavailable }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 32 * 1024 * 1024 else { throw MediaTransportError.failed("种子元数据过大") }
                data.append(byte)
            }
            metadata = data
        }
        let bytes = metadata
        return try await MediaIO.run {
            var error = [CChar](repeating: 0, count: 256)
            let result: OpaquePointer?
            if let bytes {
                result = bytes.withUnsafeBytes { raw in
                    ANITAddTorrent(self.pointer, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, directory.path, &error, error.count)
                }
            } else { result = ANITAddMagnet(self.pointer, uri, directory.path, &error, error.count) }
            guard let result else { throw MediaTransportError.failed("无法打开磁力或种子，可能已有同一种子的下载任务") }
            return NativeTorrent(result, engine: self)
        }
    }
}

final class NativeTorrent: @unchecked Sendable {
    struct File: Identifiable, Sendable { let id: Int32; let path: String; let size: Int64 }
    let pointer: OpaquePointer
    private let engine: NativeTorrentEngine
    init(_ pointer: OpaquePointer, engine: NativeTorrentEngine) { self.pointer = pointer; self.engine = engine }
    deinit { ANITCloseTorrent(pointer) }
    func files() async throws -> [File] {
        for _ in 0..<600 {
            try Task.checkCancellation()
            let files: [File]? = try await MediaIO.run {
                let count = ANITFileCount(self.pointer)
                guard count >= 0 else {
                    if ANITGetStatus(self.pointer).failed != 0 { throw MediaTransportError.failed("BT 元数据获取失败") }
                    return nil
                }
                return (0..<count).compactMap { index in
                    var path = [CChar](repeating: 0, count: 4096); var size: Int64 = 0
                    guard ANITFileInfo(self.pointer, index, &path, path.count, &size) == 1 else { return nil }
                    return File(id: index, path: String(cString: path), size: size)
                }
            }
            if let files { return files }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MediaTransportError.timedOut
    }
    func select(_ file: File) async throws {
        let selected = try await MediaIO.run { ANITSelectFile(self.pointer, file.id) }
        guard selected != 0 else { throw MediaTransportError.unavailable }
    }
    var magnetURI: String? {
        var uri = [CChar](repeating: 0, count: 16_384)
        return ANITCopyMagnetURI(pointer, &uri, uri.count) != 0 ? String(cString: uri) : nil
    }
    func pause(_ value: Bool) { ANITSetPaused(pointer, value ? 1 : 0) }
    func save() { ANITSaveResume(pointer) }
    func remove() { ANITRemove(pointer, 1) }

    private final class ReadToken: @unchecked Sendable {
        let pointer = ANITCreateReadToken()!
        func cancel() { ANITCancelRead(pointer) }
        deinit { ANITDestroyReadToken(pointer) }
    }
    func read(file: File, offset: Int64, count: Int) async throws -> Data {
        let token = ReadToken()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await MediaIO.run {
                var bytes = [UInt8](repeating: 0, count: min(65_536, max(1, count)))
                let result = ANITRead(self.pointer, file.id, offset, &bytes, Int32(bytes.count), 30_000, token.pointer)
                switch result {
                case -2: throw CancellationError()
                case -3: throw MediaTransportError.timedOut
                case ..<0: throw MediaTransportError.unavailable
                default: return Data(bytes.prefix(Int(result)))
                }
            }
        } onCancel: { token.cancel() }
    }
}

struct TorrentByteSource: MediaByteSource {
    let torrent: NativeTorrent
    let file: NativeTorrent.File
    var size: Int64 { file.size }
    var contentType: String { file.path.lowercased().hasSuffix(".mkv") ? "video/x-matroska" : "application/octet-stream" }
    func read(offset: Int64, count: Int) async throws -> Data { try await torrent.read(file: file, offset: offset, count: count) }
}

@MainActor
final class TorrentPlaybackLease {
    let url: URL
    let taskID: UUID
    private let endpoint: MediaHTTPServer.Endpoint
    private var releaseAction: (() -> Void)?
    init(endpoint: MediaHTTPServer.Endpoint, taskID: UUID, release: @escaping () -> Void) {
        self.endpoint = endpoint; self.taskID = taskID; releaseAction = release
        url = endpoint.url(path: "stream")
    }
    func release() {
        MediaHTTPServer.shared.remove(endpoint)
        releaseAction?(); releaseAction = nil
    }
}

@MainActor @Observable
final class NativeTorrentManager {
    struct Record: Codable {
        let id: UUID
        let uri: String
        let title: String
        let subjectID: Int32
        let episodeID: Int32
        var fileIndex: Int32?
        var cachedMagnet: String?
        var keepDownloading = false
        var downloadMarked = false
        var paused = false
    }
    @MainActor @Observable
    final class Entry: Identifiable {
        var record: Record
        var id: UUID { record.id }
        var progress: Double = 0
        var speed: Int64 = 0
        var paused = false
        var peers = 0
        var error: String?
        var metadataReady = false
        @ObservationIgnored var torrent: NativeTorrent?
        @ObservationIgnored var opening: Task<NativeTorrent, Error>?
        @ObservationIgnored var readers = 0
        @ObservationIgnored var waiters = 0
        @ObservationIgnored var deleted = false
        init(_ record: Record) { self.record = record; paused = record.paused }
    }
    static let shared = NativeTorrentManager()
    private(set) var entries: [Entry] = []
    @ObservationIgnored private var engine: NativeTorrentEngine?
    @ObservationIgnored private var engineTask: Task<NativeTorrentEngine, Error>?
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var poll: Task<Void, Never>?
    private let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NativeTorrents", isDirectory: true)

    func restore() async {
        guard !restoring else { return }; restoring = true
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: root.appendingPathComponent("downloads.json")),
           let records = try? JSONDecoder().decode([Record].self, from: data) { entries = records.map(Entry.init) }
        for entry in entries where entry.record.keepDownloading {
            Task { do { _ = try await prepare(entry, headers: [:]) } catch { entry.error = "BT 下载恢复失败" } }
        }
        poll = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                guard let self else { return }
                for entry in entries {
                    guard let torrent = entry.torrent else { continue }
                    let status = try? await MediaIO.run { ANITGetStatus(torrent.pointer) }
                    guard let status else { continue }
                    entry.metadataReady = status.metadata_ready != 0
                    entry.paused = status.paused != 0; entry.peers = Int(status.peers)
                    entry.speed = status.download_rate
                    entry.progress = status.wanted > 0 ? min(1, Double(status.completed) / Double(status.wanted)) : 0
                    if status.failed != 0 { entry.error = "BT 任务发生错误，可暂停后重试" }
                    if entry.readers == 0 && entry.waiters == 0 { ANITTrimReadCache(torrent.pointer) }
                    if ticks % 30 == 0 { torrent.save() }
                }
                ticks += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func getEngine() async throws -> NativeTorrentEngine {
        if let engine { return engine }
        if let engineTask { return try await engineTask.value }
        let task = Task { try await NativeTorrentEngine.create() }; engineTask = task
        defer { engineTask = nil }
        let result = try await task.value; engine = result; return result
    }
    private func prepare(_ entry: Entry, headers: [String: String]) async throws -> NativeTorrent {
        if let torrent = entry.torrent { return torrent }
        if let opening = entry.opening { return try await opening.value }
        let task = Task {
            let engine = try await getEngine()
            let torrent = try await engine.add(entry.record.cachedMagnet ?? entry.record.uri, headers: headers,
                directory: root.appendingPathComponent("Content", isDirectory: true))
            do { _ = try await torrent.files(); try Task.checkCancellation() }
            catch { torrent.pause(true); torrent.save(); throw error }
            guard !entry.deleted else { torrent.remove(); throw CancellationError() }
            let files = try await torrent.files()
            if let index = entry.record.fileIndex, let file = files.first(where: { $0.id == index }) { try await torrent.select(file) }
            entry.record.cachedMagnet = torrent.magnetURI
            torrent.save(); persist()
            entry.torrent = torrent
            return torrent
        }
        entry.opening = task
        defer { entry.opening = nil }
        return try await task.value
    }
    private func record(uri: String, title: String, subject: Int32, episode: Int32) -> Entry {
        if let entry = entries.first(where: { $0.record.uri == uri && $0.record.subjectID == subject }) { return entry }
        let entry = Entry(Record(id: UUID(), uri: uri, title: title, subjectID: subject, episodeID: episode))
        entries.append(entry); persist(); return entry
    }
    func open(uri: String, title: String, headers: [String: String], subject: Int32, episode: Int32,
              selectFile: @escaping @MainActor ([String]) async throws -> Int) async throws -> TorrentPlaybackLease {
        if !restoring { await restore() }
        let entry = record(uri: uri, title: title, subject: subject, episode: episode)
        entry.error = nil
        entry.waiters += 1
        defer {
            entry.waiters -= 1
            if entry.waiters == 0 && entry.readers == 0 && !entry.record.keepDownloading { entry.torrent?.pause(true) }
        }
        let torrent = try await withTaskCancellationHandler {
            let result = try await prepare(entry, headers: headers)
            try Task.checkCancellation(); return result
        } onCancel: {
            Task { @MainActor in
                if entry.waiters <= 1 && entry.readers == 0 && !entry.record.keepDownloading { entry.opening?.cancel() }
            }
        }
        let files = try await torrent.files()
        let selected = try await selectFile(files.map(\.path))
        try Task.checkCancellation()
        guard selected >= 0, selected < files.count else { throw MediaTransportError.failed("种子中未找到当前剧集的视频") }
        let file = files[selected]
        try await torrent.select(file)
        torrent.pause(false)
        entry.record.fileIndex = file.id; entry.readers += 1; persist()
        let source = TorrentByteSource(torrent: torrent, file: file)
        do {
            let endpoint = try await MediaHTTPServer.shared.register { _ in source }
            if Task.isCancelled { MediaHTTPServer.shared.remove(endpoint); throw CancellationError() }
            return TorrentPlaybackLease(endpoint: endpoint, taskID: entry.id) { [weak self, weak entry] in
                guard let self, let entry else { return }
                entry.readers = max(0, entry.readers - 1)
                if entry.readers == 0 && !entry.record.keepDownloading { torrent.pause(true) }
                torrent.save(); self.persist()
            }
        } catch { entry.readers -= 1; if entry.readers == 0 && !entry.record.keepDownloading { torrent.pause(true) }; throw error }
    }
    func openSaved(_ id: UUID) async throws -> TorrentPlaybackLease {
        guard let entry = entries.first(where: { $0.id == id }), let index = entry.record.fileIndex else { throw MediaTransportError.unavailable }
        let torrent = try await prepare(entry, headers: [:])
        let files = try await torrent.files()
        guard let file = files.first(where: { $0.id == index }) else { throw MediaTransportError.unavailable }
        return try await open(uri: entry.record.uri, title: entry.record.title, headers: [:],
            subject: entry.record.subjectID, episode: entry.record.episodeID) { paths in paths.firstIndex(of: file.path) ?? -1 }
    }
    func retainDownload(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        entry.record.downloadMarked = true; entry.record.paused = false
        entry.record.keepDownloading = true; entry.torrent?.pause(false); persist()
    }
    func setPaused(_ entry: Entry, _ paused: Bool) {
        entry.record.downloadMarked = true; entry.record.paused = paused
        entry.record.keepDownloading = !paused
        entry.torrent?.pause(paused); entry.paused = paused; persist()
        if !paused { Task { do { _ = try await prepare(entry, headers: [:]) } catch { entry.error = "BT 任务恢复失败" } } }
    }
    func delete(_ entry: Entry) {
        entry.deleted = true
        entry.opening?.cancel(); entry.torrent?.remove()
        entries.removeAll { $0.id == entry.id }; persist()
    }
    private func persist() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries.map(\.record)) {
            try? data.write(to: root.appendingPathComponent("downloads.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}
