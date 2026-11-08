/*
 * Copyright (C) 2024-2026 OpenAni and contributors.
 *
 * 此源代码的使用受 GNU AFFERO GENERAL PUBLIC LICENSE version 3 许可证的约束, 可以在以下链接找到该许可证.
 * Use of this source code is governed by the GNU AGPLv3 license, which can be found at the following link.
 *
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.iosnative.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.shareIn
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import me.him188.ani.app.data.models.episode.allNames
import me.him188.ani.app.data.models.episode.displayName
import me.him188.ani.app.domain.danmaku.DanmakuRepository
import me.him188.ani.app.domain.danmaku.SplitSeasonDanmakuMatcher
import me.him188.ani.app.domain.episode.CreateMediaFetchSelectBundleFlowUseCase
import me.him188.ani.app.domain.episode.GetSubjectEpisodeInfoBundleFlowUseCase
import me.him188.ani.app.domain.episode.MediaFetchSelectBundle
import me.him188.ani.app.domain.episode.SubjectEpisodeInfoBundle
import me.him188.ani.app.domain.media.fetch.MediaSourceFetchState
import me.him188.ani.app.domain.media.resolver.MediaResolutionException
import me.him188.ani.app.domain.media.resolver.MediaResolver
import me.him188.ani.app.domain.media.resolver.MediaSourceOpenException
import me.him188.ani.app.domain.media.resolver.UnsupportedMediaException
import me.him188.ani.app.domain.media.resolver.toEpisodeMetadata
import me.him188.ani.app.domain.media.selector.MediaSelectorAutoSelectUseCase
import me.him188.ani.app.domain.media.selector.SelectTrigger
import me.him188.ani.danmaku.api.provider.DanmakuFetchRequest
import me.him188.ani.datasources.api.Media
import org.koin.core.Koin
import org.openani.mediamp.source.UriMediaData
import kotlin.coroutines.CoroutineContext
import kotlin.time.Duration

/**
 * 一集的查询 - 选择 - 解析会话.
 *
 * 复用上游的 [GetSubjectEpisodeInfoBundleFlowUseCase], [CreateMediaFetchSelectBundleFlowUseCase],
 * [MediaSelectorAutoSelectUseCase] 与 [MediaResolver], 因此选源规则与 Animeko 其他平台一致.
 * 本类只负责把结果翻译成 facade 值类型, 不持有任何界面状态.
 *
 * 播放器由 Swift 持有: [resolveSelected] 返回可播放地址, Swift 用它创建 `AVPlayerItem`.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class AniEpisodeSession internal constructor(
    koin: Koin,
    parentScope: CoroutineScope,
    private val callbackContext: CoroutineContext,
    val subjectId: Int,
    val episodeId: Int,
) {
    private val scope = CoroutineScope(
        parentScope.coroutineContext + SupervisorJob(parentScope.coroutineContext[Job]),
    )

    private val autoSelectUseCase: MediaSelectorAutoSelectUseCase = koin.get()
    private val danmakuRepository: DanmakuRepository = koin.get()

    // MediaResolver 在 Koin 中是 factory, 每个会话持有一个实例.
    private val mediaResolver: MediaResolver = koin.get()

    private val infoBundle: SharedFlow<SubjectEpisodeInfoBundle> =
        koin.get<GetSubjectEpisodeInfoBundleFlowUseCase>()
            .invoke(flowOf(GetSubjectEpisodeInfoBundleFlowUseCase.SubjectIdAndEpisodeId(subjectId, episodeId)))
            .shareIn(scope, SharingStarted.Eagerly, replay = 1)

    private val fetchSelect: StateFlow<MediaFetchSelectBundle?> =
        koin.get<CreateMediaFetchSelectBundleFlowUseCase>()
            .invoke(infoBundle)
            .stateIn(scope, SharingStarted.Eagerly, null)

    private var resolveJob: Job? = null

    init {
        // MediaFetchSession 只在 cumulativeResults 被持续收集时查询, 停止收集会中断查询.
        scope.launch {
            fetchSelect.filterNotNull().collectLatest { bundle ->
                bundle.mediaFetchSession.cumulativeResults.collect()
            }
        }
    }

    /**
     * 观察当前剧集经过滤与排序的候选资源. 查询过程中会随数据源返回而多次回调.
     */
    fun observeCandidates(listener: AniCandidatesListener): AniSubscription = observe(
        fetchSelect.filterNotNull()
            .flatMapLatest { it.mediaSelector.filteredCandidatesMedia }
            .map { list -> list.map { it.toCandidate() } },
    ) { listener.onCandidates(it) }

    /**
     * 观察已选择的资源. 自动选择与 [select] 都会触发回调; 未选择时为 `null`.
     */
    fun observeSelected(listener: AniSelectionListener): AniSubscription = observe(
        fetchSelect.filterNotNull()
            .flatMapLatest { it.mediaSelector.selected }
            .map { it?.toCandidate() },
    ) { listener.onSelected(it) }

    /**
     * 观察数据源查询进度.
     */
    fun observeFetchProgress(listener: AniFetchProgressListener): AniSubscription = observe(
        fetchSelect.filterNotNull().flatMapLatest { bundle -> bundle.fetchProgressFlow() },
    ) { listener.onProgress(it) }

    /**
     * 按 Animeko 的自动选源规则选择资源 (偏好, 数据源阶级, 快速选择超时), 等待到选出或所有数据源结束.
     *
     * @return 选中的资源; 没有可用资源时为 `null`.
     */
    @Throws(Exception::class)
    suspend fun autoSelect(): AniMediaCandidate? {
        val bundle = fetchSelect.filterNotNull().first()
        autoSelectUseCase(bundle.mediaFetchSession, bundle.mediaSelector)
        return bundle.mediaSelector.selected.value?.toCandidate()
    }

    /**
     * 手动选择一个候选资源, 并记住偏好.
     *
     * @return `false` 表示 [mediaId] 不在当前候选中.
     */
    @Throws(Exception::class)
    suspend fun select(mediaId: String): Boolean {
        val selector = fetchSelect.filterNotNull().first().mediaSelector
        val media = selector.filteredCandidatesMedia.first().firstOrNull { it.mediaId == mediaId }
            ?: return false
        return selector.select(media, SelectTrigger.MANUAL_AUTO_PAGE)
    }

    /**
     * 解析当前选中的资源为可播放地址. 网页资源会在后台 `WKWebView` 中加载页面并拦截视频请求, 可能需要数秒.
     *
     * 再次调用会释放上一次解析占用的资源.
     *
     * @throws AniPlaybackException 解析失败, [AniPlaybackException.reason] 说明原因.
     */
    @Throws(Exception::class)
    suspend fun resolveSelected(): AniPlayable {
        val bundle = fetchSelect.filterNotNull().first()
        val media = bundle.mediaSelector.selected.value
            ?: throw AniPlaybackException(AniPlaybackException.REASON_NOTHING_SELECTED, "No media selected")
        val episode = infoBundle.first().episodeCollectionInfo.episodeInfo

        resolveJob?.cancel()
        val job = Job(scope.coroutineContext[Job])
        resolveJob = job
        val resolveScope = CoroutineScope(scope.coroutineContext + job)

        val data = try {
            mediaResolver.resolve(media, episode.toEpisodeMetadata()).open(resolveScope)
        } catch (e: UnsupportedMediaException) {
            throw AniPlaybackException(AniPlaybackException.REASON_UNSUPPORTED, e.message, e)
        } catch (e: MediaResolutionException) {
            throw AniPlaybackException(e.reason.name, e.message, e)
        } catch (e: MediaSourceOpenException) {
            throw AniPlaybackException(e.reason.name, e.message, e)
        }
        return (data as? UriMediaData)?.toAniPlayable(media.originalTitle)
            ?: throw AniPlaybackException(
                AniPlaybackException.REASON_UNSUPPORTED,
                "Resolved media data is not a URI: ${data::class.simpleName}",
            )
    }

    /**
     * 从所有弹幕源获取本集弹幕, 按时间升序.
     */
    @Throws(Exception::class)
    suspend fun fetchDanmaku(): List<AniDanmaku> {
        val request = infoBundle.first().toDanmakuFetchRequest()
        return danmakuRepository.fetchFromAllRemotes(request).first()
            .flatMap { it.list }
            .map { it.toAniDanmaku() }
            .sortedBy { it.timeMillis }
    }

    /**
     * 结束会话: 停止查询, 释放解析占用的资源. 之后不再回调.
     */
    fun close() {
        scope.cancel()
    }

    private fun Media.toCandidate(): AniMediaCandidate = toAniMediaCandidate(playable = mediaResolver.supports(this))

    private fun <T> observe(flow: Flow<T>, onValue: (T) -> Unit): AniSubscription {
        val job = scope.launch {
            flow.distinctUntilChanged().collect { value ->
                withContext(callbackContext) { onValue(value) }
            }
        }
        return AniSubscription(job)
    }
}

private fun MediaFetchSelectBundle.fetchProgressFlow(): Flow<AniFetchProgress> {
    val results = mediaFetchSession.mediaSourceResults
    if (results.isEmpty()) return flowOf(AniFetchProgress(completed = 0, total = 0, candidateCount = 0))
    return combine(
        combine(results.map { it.state }) { it.toList() },
        mediaFetchSession.cumulativeResults,
    ) { states, media ->
        val enabled = states.filter { it !is MediaSourceFetchState.Disabled }
        AniFetchProgress(
            completed = enabled.count { it is MediaSourceFetchState.Completed },
            total = enabled.size,
            candidateCount = media.size,
        )
    }
}

private fun SubjectEpisodeInfoBundle.toDanmakuFetchRequest(): DanmakuFetchRequest {
    val subject = subjectInfo
    val episode = episodeCollectionInfo.episodeInfo
    return DanmakuFetchRequest(
        subjectId = subject.subjectId,
        subjectPrimaryName = subject.displayName,
        subjectNames = subject.allNames,
        subjectPublishDate = subject.airDate,
        episodeId = episode.episodeId,
        episodeSort = episode.sort,
        episodeEp = episode.ep,
        episodeName = episode.displayName,
        episodeNames = episode.allNames,
        filename = null,
        // 与上游 SearchDanmakuRequest 的默认值一致: 未知文件时用占位哈希
        fileHash = "aa".repeat(16),
        fileSize = null,
        videoDuration = Duration.ZERO,
        splitSeason = SplitSeasonDanmakuMatcher.create(
            seriesInfo.splitSeason,
            subject.allNames,
            episode.sort,
            episode.ep,
        ),
    )
}

interface AniCandidatesListener {
    fun onCandidates(candidates: List<AniMediaCandidate>)
}

interface AniSelectionListener {
    fun onSelected(candidate: AniMediaCandidate?)
}

interface AniFetchProgressListener {
    fun onProgress(progress: AniFetchProgress)
}

/**
 * 解析失败. [reason] 取值为本类的 `REASON_*` 常量, 或上游 `ResolutionFailures` / `OpenFailures` 的枚举名.
 */
class AniPlaybackException(
    val reason: String,
    message: String?,
    cause: Throwable? = null,
) : Exception(message, cause) {
    companion object {
        const val REASON_NOTHING_SELECTED = "NOTHING_SELECTED"
        const val REASON_UNSUPPORTED = "UNSUPPORTED"
    }
}
