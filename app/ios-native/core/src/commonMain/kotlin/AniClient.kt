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
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.datetime.TimeZone
import kotlinx.datetime.todayIn
import me.him188.ani.app.data.network.AniApiProvider
import me.him188.ani.app.data.network.AniEpisodeCommentService
import me.him188.ani.app.data.network.BangumiCommentService
import me.him188.ani.app.data.network.TrendsRepository
import me.him188.ani.app.data.network.toEpisodeComment
import me.him188.ani.app.data.network.AniSubjectSearchService
import me.him188.ani.app.data.repository.episode.EpisodeCollectionRepository
import me.him188.ani.app.data.repository.episode.setEpisodeWatched
import me.him188.ani.app.data.repository.subject.SetSubjectCollectionTypeOrDeleteUseCase
import me.him188.ani.app.data.repository.subject.SubjectCollectionRepository
import me.him188.ani.app.data.repository.user.UserRepository
import me.him188.ani.app.domain.episode.GetAnimeScheduleFlowUseCase
import me.him188.ani.app.domain.episode.GetSubjectRecommendationUseCase
import me.him188.ani.app.domain.session.SessionManager
import me.him188.ani.app.domain.session.SessionState
import me.him188.ani.app.domain.session.SessionStateProvider
import me.him188.ani.app.domain.session.auth.BangumiOAuthClient
import me.him188.ani.app.domain.session.auth.OAuthConfigurator
import org.koin.core.Koin
import kotlin.coroutines.CoroutineContext
import kotlin.time.Clock

/**
 * SwiftUI 客户端访问 Animeko 数据层的唯一入口.
 *
 * Swift 只调用本类与 [AniEpisodeSession] 的公开方法, 不直接接触 app-data. 桥接由 SKIE 完成: `suspend` 方法在 Swift 中是
 * `async throws`, 返回 `Flow` 的 `*Updates` 在 Swift 中可以 `for await`, 取消所在的 Task 即停止收集.
 *
 * 实例由平台入口创建 (iOS: `AniCoreStarterKt.startAniCore()`), 整个进程只有一个.
 */
class AniClient internal constructor(
    private val koin: Koin,
    private val scope: CoroutineScope,
    private val callbackContext: CoroutineContext,
) {
    private val searchService: AniSubjectSearchService by lazy { koin.get() }
    private val subjectCollectionRepository: SubjectCollectionRepository by lazy { koin.get() }
    private val episodeCollectionRepository: EpisodeCollectionRepository by lazy { koin.get() }
    private val setSubjectCollectionType: SetSubjectCollectionTypeOrDeleteUseCase by lazy { koin.get() }
    private val sessionStateProvider: SessionStateProvider by lazy { koin.get() }
    private val sessionManager: SessionManager by lazy { koin.get() }
    private val userRepository: UserRepository by lazy { koin.get() }
    private val trendsRepository: TrendsRepository by lazy { koin.get() }
    private val getAnimeSchedule: GetAnimeScheduleFlowUseCase by lazy { koin.get() }
    private val getSubjectRecommendation: GetSubjectRecommendationUseCase by lazy { koin.get() }
    private val episodeCommentService: AniEpisodeCommentService by lazy { koin.get() }
    private val subjectCommentService: BangumiCommentService by lazy { koin.get() }

    // region 搜索与条目

    /**
     * 按关键词搜索 Bangumi 条目. 结果包含 NSFW 条目, 由调用方决定是否展示.
     *
     * @param offset 分页偏移, 从 0 开始.
     * @param limit 每页数量, Bangumi 最多返回 20 条.
     */
    @Throws(Exception::class)
    suspend fun searchSubjects(keyword: String, offset: Int, limit: Int): List<AniSubject> {
        return searchService.searchSubjects(keyword, offset = offset, limit = limit)
            .map { it.subjectInfo.toAniSubject(mainEpisodeCount = it.mainEpisodeCount) }
    }

    /**
     * 读取一次条目与其全部剧集. 登录后剧集带有观看状态.
     */
    @Throws(Exception::class)
    suspend fun subjectDetail(subjectId: Int): AniSubjectDetail {
        return subjectCollectionRepository.subjectCollectionFlow(subjectId).first().toAniSubjectDetail()
    }

    /**
     * 条目详情. 修改收藏或剧集观看状态后会再次发出. 失败时发出一个带 [AniSubjectDetailUpdate.error] 的值后结束.
     */
    fun subjectDetailUpdates(subjectId: Int): Flow<AniSubjectDetailUpdate> =
        subjectCollectionRepository.subjectCollectionFlow(subjectId).forSwift(
            onValue = { AniSubjectDetailUpdate(it.toAniSubjectDetail(), null) },
            onError = { AniSubjectDetailUpdate(null, it) },
        )

    /**
     * 修改条目收藏状态. [AniCollectionType.NOT_COLLECTED] 表示取消收藏. 需要登录.
     */
    @Throws(Exception::class)
    suspend fun setSubjectCollectionType(subjectId: Int, type: AniCollectionType) {
        setSubjectCollectionType.invoke(
            subjectId,
            type.takeUnless { it == AniCollectionType.NOT_COLLECTED }?.toUnified(),
        )
    }

    /**
     * 标记剧集看过或取消. 未登录时只写本地.
     */
    @Throws(Exception::class)
    suspend fun setEpisodeWatched(subjectId: Int, episodeId: Int, watched: Boolean) {
        episodeCollectionRepository.setEpisodeWatched(subjectId, episodeId, watched)
    }

    // endregion

    // region 收藏

    /**
     * 本地缓存中最近更新的收藏. [type] 为 `null` 时包含所有类型. 用 [refreshCollections] 从服务器更新缓存.
     */
    fun collectionUpdates(type: AniCollectionType?, limit: Int): Flow<AniCollectionsUpdate> =
        subjectCollectionRepository
            .mostRecentlyUpdatedSubjectCollectionsFlow(limit, types = type?.let { listOf(it.toUnified()) })
            .forSwift(
                onValue = { list -> AniCollectionsUpdate(list.map { it.toAniCollectionItem() }, null) },
                onError = { AniCollectionsUpdate(null, it) },
            )

    /**
     * 从服务器拉取最近更新的收藏到本地缓存. 需要登录并绑定 Bangumi.
     */
    @Throws(Exception::class)
    suspend fun refreshCollections(type: AniCollectionType?, limit: Int) {
        subjectCollectionRepository.updateRecentlyUpdatedSubjectCollections(limit, type?.toUnified())
    }

    // endregion

    // region 账号

    /**
     * 登录状态. 启动后若需要刷新 token, 第一个值在刷新完成后到达.
     */
    val sessionUpdates: Flow<AniSession>
        get() = combine(sessionStateProvider.stateFlow, userRepository.selfInfoFlow) { state, self ->
            AniSession(
                loggedIn = state is SessionState.Valid,
                bangumiConnected = (state as? SessionState.Valid)?.bangumiConnected == true,
                nickname = self?.nickname.orEmpty(),
                avatarUrl = self?.avatarUrl.orEmpty(),
            )
        }.forSwift()

    /**
     * 使用 Bangumi 授权登录. 未登录时会注册或登录 Ani 账号, 已登录时为当前账号绑定 Bangumi.
     *
     * 先发出带 [AniLoginEvent.openUrl] 的事件要求打开授权页; 用户在网页完成授权后, 轮询到结果并发出
     * [AniLoginEvent.finished] 为 `true` 的事件后结束. 停止收集即放弃登录.
     */
    fun bangumiLogin(): Flow<AniLoginEvent> = channelFlow {
        val configurator = OAuthConfigurator(
            client = BangumiOAuthClient(koin.get<AniApiProvider>().bangumiApi, sessionStateProvider),
            sessionManager = sessionManager,
            sessionStateProvider = sessionStateProvider,
        )
        val isRegister = sessionStateProvider.stateFlow.first() !is SessionState.Valid
        val result = configurator.auth(isRegister) { url -> send(AniLoginEvent.openUrl(url)) }
        send(
            when (result) {
                is OAuthConfigurator.State.Success -> AniLoginEvent.finished(success = true, error = null)
                is OAuthConfigurator.State.Failed -> AniLoginEvent.finished(false, result.error::class.simpleName)
                else -> AniLoginEvent.finished(success = false, error = null)
            },
        )
    }.catch { emit(AniLoginEvent.finished(false, it::class.simpleName)) }

    /**
     * 退出登录, 清除本地账号信息.
     */
    @Throws(Exception::class)
    suspend fun logout() {
        userRepository.clearSelfInfo()
    }

    // endregion

    // region 探索

    /**
     * 条目的相关推荐.
     */
    @Throws(Exception::class)
    suspend fun subjectRecommendations(subjectId: Int): List<AniRecommendation> {
        return getSubjectRecommendation(subjectId).map { it.toAniRecommendation() }
    }

    /**
     * 热门条目 (Ani 服务器统计).
     */
    @Throws(Exception::class)
    suspend fun trendingSubjects(): List<AniSubject> {
        return trendsRepository.getTrendsInfo().subjects.map { it.toAniSubject() }
    }

    /**
     * 以今天为中心前后 7 天的放送时间表 (用户所在时区). 跨过午夜后不会自动刷新, 需要重新收集.
     */
    fun scheduleUpdates(): Flow<AniScheduleUpdate> {
        val timeZone = TimeZone.currentSystemDefault()
        val today = Clock.System.todayIn(timeZone)
        return getAnimeSchedule(today, timeZone).forSwift(
            onValue = { days -> AniScheduleUpdate(days.map { it.toAniScheduleDay() }, null) },
            onError = { AniScheduleUpdate(null, it) },
        )
    }

    // endregion

    // region 评论

    /**
     * 剧集评论 (Ani 与 Bangumi 合并). 第一页 [cursor] 传 `null`.
     */
    @Throws(Exception::class)
    suspend fun episodeComments(episodeId: Int, cursor: String?, limit: Int): AniCommentPage {
        val response = episodeCommentService.listEpisodeComments(episodeId.toLong(), after = cursor, limit = limit)
        return AniCommentPage(
            items = response.items.map { it.toEpisodeComment().toAniComment() },
            nextCursor = response.nextCursor,
        )
    }

    /**
     * 条目评价. 第一页 [cursor] 传 `null`, 之后传上一页的 [AniCommentPage.nextCursor].
     */
    @Throws(Exception::class)
    suspend fun subjectReviews(subjectId: Int, cursor: String?, limit: Int): AniCommentPage {
        val offset = cursor?.toIntOrNull() ?: 0
        val paged = subjectCommentService.getSubjectComments(subjectId, offset, limit)
            ?: return AniCommentPage(emptyList(), null)
        return AniCommentPage(
            items = paged.page.map { it.toAniComment() },
            nextCursor = if (paged.hasMore) (offset + paged.page.size).toString() else null,
        )
    }

    /**
     * 发表剧集评论. [text] 按 BBCode 发送. 需要登录.
     */
    @Throws(Exception::class)
    suspend fun postEpisodeComment(episodeId: Int, text: String) {
        episodeCommentService.createEpisodeComment(episodeId.toLong(), text)
    }

    // endregion

    /** 设置项. */
    val settings: AniSettingsStore by lazy { AniSettingsStore(koin, scope, callbackContext) }

    /** 一起看. */
    val watchTogether: AniWatchTogether by lazy { AniWatchTogether(koin, scope, callbackContext) }

    /** 缓存 (下载) 管理. */
    val downloads: AniDownloads by lazy { AniDownloads(koin, scope, callbackContext) }

    /**
     * 为一集创建播放会话. 会话立即开始查询全部启用的数据源; 不再使用时调用 [AniEpisodeSession.close].
     */
    fun openEpisode(subjectId: Int, episodeId: Int): AniEpisodeSession {
        return AniEpisodeSession(
            koin = koin,
            parentScope = scope,
            callbackContext = callbackContext,
            subjectId = subjectId,
            episodeId = episodeId,
        )
    }
}

/** 条目详情的一次更新: [detail] 与 [error] 恰有一个非空. */
data class AniSubjectDetailUpdate(val detail: AniSubjectDetail?, val error: String?)

/** 收藏列表的一次更新: [items] 与 [error] 恰有一个非空. */
data class AniCollectionsUpdate(val items: List<AniCollectionItem>?, val error: String?)

/** 时间表的一次更新: [days] 与 [error] 恰有一个非空. */
data class AniScheduleUpdate(val days: List<AniScheduleDay>?, val error: String?)

/**
 * 登录过程中的事件. [openUrl] 非空时要求打开授权页; [finished] 为 `true` 时登录结束,
 * 失败时 [error] 是错误类型名 (如 `NetworkError`), 可能为 `null`.
 */
data class AniLoginEvent(
    val openUrl: String?,
    val finished: Boolean,
    val success: Boolean,
    val error: String?,
) {
    internal companion object {
        fun openUrl(url: String) = AniLoginEvent(url, finished = false, success = false, error = null)
        fun finished(success: Boolean, error: String?) = AniLoginEvent(null, finished = true, success, error)
    }
}
