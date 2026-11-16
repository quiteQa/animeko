import Foundation

/// 串行保存进度. 最多保留正在写入的一项和最新待写入的一项.
@MainActor
final class CoalescingProgressWriter<Value> {
    private let write: @MainActor (Value) async -> Void
    private var pending: Value?
    private var worker: Task<Void, Never>?

    init(write: @escaping @MainActor (Value) async -> Void) {
        self.write = write
    }

    func submit(_ value: Value) {
        pending = value
        guard worker == nil else { return }
        worker = Task { await drain() }
    }

    func flush() async {
        while let worker { await worker.value }
    }

    private func drain() async {
        while let value = pending {
            pending = nil
            await write(value)
        }
        worker = nil
    }
}
