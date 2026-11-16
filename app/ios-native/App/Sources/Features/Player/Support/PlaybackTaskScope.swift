import Foundation

/// 一代异步工作的所有权. invalidate 同步禁止结果发布, 并取消这一代的全部任务.
@MainActor
final class PlaybackTaskScope {
    struct Token: Equatable, Sendable {
        fileprivate let id = UUID()
    }

    private(set) var token = Token()
    private var isClosed = false
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func accepts(_ token: Token) -> Bool {
        !isClosed && self.token == token && !Task.isCancelled
    }

    func run(_ operation: @escaping @MainActor (Token) async -> Void) {
        guard !isClosed else { return }
        let id = UUID()
        let token = token
        tasks[id] = Task { [weak self] in
            guard self?.accepts(token) == true else { return }
            await operation(token)
            self?.tasks.removeValue(forKey: id)
        }
    }

    /// 返回的任务可在解除 Kotlin 会话所有权前等待完成.
    @discardableResult
    func invalidate() -> [Task<Void, Never>] {
        token = Token()
        let previous = Array(tasks.values)
        tasks.removeAll()
        previous.forEach { $0.cancel() }
        return previous
    }
    /// 永久关闭此工作域; 关闭后的新任务也不能启动.
    @discardableResult
    func close() -> [Task<Void, Never>] {
        isClosed = true
        return invalidate()
    }

}
