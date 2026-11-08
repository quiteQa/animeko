import AniCore
import Foundation

// AniCore (Kotlin facade) 到 Swift 并发模型的适配.
// Kotlin `suspend` 已由 Kotlin/Native 导出为 `async throws`; 这里只把 `observe*` 回调包装为 `AsyncStream`.
// 回调在主线程触发, 订阅随 `AsyncStream` 结束而取消.

extension AniEpisodeSession {
    var candidateUpdates: AsyncStream<[AniMediaCandidate]> {
        AsyncStream { continuation in
            let subscription = observeCandidates(listener: CandidatesListener { continuation.yield($0) })
            continuation.onTermination = { _ in subscription.cancel() }
        }
    }

    var selectionUpdates: AsyncStream<AniMediaCandidate?> {
        AsyncStream { continuation in
            let subscription = observeSelected(listener: SelectionListener { continuation.yield($0) })
            continuation.onTermination = { _ in subscription.cancel() }
        }
    }

    var fetchProgressUpdates: AsyncStream<AniFetchProgress> {
        AsyncStream { continuation in
            let subscription = observeFetchProgress(listener: FetchProgressListener { continuation.yield($0) })
            continuation.onTermination = { _ in subscription.cancel() }
        }
    }
}

private final class CandidatesListener: NSObject, AniCandidatesListener {
    private let block: ([AniMediaCandidate]) -> Void
    init(_ block: @escaping ([AniMediaCandidate]) -> Void) { self.block = block }
    func onCandidates(candidates: [AniMediaCandidate]) { block(candidates) }
}

private final class SelectionListener: NSObject, AniSelectionListener {
    private let block: (AniMediaCandidate?) -> Void
    init(_ block: @escaping (AniMediaCandidate?) -> Void) { self.block = block }
    func onSelected(candidate: AniMediaCandidate?) { block(candidate) }
}

private final class FetchProgressListener: NSObject, AniFetchProgressListener {
    private let block: (AniFetchProgress) -> Void
    init(_ block: @escaping (AniFetchProgress) -> Void) { self.block = block }
    func onProgress(progress: AniFetchProgress) { block(progress) }
}

extension Error {
    /// 解析失败的原因码 (`AniPlaybackException.reason`), 其他错误为 `nil`.
    var aniPlaybackReason: String? {
        let kotlinException = (self as NSError).userInfo["KotlinException"]
        return (kotlinException as? AniPlaybackException)?.reason
    }
}
