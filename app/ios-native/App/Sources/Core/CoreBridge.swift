import AniCore
import Foundation

// AniCore (Kotlin facade) 到 Swift 并发模型的适配.
// Kotlin `suspend` 已由 Kotlin/Native 导出为 `async throws`; 这里只把 `observe*` 回调包装为 `AsyncStream`.
// 回调在主线程触发, 订阅随 `AsyncStream` 结束而取消.

/// 带错误的观察结果. Kotlin 侧上游抛出异常后不再回调.
enum Observed<Value> {
    case value(Value)
    case failure(String)
}

private func stream<Value>(_ subscribe: (@escaping (Value) -> Void) -> AniSubscription) -> AsyncStream<Value> {
    AsyncStream { continuation in
        let subscription = subscribe { continuation.yield($0) }
        continuation.onTermination = { _ in subscription.cancel() }
    }
}

extension AniCore {
    var sessionUpdates: AsyncStream<AniSession> {
        stream { yield in observeSession(listener: SessionListener(yield)) }
    }

    func subjectDetailUpdates(subjectId: Int32) -> AsyncStream<Observed<AniSubjectDetail>> {
        stream { yield in observeSubjectDetail(subjectId: subjectId, listener: SubjectDetailListener(yield)) }
    }

    func collectionUpdates(type: AniCollectionType?, limit: Int32) -> AsyncStream<Observed<[AniCollectionItem]>> {
        stream { yield in observeCollections(type: type, limit: limit, listener: CollectionsListener(yield)) }
    }

    /// 用 Bangumi 授权登录. `openURL` 负责展示授权页; 结束后返回是否成功. 取消所在的 `Task` 即放弃登录.
    /// Kotlin 侧的回调都在主线程触发.
    @MainActor
    func loginWithBangumi(openURL: @escaping @MainActor (URL) -> Void) async -> Result<Void, LoginError> {
        let holder = SubscriptionHolder()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                holder.subscription = startBangumiLogin(listener: LoginListener(
                    openURL: { string in
                        guard let url = URL(string: string) else { return }
                        MainActor.assumeIsolated { openURL(url) }
                    },
                    finished: { success, error in
                        continuation.resume(returning: success ? .success(()) : .failure(LoginError(reason: error)))
                    },
                ))
            }
        } onCancel: {
            Task { @MainActor in holder.subscription?.cancel() }
        }
    }
}

extension AniCore {
    var scheduleUpdates: AsyncStream<Observed<[AniScheduleDay]>> {
        stream { yield in observeSchedule(listener: ScheduleListener(yield)) }
    }
}

extension AniSettingsStore {
    var settingsUpdates: AsyncStream<AniSettings> {
        stream { yield in observeSettings(listener: SettingsListener(yield)) }
    }

    var danmakuFilterUpdates: AsyncStream<[AniDanmakuFilter]> {
        stream { yield in observeDanmakuFilters(listener: DanmakuFiltersListener(yield)) }
    }

    var mediaSourceUpdates: AsyncStream<[AniMediaSourceItem]> {
        stream { yield in observeMediaSources(listener: MediaSourcesListener(yield)) }
    }
}

extension AniDownloads {
    /// `subjectId` 为 0 时包含所有条目.
    func downloadUpdates(subjectId: Int32 = 0) -> AsyncStream<[AniDownload]> {
        stream { yield in observeDownloads(subjectId: subjectId, listener: DownloadsListener(yield)) }
    }
}

struct LoginError: Error {
    /// Kotlin 侧的错误类型名, 如 `NetworkError`.
    let reason: String?
}

extension AniEpisodeSession {
    func candidateUpdates(preferredOnly: Bool) -> AsyncStream<[AniMediaCandidate]> {
        stream { yield in observeCandidates(preferredOnly: preferredOnly, listener: CandidatesListener(yield)) }
    }

    var selectionUpdates: AsyncStream<AniMediaCandidate?> {
        stream { yield in observeSelected(listener: SelectionListener(yield)) }
    }

    var fetchProgressUpdates: AsyncStream<AniFetchProgress> {
        stream { yield in observeFetchProgress(listener: FetchProgressListener(yield)) }
    }

    var sourceUpdates: AsyncStream<[AniMediaSourceStatus]> {
        stream { yield in observeSources(listener: SourcesListener(yield)) }
    }

    var preferenceUpdates: AsyncStream<[AniPreference]> {
        stream { yield in observePreferences(listener: PreferencesListener(yield)) }
    }
}

extension Error {
    /// 解析失败的原因码 (`AniPlaybackException.reason`), 其他错误为 `nil`.
    var aniPlaybackReason: String? {
        let kotlinException = (self as NSError).userInfo["KotlinException"]
        return (kotlinException as? AniPlaybackException)?.reason
    }
}

// MARK: - Listener 实现

private final class SubscriptionHolder: @unchecked Sendable {
    var subscription: AniSubscription?
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

private final class SourcesListener: NSObject, AniSourcesListener {
    private let block: ([AniMediaSourceStatus]) -> Void
    init(_ block: @escaping ([AniMediaSourceStatus]) -> Void) { self.block = block }
    func onSources(sources: [AniMediaSourceStatus]) { block(sources) }
}

private final class PreferencesListener: NSObject, AniPreferencesListener {
    private let block: ([AniPreference]) -> Void
    init(_ block: @escaping ([AniPreference]) -> Void) { self.block = block }
    func onPreferences(preferences: [AniPreference]) { block(preferences) }
}

private final class SessionListener: NSObject, AniSessionListener {
    private let block: (AniSession) -> Void
    init(_ block: @escaping (AniSession) -> Void) { self.block = block }
    func onSession(session: AniSession) { block(session) }
}

private final class SubjectDetailListener: NSObject, AniSubjectDetailListener {
    private let block: (Observed<AniSubjectDetail>) -> Void
    init(_ block: @escaping (Observed<AniSubjectDetail>) -> Void) { self.block = block }
    func onDetail(detail: AniSubjectDetail) { block(.value(detail)) }
    func onError(message: String) { block(.failure(message)) }
}

private final class CollectionsListener: NSObject, AniCollectionsListener {
    private let block: (Observed<[AniCollectionItem]>) -> Void
    init(_ block: @escaping (Observed<[AniCollectionItem]>) -> Void) { self.block = block }
    func onCollections(items: [AniCollectionItem]) { block(.value(items)) }
    func onError(message: String) { block(.failure(message)) }
}

private final class LoginListener: NSObject, AniLoginListener {
    private let openURL: (String) -> Void
    private let finished: (Bool, String?) -> Void
    private var didFinish = false

    init(openURL: @escaping (String) -> Void, finished: @escaping (Bool, String?) -> Void) {
        self.openURL = openURL
        self.finished = finished
    }

    func onOpenUrl(url: String) { openURL(url) }

    func onFinished(success: Bool, errorMessage: String?) {
        guard !didFinish else { return }
        didFinish = true
        finished(success, errorMessage)
    }
}

private final class ScheduleListener: NSObject, AniScheduleListener {
    private let block: (Observed<[AniScheduleDay]>) -> Void
    init(_ block: @escaping (Observed<[AniScheduleDay]>) -> Void) { self.block = block }
    func onSchedule(days: [AniScheduleDay]) { block(.value(days)) }
    func onError(message: String) { block(.failure(message)) }
}

private final class SettingsListener: NSObject, AniSettingsListener {
    private let block: (AniSettings) -> Void
    init(_ block: @escaping (AniSettings) -> Void) { self.block = block }
    func onSettings(settings: AniSettings) { block(settings) }
}

private final class DanmakuFiltersListener: NSObject, AniDanmakuFiltersListener {
    private let block: ([AniDanmakuFilter]) -> Void
    init(_ block: @escaping ([AniDanmakuFilter]) -> Void) { self.block = block }
    func onFilters(filters: [AniDanmakuFilter]) { block(filters) }
}

private final class MediaSourcesListener: NSObject, AniMediaSourcesListener {
    private let block: ([AniMediaSourceItem]) -> Void
    init(_ block: @escaping ([AniMediaSourceItem]) -> Void) { self.block = block }
    func onMediaSources(sources: [AniMediaSourceItem]) { block(sources) }
}

private final class DownloadsListener: NSObject, AniDownloadsListener {
    private let block: ([AniDownload]) -> Void
    init(_ block: @escaping ([AniDownload]) -> Void) { self.block = block }
    func onDownloads(downloads: [AniDownload]) { block(downloads) }
}

extension AniWatchTogether {
    var roomUpdates: AsyncStream<AniWatchTogetherRoom> {
        stream { yield in observeRoom(listener: WatchTogetherRoomListener(yield)) }
    }

    var eventUpdates: AsyncStream<WatchTogetherEvent> {
        stream { yield in observeEvents(listener: WatchTogetherEventListener(yield)) }
    }

    var directiveUpdates: AsyncStream<AniPlaybackDirective> {
        stream { yield in observeDirectives(listener: WatchTogetherDirectiveListener(yield)) }
    }
}

/// 一起看中需要提示用户的事件.
enum WatchTogetherEvent {
    case navigate(AniWatchTogetherNavigation)
    case message(String)
}

private final class WatchTogetherRoomListener: NSObject, AniWatchTogetherRoomListener {
    private let block: (AniWatchTogetherRoom) -> Void
    init(_ block: @escaping (AniWatchTogetherRoom) -> Void) { self.block = block }
    func onRoom(room: AniWatchTogetherRoom) { block(room) }
}

private final class WatchTogetherEventListener: NSObject, AniWatchTogetherEventListener {
    private let block: (WatchTogetherEvent) -> Void
    init(_ block: @escaping (WatchTogetherEvent) -> Void) { self.block = block }
    func onNavigate(navigation: AniWatchTogetherNavigation) { block(.navigate(navigation)) }
    func onMessage(message: String) { block(.message(message)) }
}

private final class WatchTogetherDirectiveListener: NSObject, AniWatchTogetherDirectiveListener {
    private let block: (AniPlaybackDirective) -> Void
    init(_ block: @escaping (AniPlaybackDirective) -> Void) { self.block = block }
    func onDirective(directive: AniPlaybackDirective) { block(directive) }
}
