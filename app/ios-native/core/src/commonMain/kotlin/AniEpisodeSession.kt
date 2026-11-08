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
import me.him188.ani.app.data.models.episode.allNames
import me.him188.ani.app.data.models.preference.HlsAdFilteringMode
import me.him188.ani.app.data.models.episode.displayName
import me.him188.ani.app.data.network.AutoSkipRepository
import me.him188.ani.app.data.repository.player.EpisodePlayHistoryRepository
import me.him188.ani.app.data.repository.user.SettingsRepository
import me.him188.ani.app.domain.danmaku.DanmakuRepository
import me.him188.ani.app.domain.danmaku.DanmakuTextConversionSettings
import me.him188.ani.app.domain.danmaku.SplitSeasonDanmakuMatcher
import me.him188.ani.app.domain.episode.CreateMediaFetchSelectBundleFlowUseCase
import me.him188.ani.app.domain.episode.EpisodeCompletionContext
import me.him188.ani.app.domain.episode.findNeighborEpisode
import me.him188.ani.app.domain.episode.GetEpisodeCollectionTypeUseCase
import me.him188.ani.app.domain.episode.GetSubjectEpisodeInfoBundleFlowUseCase
import me.him188.ani.app.domain.episode.MediaFetchSelectBundle
import me.him188.ani.app.domain.episode.SetEpisodeCollectionTypeUseCase
import me.him188.ani.app.domain.episode.SubjectEpisodeInfoBundle
import me.him188.ani.app.domain.media.download.AddDownloadUseCase
import me.him188.ani.app.domain.media.fetch.MediaSourceFetchState
import me.him188.ani.app.domain.media.fetch.create
import me.him188.ani.app.domain.media.hls.HlsPlaybackOptions
import me.him188.ani.app.domain.media.hls.HlsPlaybackPreparer
import me.him188.ani.app.domain.media.hls.HlsPlaybackProxySession
import me.him188.ani.app.domain.media.resolver.MediaResolutionException
import me.him188.ani.app.domain.media.resolver.MediaResolver
import me.him188.ani.app.domain.media.resolver.MediaSourceOpenException
import me.him188.ani.app.domain.media.resolver.UnsupportedMediaException
import me.him188.ani.app.domain.media.resolver.toEpisodeMetadata
import me.him188.ani.app.domain.media.selector.MediaPreferenceItem
import me.him188.ani.app.domain.media.selector.MediaSelectorAutoSelectUseCase
import me.him188.ani.app.domain.media.selector.SelectTrigger
import me.him188.ani.app.domain.mediasource.MediaSourceTags
import me.him188.ani.app.domain.mediasource.instance.GetMediaSourceInstancesUseCase
import me.him188.ani.app.domain.settings.GetDanmakuRegexFilterListFlowUseCase
import me.him188.ani.app.domain.settings.GetVideoScaffoldConfigUseCase
import me.him188.ani.danmaku.api.DanmakuServiceId
import me.him188.ani.danmaku.api.provider.DanmakuFetchRequest
import me.him188.ani.datasources.api.Media
import me.him188.ani.datasources.api.MediaCacheMetadata
import me.him188.ani.datasources.api.source.MediaFetchRequest
import me.him188.ani.datasources.api.topic.UnifiedCollectionType
import me.him188.ani.datasources.api.topic.isDoneOrDropped
import me.him188.ani.app.data.models.episode.EpisodeInfo
import me.him188.ani.app.data.models.subject.nameCnOrName
import me.him188.ani.app.data.repository.media.ManualBrowseMemory
import me.him188.ani.app.data.repository.media.ManualBrowseMemoryRepository
import me.him188.ani.app.domain.media.fetch.awaitCompletedResults
import me.him188.ani.app.domain.media.selector.MaybeExcludedMedia
import me.him188.ani.app.domain.media.selector.MediaSelector
import me.him188.ani.app.domain.media.selector.ReplayBrowseMemoryUseCase
import me.him188.ani.app.domain.media.selector.UnsafeOriginalMediaAccess
import me.him188.ani.app.domain.media.selector.preselectedBrowseEpisodeIndex
import me.him188.ani.app.domain.mediasource.GetPreferredWebMediaSourceUseCase
import me.him188.ani.app.domain.mediasource.instance.MediaSourceInstance
import me.him188.ani.app.domain.mediasource.web.BlockReason
import me.him188.ani.app.domain.mediasource.web.BlockedException
import me.him188.ani.datasources.api.source.BrowseChannel
import me.him188.ani.datasources.api.source.BrowseSubject
import me.him188.ani.datasources.api.source.MediaSourceKind
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration.Companion.seconds
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
    private val playHistoryRepository: EpisodePlayHistoryRepository = koin.get()
    private val getEpisodeCollectionType: GetEpisodeCollectionTypeUseCase = koin.get()
    private val setEpisodeCollectionType: SetEpisodeCollectionTypeUseCase = koin.get()
    private val hlsPlaybackPreparer: HlsPlaybackPreparer = koin.get()
    private val getVideoScaffoldConfig: GetVideoScaffoldConfigUseCase = koin.get()
    private val getMediaSourceInstances: GetMediaSourceInstancesUseCase = koin.get()
    private val settingsRepository: SettingsRepository = koin.get()
    private val getDanmakuRegexFilterList: GetDanmakuRegexFilterListFlowUseCase = koin.get()
    private val danmakuProcessor = DanmakuProcessor()
    private val addDownload: AddDownloadUseCase = koin.get()
    private val autoSkipRepository: AutoSkipRepository = koin.get()
    private val replayBrowseMemory: ReplayBrowseMemoryUseCase = koin.get()
    private val manualBrowseMemory: ManualBrowseMemoryRepository = koin.get()
    private val getPreferredWebMediaSource: GetPreferredWebMediaSourceUseCase = koin.get()
    private var skipRules: List<Long>? = null

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
    private var hlsProxySession: HlsPlaybackProxySession? = null
    private var markedWatched = false

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
     *
     * @param preferredOnly 为 `true` 时只包含符合当前偏好 ([setPreference]) 的资源.
     */
    fun observeCandidates(preferredOnly: Boolean, listener: AniCandidatesListener): AniSubscription = observe(
        fetchSelect.filterNotNull()
            .flatMapLatest {
                if (preferredOnly) it.mediaSelector.preferredCandidatesMedia else it.mediaSelector.filteredCandidatesMedia
            }
            .map { list -> list.map { it.toCandidate() } },
    ) { listener.onCandidates(it) }

    /**
     * 观察每个数据源的查询状态.
     */
    fun observeSources(listener: AniSourcesListener): AniSubscription = observe(
        fetchSelect.filterNotNull().flatMapLatest { bundle -> bundle.sourceStatusFlow() },
    ) { listener.onSources(it) }

    /**
     * 重新查询一个失败或被放弃的数据源; 对已禁用的数据源则临时启用它.
     */
    fun retrySource(instanceId: String) {
        val result = fetchSelect.value?.mediaFetchSession?.mediaSourceResults
            ?.firstOrNull { it.instanceId == instanceId } ?: return
        if (result.state.value is MediaSourceFetchState.Disabled) result.enable() else result.restart()
    }

    /**
     * 观察选源偏好 (字幕组, 分辨率, 字幕语言, 数据源).
     */
    fun observePreferences(listener: AniPreferencesListener): AniSubscription = observe(
        fetchSelect.filterNotNull().flatMapLatest { bundle ->
            val selector = bundle.mediaSelector
            combine(
                selector.alliance.toAniPreference(AniPreferenceKeys.ALLIANCE),
                selector.resolution.toAniPreference(AniPreferenceKeys.RESOLUTION),
                selector.subtitleLanguageId.toAniPreference(AniPreferenceKeys.SUBTITLE_LANGUAGE),
                selector.mediaSourceId.toAniPreference(AniPreferenceKeys.MEDIA_SOURCE),
            ) { a, b, c, d -> listOf(a, b, c, d) }
        },
    ) { listener.onPreferences(it) }

    /**
     * 设置一个偏好维度. [value] 为 `null` 时清除该维度的偏好. 偏好会保存并影响之后的自动选择.
     */
    @Throws(Exception::class)
    suspend fun setPreference(key: String, value: String?) {
        val selector = fetchSelect.filterNotNull().first().mediaSelector
        val item: MediaPreferenceItem<String> = when (key) {
            AniPreferenceKeys.ALLIANCE -> selector.alliance
            AniPreferenceKeys.RESOLUTION -> selector.resolution
            AniPreferenceKeys.SUBTITLE_LANGUAGE -> selector.subtitleLanguageId
            AniPreferenceKeys.MEDIA_SOURCE -> selector.mediaSourceId
            else -> throw IllegalArgumentException("Unknown preference key: $key")
        }
        if (value == null) item.removePreference() else item.prefer(value)
    }

    /**
     * 本集上次播放到的位置 (毫秒). 没有记录或已看完时为 0.
     */
    @Throws(Exception::class)
    suspend fun resumePositionMillis(): Long {
        return playHistoryRepository.getResumePositionMillisByEpisodeId(episodeId) ?: 0L
    }

    /**
     * 上报播放进度. Swift 在播放中定期 (约每 5 秒) 以及暂停, 退出时调用.
     *
     * 保存播放位置; 正在播放且看到 90% 时把本集标记为看过 (每个会话最多一次), 规则与上游一致.
     */
    @Throws(Exception::class)
    suspend fun reportPlayback(positionMillis: Long, durationMillis: Long, isPlaying: Boolean) {
        if (!PlaybackProgressPolicy.shouldSave(positionMillis, durationMillis)) return
        val info = infoBundle.first()
        playHistoryRepository.saveOrUpdate(
            episodeId = episodeId,
            positionMillis = positionMillis.coerceAtMost(durationMillis),
            subjectId = subjectId,
            episodeSort = info.episodeInfo.sort.number,
            subjectName = info.subjectInfo.displayName,
            subjectImageUrl = info.subjectInfo.imageLarge,
            episodeName = info.episodeInfo.displayName,
            durationMillis = durationMillis,
        )
        if (isPlaying && !markedWatched && PlaybackProgressPolicy.shouldMarkWatched(positionMillis, durationMillis)) {
            markedWatched = true
            if (!settingsRepository.videoScaffoldConfig.flow.first().autoMarkDone) return
            val current = getEpisodeCollectionType(subjectId, episodeId, allowNetwork = false)
            if (current?.isDoneOrDropped() != true) {
                setEpisodeCollectionType(subjectId, episodeId, UnifiedCollectionType.DONE)
            }
        }
    }

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
        // 与上游 AutoSelectExtension 相同的顺序: 本地缓存 → 浏览记忆回放 → 自动选择
        val episodeInfo = infoBundle.first().episodeInfo
        val replayed = !hasLocalCacheForEpisode(bundle) && replayBrowseMemorySafely(episodeInfo, bundle.mediaSelector)
        if (!replayed) {
            autoSelectUseCase(bundle.mediaFetchSession, bundle.mediaSelector)
        }
        return bundle.mediaSelector.selected.value?.toCandidate()
    }

    private suspend fun replayBrowseMemorySafely(episodeInfo: EpisodeInfo, selector: MediaSelector): Boolean = try {
        replayBrowseMemory(subjectId, episodeInfo, selector).isHit
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        false // 任何失败都退回自动选择
    }

    /**
     * 本地缓存的优先级高于浏览记忆: 等本地缓存源完成 (最多 2 秒), 看候选里有没有本集的缓存.
     */
    @OptIn(UnsafeOriginalMediaAccess::class)
    private suspend fun hasLocalCacheForEpisode(bundle: MediaFetchSelectBundle): Boolean {
        val cacheResults = bundle.mediaFetchSession.mediaSourceResults.filter { it.kind == MediaSourceKind.LocalCache }
        if (cacheResults.isEmpty()) return false
        return try {
            withTimeoutOrNull(2.seconds) {
                val cachedMediaIds = cacheResults.flatMapTo(HashSet()) { result ->
                    result.awaitCompletedResults().map { it.mediaId }
                }
                if (cachedMediaIds.isEmpty()) return@withTimeoutOrNull false
                bundle.mediaSelector.filteredCandidates
                    .first { candidates -> candidates.any { it.original.mediaId in cachedMediaIds } }
                    .any { it is MaybeExcludedMedia.Included && it.result.kind == MediaSourceKind.LocalCache }
            } == true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            false
        }
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
        // 用户在别处手动换源, 说明不想再按浏览记忆走; 删除记忆, 下一集回到自动匹配
        forgetBrowseMemory()
        return selector.select(media, SelectTrigger.MANUAL_AUTO_PAGE)
    }

    // region 手动查找

    private val browsedSubjects = mutableMapOf<String, Pair<BrowseSubject, List<BrowseChannel>>>()

    /**
     * 支持浏览的已启用数据源, 以及默认选中的源与关键字.
     */
    @Throws(Exception::class)
    suspend fun browseSources(): AniBrowseSources {
        val instances = browsableInstances()
        val memorySourceId = manualBrowseMemory.get(subjectId)?.mediaSourceId
        val preferredId = memorySourceId ?: getPreferredWebMediaSource(subjectId).first()
        val default = instances.firstOrNull { it.mediaSourceId == preferredId } ?: instances.firstOrNull()
        return AniBrowseSources(
            sources = instances.map { AniBrowseSource(it.instanceId, it.mediaSourceId, it.source.info.displayName) },
            defaultInstanceId = default?.instanceId,
            defaultKeyword = infoBundle.first().subjectInfo.nameCnOrName,
        )
    }

    /**
     * 在数据源 [instanceId] 上按关键字搜索条目, 原样返回站点的结果 (不匹配, 不排序).
     *
     * @throws AniBrowseException 请求失败; 站点要求验证码时 reason 为 CAPTCHA_UNSUPPORTED.
     */
    @Throws(Exception::class)
    suspend fun browseSearch(instanceId: String, keyword: String): List<AniBrowseSubject> {
        val instance = browsableInstance(instanceId)
        return runBrowse { instance.source.searchSubjects(keyword) }
            .map { AniBrowseSubject(it.name, it.url) }
    }

    /**
     * 打开条目, 返回全部线路与剧集. 每条线路带有对应正在观看这一集的预选项 (规则同上游手动查找).
     */
    @Throws(Exception::class)
    suspend fun browseSubject(instanceId: String, subject: AniBrowseSubject): List<AniBrowseChannel> {
        val instance = browsableInstance(instanceId)
        val browseSubject = BrowseSubject(subject.name, subject.url)
        val channels = runBrowse { instance.source.browseSubject(browseSubject) }
        browsedSubjects[subject.url] = browseSubject to channels
        val info = infoBundle.first()
        return channels.mapIndexed { index, channel ->
            AniBrowseChannel(
                index = index,
                label = channel.label ?: channel.name ?: "",
                episodes = channel.episodes.mapIndexed { i, episode ->
                    AniBrowseEpisode(i, episode.name, episode.episodeSort?.toString().orEmpty())
                },
                preselectedEpisodeIndex = preselectedBrowseEpisodeIndex(
                    pageName = browseSubject.name,
                    episodes = channel.episodes,
                    sort = info.episodeInfo.sort,
                    ep = info.episodeInfo.ep,
                    splitSeason = info.seriesInfo.splitSeason,
                    subjectNames = info.subjectInfo.allNames,
                ) ?: -1,
            )
        }
    }

    /**
     * 把 [browseSubject] 打开过的条目里的一集作为当前集播放.
     *
     * [remember] 为 `true` 时是正式选择: 写入选源偏好与浏览记忆, 之后每一集按记住的线路里对应位置的一项自动选择.
     * 为 `false` 时只对本集有效, 不写偏好与记忆.
     */
    @Throws(Exception::class)
    suspend fun playBrowsed(instanceId: String, subjectUrl: String, channelIndex: Int, episodeIndex: Int, remember: Boolean) {
        val instance = browsableInstance(instanceId)
        val (subject, channels) = browsedSubjects[subjectUrl]
            ?: throw AniBrowseException(AniBrowseException.REASON_FAILED, "Subject not opened: $subjectUrl")
        val channel = channels.getOrNull(channelIndex)
            ?: throw AniBrowseException(AniBrowseException.REASON_FAILED, "No channel $channelIndex")
        val episode = channel.episodes.getOrNull(episodeIndex)
            ?: throw AniBrowseException(AniBrowseException.REASON_FAILED, "No episode $episodeIndex")
        val sort = infoBundle.first().episodeInfo.sort
        val media = try {
            instance.source.createMedia(subject, channel.name, episode, sort)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            throw AniBrowseException(AniBrowseException.REASON_FAILED, e.message, e)
        }
        val selector = fetchSelect.filterNotNull().first().mediaSelector
        if (remember) {
            selector.select(media, SelectTrigger.MANUAL_BROWSE)
            manualBrowseMemory.set(
                subjectId,
                ManualBrowseMemory(
                    mediaSourceId = instance.mediaSourceId,
                    subject = subject,
                    channelIndex = channelIndex,
                    channelName = channel.name,
                    episodeIndex = episodeIndex,
                    playedAsSort = sort,
                ),
            )
        } else {
            selector.selectTemporarily(media, SelectTrigger.MANUAL_BROWSE)
        }
    }

    /**
     * 切换 "记住选择". 关闭时一并删除本条目已有的浏览记忆, 否则下一集仍会按旧记忆回放.
     */
    @Throws(Exception::class)
    suspend fun setRememberManualSelection(remember: Boolean) {
        settingsRepository.mediaSelectorSettings.update { copy(rememberManualSelection = remember) }
        if (!remember) forgetBrowseMemory()
    }

    private suspend fun forgetBrowseMemory() {
        try {
            manualBrowseMemory.remove(subjectId)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // 删除失败只影响下一集是否回放
        }
    }

    private suspend fun browsableInstances(): List<MediaSourceInstance> =
        getMediaSourceInstances().first().filter { it.isEnabled && it.source.supportsBrowsing }

    private suspend fun browsableInstance(instanceId: String): MediaSourceInstance =
        browsableInstances().firstOrNull { it.instanceId == instanceId }
            ?: throw AniBrowseException(AniBrowseException.REASON_FAILED, "Media source $instanceId is not browsable")

    /**
     * 浏览请求的统一异常处理. iOS 没有交互式验证码, 被验证码挡住时直接报告不支持.
     */
    private suspend fun <T> runBrowse(request: suspend () -> T): T = try {
        request()
    } catch (e: CancellationException) {
        throw e
    } catch (e: BlockedException) {
        val reason = if (e.reason is BlockReason.Captcha) {
            AniBrowseException.REASON_CAPTCHA_UNSUPPORTED
        } else {
            AniBrowseException.REASON_FAILED
        }
        throw AniBrowseException(reason, e.message, e)
    } catch (e: Exception) {
        throw AniBrowseException(AniBrowseException.REASON_FAILED, e.message, e)
    }

    // endregion

    /**
     * 解析当前选中的资源为可播放地址. 网页资源会在后台 `WKWebView` 中加载页面并拦截视频请求, 可能需要数秒.
     *
     * 按用户的 HLS 去广告设置, 需要时经上游的 HLS 本地代理过滤广告分片, 此时返回的是本地代理地址.
     * 再次调用会释放上一次解析占用的资源 (包括本地代理).
     *
     * @param startPositionMillis 预计的起播位置, 用作 HLS 代理预缓存的起点.
     * @throws AniPlaybackException 解析失败, [AniPlaybackException.reason] 说明原因.
     */
    @Throws(Exception::class)
    suspend fun resolveSelected(startPositionMillis: Long): AniPlayable {
        val bundle = fetchSelect.filterNotNull().first()
        val media = bundle.mediaSelector.selected.value
            ?: throw AniPlaybackException(AniPlaybackException.REASON_NOTHING_SELECTED, "No media selected")
        val episode = infoBundle.first().episodeCollectionInfo.episodeInfo

        releaseResolved()
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
        val uriData = data as? UriMediaData
            ?: throw AniPlaybackException(
                AniPlaybackException.REASON_UNSUPPORTED,
                "Resolved media data is not a URI: ${data::class.simpleName}",
            )
        return prepareHls(uriData, media, startPositionMillis).toAniPlayable(media.originalTitle)
    }

    /**
     * 与上游 `PlayerSession` 相同的 HLS 去广告判断. 本客户端不做自动跳过 OP/ED, 因此不需要代理分片.
     */
    private suspend fun prepareHls(data: UriMediaData, media: Media, startPositionMillis: Long): UriMediaData {
        val config = getVideoScaffoldConfig().first()
        val options = HlsPlaybackOptions(
            filterSegments = when (config.effectiveHlsAdFilteringMode) {
                HlsAdFilteringMode.ALL -> true
                HlsAdFilteringMode.SMART -> MediaSourceTags.HLS_ADS in mediaSourceTags(media.mediaSourceId)
                HlsAdFilteringMode.OFF -> false
            },
            proxySegments = false,
        )
        if (!options.isEnabled) return data
        val result = hlsPlaybackPreparer.prepare(data, options, startPositionMillis.takeIf { it > 0 })
        hlsProxySession = result.session
        return result.data
    }

    private suspend fun mediaSourceTags(mediaSourceId: String): List<String> {
        return getMediaSourceInstances().first()
            .find { it.mediaSourceId == mediaSourceId }
            ?.config?.tags
            .orEmpty()
    }

    private fun releaseResolved() {
        resolveJob?.cancel()
        resolveJob = null
        hlsProxySession?.close()
        hlsProxySession = null
    }

    /**
     * 本集可自动跳过的 OP/ED 片段, 来自服务器汇总的用户跳过记录. 每个会话只请求一次.
     *
     * @param videoDurationMillis 视频时长, 决定片段长度; 10 分钟以下的视频没有片段.
     */
    @Throws(Exception::class)
    suspend fun skipSegments(videoDurationMillis: Long): List<AniSkipSegment> {
        val times = skipRules ?: autoSkipRepository.rulesFlow(episodeId).first().also { skipRules = it }
        val opEdSkipMillis = settingsRepository.videoScaffoldConfig.flow.first().opEdSkipDuration.inWholeMilliseconds
        return buildSkipSegments(times, videoDurationMillis, opEdSkipMillis)
    }

    /**
     * 上报一次手动跳过 OP/ED, 帮助服务器统计跳过点. 上游仓库会限流 (每集最多两次, 间隔十分钟).
     * 拖入的本地文件之类不属于任何数据源的资源不上报.
     */
    @Throws(Exception::class)
    suspend fun reportManualSkip(positionMillis: Long) {
        val media = fetchSelect.value?.mediaSelector?.selected?.value ?: return
        val timeSeconds = (positionMillis / 1000).toInt()
        if (timeSeconds !in 0..200 * 60) return
        autoSkipRepository.reportSkip(episodeId, media.mediaSourceId, timeSeconds, positionMillis)
    }

    /**
     * 自动播放时的下一集: 剧集列表中紧随本集且确定已播出的一集. 没有时为 `null`. 与上游规则相同.
     */
    @Throws(Exception::class)
    suspend fun nextEpisode(): AniEpisode? {
        val subject = infoBundle.first().subjectCollectionInfo
        return subject.episodes
            .findNeighborEpisode(episodeId, offset = 1)
            ?.takeIf { with(EpisodeCompletionContext) { it.episodeInfo.isKnownCompleted(subject.recurrence) } }
            ?.toAniEpisode()
    }

    /**
     * 缓存当前选中的资源. 已有同一资源同一集的缓存时直接返回.
     *
     * @throws AniPlaybackException 没有选中资源时.
     */
    @Throws(Exception::class)
    suspend fun downloadSelected() {
        val media = fetchSelect.filterNotNull().first().mediaSelector.selected.value
            ?: throw AniPlaybackException(AniPlaybackException.REASON_NOTHING_SELECTED, "No media selected")
        val info = infoBundle.first()
        addDownload(
            subject = info.subjectInfo,
            episode = info.episodeInfo,
            media = media,
            metadata = MediaCacheMetadata(MediaFetchRequest.create(info.subjectInfo, info.episodeInfo)),
            splitSeason = info.seriesInfo.splitSeason,
        )
    }

    /**
     * 从所有弹幕源获取本集弹幕, 按时间升序. 已按用户设置做简繁转换并应用正则屏蔽词.
     */
    @Throws(Exception::class)
    suspend fun fetchDanmaku(): List<AniDanmaku> {
        val request = infoBundle.first().toDanmakuFetchRequest()
        val results = danmakuRepository.fetchFromAllRemotes(request).first()
        val textConversion = DanmakuTextConversionSettings(
            global = settingsRepository.danmakuConfig.flow.first().textConversion,
            overrides = settingsRepository.danmakuTextConversionOverrides.flow.first()
                .overrides.mapKeys { DanmakuServiceId(it.key) },
        )
        return danmakuProcessor.process(results, textConversion, getDanmakuRegexFilterList().first())
            .map { it.toAniDanmaku() }
    }

    /**
     * 结束会话: 停止查询, 释放解析占用的资源. 之后不再回调.
     */
    fun close() {
        releaseResolved()
        scope.cancel()
    }

    private fun Media.toCandidate(): AniMediaCandidate = toAniMediaCandidate(playable = mediaResolver.supports(this))

    private fun <T> observe(flow: Flow<T>, onValue: (T) -> Unit): AniSubscription =
        scope.launchObserver(callbackContext, flow, onValue = onValue)
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

private fun MediaFetchSelectBundle.sourceStatusFlow(): Flow<List<AniMediaSourceStatus>> {
    val results = mediaFetchSession.mediaSourceResults
    if (results.isEmpty()) return flowOf(emptyList())
    return combine(
        combine(results.map { it.state }) { it.toList() },
        mediaFetchSession.cumulativeResults,
    ) { states, media ->
        val counts = media.groupingBy { it.mediaSourceId }.eachCount()
        results.zip(states) { result, state ->
            AniMediaSourceStatus(
                instanceId = result.instanceId,
                mediaSourceId = result.mediaSourceId,
                displayName = result.sourceInfo.displayName,
                kind = result.kind.name,
                state = state.toAniStateName(),
                resultCount = counts[result.mediaSourceId] ?: 0,
            )
        }
    }
}

private fun MediaPreferenceItem<String>.toAniPreference(key: String): Flow<AniPreference> =
    combine(available, finalSelected) { available, selected ->
        AniPreference(key = key, available = available, selected = selected)
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

interface AniSourcesListener {
    fun onSources(sources: List<AniMediaSourceStatus>)
}

interface AniPreferencesListener {
    fun onPreferences(preferences: List<AniPreference>)
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
