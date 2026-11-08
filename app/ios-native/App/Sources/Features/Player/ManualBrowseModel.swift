import AniCore
import Foundation

/// 手动查找的状态: 选中的数据源, 关键字, 各源的搜索结果, 打开的条目与线路.
///
/// 由 `PlayerModel` 持有, 关闭选源面板后保留, 切换剧集时重置 (打开过的条目属于旧的 Kotlin 会话).
@MainActor
@Observable
final class ManualBrowseModel {
    enum Load<Value> {
        case idle
        case loading
        case loaded(Value)
        case failed(String)
    }

    private(set) var sources: [AniBrowseSource] = []
    private(set) var sourcesLoaded = false
    private(set) var selectedSourceId: String?
    var keyword = ""

    /// 当前源的搜索结果
    private(set) var results: Load<[AniBrowseSubject]> = .idle
    private(set) var openedSubject: AniBrowseSubject?
    private(set) var channels: Load<[AniBrowseChannel]> = .idle
    var selectedChannelIndex = 0
    private(set) var isPlaying = false
    private(set) var playError: String?

    /// 按源缓存的搜索: 切回同一关键字搜过的源直接显示, 不重复请求. 失败也缓存, 只在用户重试时重搜.
    @ObservationIgnored private var searchCache: [String: (keyword: String, result: Load<[AniBrowseSubject]>)] = [:]

    var selectedSource: AniBrowseSource? {
        sources.first { $0.instanceId == selectedSourceId }
    }

    func reset() {
        sources = []
        sourcesLoaded = false
        selectedSourceId = nil
        keyword = ""
        results = .idle
        searchCache = [:]
        closeSubject()
    }

    /// 首次打开时加载可浏览的源与默认值, 并用默认关键字搜索默认源.
    func loadIfNeeded(session: AniEpisodeSession) async {
        guard !sourcesLoaded else { return }
        guard let info = try? await session.browseSources() else {
            sourcesLoaded = true
            return
        }
        sources = info.sources
        keyword = info.defaultKeyword
        selectedSourceId = info.defaultInstanceId
        sourcesLoaded = true
        await searchIfNeeded(session: session)
    }

    /// 换源. 打开的条目属于原来的源, 一并关闭.
    func selectSource(_ instanceId: String, session: AniEpisodeSession) async {
        selectedSourceId = instanceId
        closeSubject()
        await searchIfNeeded(session: session)
    }

    /// 当前源用当前关键字搜过 (包括失败) 时直接显示缓存, 否则搜索.
    func searchIfNeeded(session: AniEpisodeSession) async {
        guard let sourceId = selectedSourceId else { return }
        if let cached = searchCache[sourceId], cached.keyword == keyword {
            results = cached.result
            return
        }
        await search(session: session)
    }

    /// 总是重新搜索当前源, 可以当作刷新与重试.
    func search(session: AniEpisodeSession) async {
        guard let sourceId = selectedSourceId else { return }
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        closeSubject()
        results = .loading
        let result: Load<[AniBrowseSubject]>
        do {
            result = .loaded(try await session.browseSearch(instanceId: sourceId, keyword: keyword))
        } catch {
            result = .failed(Self.describe(error))
        }
        searchCache[sourceId] = (keyword, result)
        // 搜索期间用户可能已经换源; 只更新仍在看的源
        if selectedSourceId == sourceId { results = result }
    }

    func openSubject(_ subject: AniBrowseSubject, session: AniEpisodeSession) async {
        guard let sourceId = selectedSourceId else { return }
        openedSubject = subject
        channels = .loading
        playError = nil
        do {
            let list = try await session.browseSubject(instanceId: sourceId, subject: subject)
            guard openedSubject?.url == subject.url else { return }
            channels = .loaded(list)
            // 默认选中有预选项的线路, 否则第一条
            selectedChannelIndex = list.first { $0.preselectedEpisodeIndex >= 0 }.map { Int($0.index) } ?? 0
        } catch {
            guard openedSubject?.url == subject.url else { return }
            channels = .failed(Self.describe(error))
        }
    }

    func closeSubject() {
        openedSubject = nil
        channels = .idle
        selectedChannelIndex = 0
        playError = nil
    }

    /// 把一集作为当前集播放.
    /// - Returns: 是否成功提交选择 (成功后面板关闭, 播放由选择变化触发).
    func play(episodeIndex: Int, remember: Bool, session: AniEpisodeSession) async -> Bool {
        guard let sourceId = selectedSourceId, let subject = openedSubject, !isPlaying else { return false }
        isPlaying = true
        playError = nil
        defer { isPlaying = false }
        do {
            try await session.playBrowsed(
                instanceId: sourceId,
                subjectUrl: subject.url,
                channelIndex: Int32(selectedChannelIndex),
                episodeIndex: Int32(episodeIndex),
                remember: remember,
            )
            return true
        } catch {
            playError = Self.describe(error)
            return false
        }
    }

    private static func describe(_ error: Error) -> String {
        let kotlinException = (error as NSError).userInfo["KotlinException"]
        if let browse = kotlinException as? AniBrowseException, browse.reason == "CAPTCHA_UNSUPPORTED" {
            return "该站点要求验证码, iOS 暂不支持在 App 内完成验证"
        }
        return error.localizedDescription
    }
}
