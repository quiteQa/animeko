import Foundation
import Network
import Darwin

protocol MediaByteSource: Sendable {
    var size: Int64 { get }
    var contentType: String { get }
    func read(offset: Int64, count: Int) async throws -> Data
}

struct MediaFileSource: MediaByteSource {
    let url: URL
    let size: Int64
    let contentType: String
    init(_ url: URL) throws {
        self.url = url
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else { throw MediaTransportError.unavailable }
        self.size = size.int64Value
        switch url.pathExtension.lowercased() {
        case "m3u8": contentType = "application/vnd.apple.mpegurl"
        case "ts": contentType = "video/mp2t"
        case "m4s": contentType = "video/iso.segment"
        case "vtt": contentType = "text/vtt"
        case "mkv": contentType = "video/x-matroska"
        default: contentType = "video/mp4"
        }
    }
    func read(offset: Int64, count: Int) async throws -> Data {
        try Task.checkCancellation()
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(offset))
        return try file.read(upToCount: count) ?? Data()
    }
}

enum MediaTransportError: LocalizedError {
    case unavailable, cancelled, timedOut, invalidRequest, failed(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "媒体暂不可用"
        case .cancelled: "媒体操作已取消"
        case .timedOut: "等待媒体数据超时"
        case .invalidRequest: "媒体请求无效"
        case .failed(let message): message
        }
    }
}

/// 每个会话以随机路径授权; listener、路由表与连接集合只在 queue 使用.
/// BT 读和 HLS 生成在请求任务中执行, socket 回调不等待下载或编码.
final class MediaHTTPServer: @unchecked Sendable {
    struct Endpoint: Sendable {
        let token: String
        let port: UInt16
        func url(host: String = "127.0.0.1", path: String = "video") -> URL {
            var components = URLComponents()
            components.scheme = "http"
            components.host = host
            components.port = Int(port)
            components.path = "/\(token)/\(path)"
            return components.url!
        }
    }
    typealias Provider = @Sendable (String) async throws -> any MediaByteSource
    static let shared = MediaHTTPServer()
    private let queue = DispatchQueue(label: "ani.media.http", qos: .userInitiated)
    private var listener: NWListener?
    private var port: UInt16?
    private var startTimeout: DispatchWorkItem?
    private var waiters: [CheckedContinuation<UInt16, Error>] = []
    private var providers: [String: Provider] = [:]
    private var connections: [UUID: Connection] = [:]

    private final class Connection: @unchecked Sendable {
        let id = UUID()
        let socket: NWConnection
        var token: String?
        var task: Task<Void, Never>?
        var headerTimeout: DispatchWorkItem?
        init(_ socket: NWConnection) { self.socket = socket }
    }

    func register(_ provider: @escaping Provider) async throws -> Endpoint {
        let port = try await start()
        return await withCheckedContinuation { continuation in
            queue.async {
                let token = UUID().uuidString
                self.providers[token] = provider
                continuation.resume(returning: Endpoint(token: token, port: port))
            }
        }
    }

    func remove(_ endpoint: Endpoint) {
        queue.async {
            self.providers.removeValue(forKey: endpoint.token)
            for connection in self.connections.values where connection.token == endpoint.token {
                connection.task?.cancel()
                connection.socket.cancel()
            }
        }
    }

    private func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let port = self.port { continuation.resume(returning: port); return }
                self.waiters.append(continuation)
                guard self.listener == nil else { return }
                do {
                    let listener = try NWListener(using: .tcp, on: .any)
                    self.listener = listener
                    listener.newConnectionHandler = { [weak self] in self?.accept($0) }
                    listener.stateUpdateHandler = { [weak self, weak listener] state in
                        guard let self, self.listener === listener else { return }
                        switch state {
                        case .ready:
                            guard let port = listener?.port?.rawValue else { return }
                            self.startTimeout?.cancel(); self.startTimeout = nil
                            self.port = port
                            let waiters = self.waiters; self.waiters.removeAll()
                            waiters.forEach { $0.resume(returning: port) }
                        case .failed(let error):
                            let waiters = self.waiters; self.waiters.removeAll()
                            waiters.forEach { $0.resume(throwing: error) }
                            self.listener?.cancel(); self.listener = nil; self.port = nil
                        default: break
                        }
                    }
                    let timeout = DispatchWorkItem { [weak self, weak listener] in
                        guard let self, self.port == nil, self.listener === listener else { return }
                        self.listener = nil; listener?.cancel()
                        let waiters = self.waiters; self.waiters.removeAll()
                        waiters.forEach { $0.resume(throwing: MediaTransportError.timedOut) }
                    }
                    self.startTimeout = timeout
                    self.queue.asyncAfter(deadline: .now() + 10, execute: timeout)
                    listener.start(queue: self.queue)
                } catch {
                    let waiters = self.waiters; self.waiters.removeAll()
                    waiters.forEach { $0.resume(throwing: error) }
                }
            }
        }
    }

    private func accept(_ socket: NWConnection) {
        guard connections.count < 12 else { socket.cancel(); return }
        let connection = Connection(socket)
        connections[connection.id] = connection
        socket.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .failed = state { self.finish(connection) }
            if case .cancelled = state { self.finish(connection) }
        }
        let timeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.finish(connection)
        }
        connection.headerTimeout = timeout
        queue.asyncAfter(deadline: .now() + 10, execute: timeout)
        socket.start(queue: queue)
        receiveHeader(connection, accumulated: Data())
    }

    private func finish(_ connection: Connection) {
        connection.headerTimeout?.cancel()
        connection.task?.cancel()
        connection.socket.cancel()
        connections.removeValue(forKey: connection.id)
    }

    private func receiveHeader(_ connection: Connection, accumulated: Data) {
        connection.socket.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            guard buffer.count <= 16_384, error == nil else { self.finish(connection); return }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete { self.finish(connection) } else { self.receiveHeader(connection, accumulated: buffer) }
                return
            }
            connection.headerTimeout?.cancel()
            guard let text = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { self.finish(connection); return }
            let lines = text.components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ")
            guard first.count == 3, first[2].hasPrefix("HTTP/1."), first[1].hasPrefix("/"),
                  let components = URLComponents(string: String(first[1])),
                  !components.path.contains("\0") else { self.finish(connection); return }
            let path = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard let token = path.first, let provider = self.providers[token], !path.contains("..") else {
                connection.task = Task { try? await self.sendStatus(404, socket: connection.socket); connection.socket.cancel() }
                return
            }
            connection.token = token
            let method = String(first[0])
            var range: String?
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { self.finish(connection); return }
                if line[..<colon].lowercased() == "range" {
                    guard range == nil else { self.finish(connection); return }
                    range = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                }
            }
            let requestRange = range
            let remainder = path.dropFirst().joined(separator: "/")
            connection.task = Task {
                defer { self.queue.async { self.finish(connection) } }
                var sentHeader = false
                do {
                    guard method == "GET" || method == "HEAD" else { try await self.sendStatus(405, socket: connection.socket); return }
                    let source = try await provider(remainder)
                    let selection: HTTPByteRange
                    do { selection = try HTTPByteRange.resolve(requestRange, size: source.size) }
                    catch { try await self.sendStatus(416, headers: "Content-Range: bytes */\(source.size)\r\n", socket: connection.socket); return }
                    var header = "HTTP/1.1 \(selection.partial ? "206 Partial Content" : "200 OK")\r\n"
                    header += "Content-Type: \(source.contentType)\r\nContent-Length: \(selection.count)\r\nAccept-Ranges: bytes\r\n"
                    if selection.partial { header += "Content-Range: \(selection.contentRange)\r\n" }
                    header += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
                    try await self.send(Data(header.utf8), socket: connection.socket)
                    sentHeader = true
                    if method == "HEAD" { return }
                    var offset = selection.offset
                    var remaining = selection.count
                    while remaining > 0 {
                        try Task.checkCancellation()
                        let chunk = try await source.read(offset: offset, count: Int(min(65_536, remaining)))
                        guard !chunk.isEmpty, chunk.count <= remaining else { throw MediaTransportError.unavailable }
                        try await self.send(chunk, socket: connection.socket)
                        remaining -= Int64(chunk.count); offset += Int64(chunk.count)
                    }
                } catch is CancellationError {} catch {
                    if !sentHeader { try? await self.sendStatus(503, headers: "Retry-After: 1\r\n", socket: connection.socket) }
                }
            }
        }
    }

    private func sendStatus(_ status: Int, headers: String = "", socket: NWConnection) async throws {
        try await send(Data("HTTP/1.1 \(status) Error\r\n\(headers)Content-Length: 0\r\nConnection: close\r\n\r\n".utf8), socket: socket)
    }
    private func send(_ data: Data, socket: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            socket.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    static func localAddress() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var current = interfaces
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: item.pointee.ifa_name).hasPrefix("en") else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: buffer)
            }
        }
        return nil
    }
}
