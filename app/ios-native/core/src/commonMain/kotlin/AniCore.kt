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
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import me.him188.ani.app.data.network.AniApiProvider
import me.him188.ani.app.data.network.AniSubjectSearchService
import me.him188.ani.app.data.repository.episode.EpisodeCollectionRepository
import me.him188.ani.app.data.repository.episode.setEpisodeWatched
import me.him188.ani.app.data.repository.subject.SetSubjectCollectionTypeOrDeleteUseCase
import me.him188.ani.app.data.repository.subject.SubjectCollectionRepository
import me.him188.ani.app.data.repository.user.UserRepository
import me.him188.ani.app.domain.session.SessionManager
import me.him188.ani.app.domain.session.SessionState
import me.him188.ani.app.domain.session.SessionStateProvider
import me.him188.ani.app.domain.session.auth.BangumiOAuthClient
import me.him188.ani.app.domain.session.auth.OAuthConfigurator
import org.koin.core.Koin
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.cancellation.CancellationException

/**
 * SwiftUI 客户端访问 Animeko 数据层的唯一入口.
 *
 * Swift 只调用本类与 [AniEpisodeSession] 的公开方法, 不直接接触 app-data. 所有 `suspend` 方法在 Swift 中是 `async throws`;
 * 所有 `observe*` 方法的回调在 [callbackContext] (iOS 上为主线程) 上触发, 返回的 [AniSubscription] 用于取消.
 *
 * 实例由平台入口创建 (iOS: `AniCoreStarterKt.startAniCore()`), 整个进程只有一个.
 */
class AniCore internal constructor(
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
            .map { it.subjectInfo.toAniSubject() }
    }

    /**
     * 读取一次条目与其全部剧集. 登录后剧集带有观看状态.
     */
    @Throws(Exception::class)
    suspend fun subjectDetail(subjectId: Int): AniSubjectDetail {
        return subjectCollectionRepository.subjectCollectionFlow(subjectId).first().toAniSubjectDetail()
    }

    /**
     * 观察条目详情. 修改收藏或剧集观看状态后会再次回调.
     */
    fun observeSubjectDetail(subjectId: Int, listener: AniSubjectDetailListener): AniSubscription =
        scope.launchObserver(
            callbackContext,
            subjectCollectionRepository.subjectCollectionFlow(subjectId).map { it.toAniSubjectDetail() },
            onError = { listener.onError(it.message ?: it.toString()) },
        ) { listener.onDetail(it) }

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
     * 观察本地缓存中最近更新的收藏. [type] 为 `null` 时包含所有类型. 用 [refreshCollections] 从服务器更新缓存.
     */
    fun observeCollections(type: AniCollectionType?, limit: Int, listener: AniCollectionsListener): AniSubscription =
        scope.launchObserver(
            callbackContext,
            subjectCollectionRepository
                .mostRecentlyUpdatedSubjectCollectionsFlow(limit, types = type?.let { listOf(it.toUnified()) })
                .map { list -> list.map { it.toAniCollectionItem() } },
            onError = { listener.onError(it.message ?: it.toString()) },
        ) { listener.onCollections(it) }

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
     * 观察登录状态. 启动后若需要刷新 token, 首次回调会在刷新完成后到达.
     */
    fun observeSession(listener: AniSessionListener): AniSubscription = scope.launchObserver(
        callbackContext,
        combine(sessionStateProvider.stateFlow, userRepository.selfInfoFlow) { state, self ->
            AniSession(
                loggedIn = state is SessionState.Valid,
                bangumiConnected = (state as? SessionState.Valid)?.bangumiConnected == true,
                nickname = self?.nickname.orEmpty(),
                avatarUrl = self?.avatarUrl.orEmpty(),
            )
        },
    ) { listener.onSession(it) }

    /**
     * 使用 Bangumi 授权登录. 未登录时会注册或登录 Ani 账号, 已登录时为当前账号绑定 Bangumi.
     *
     * 流程: [AniLoginListener.onOpenUrl] 要求打开授权页 (Swift 用 `ASWebAuthenticationSession` 或系统浏览器),
     * 用户在网页完成授权后, 本方法轮询到结果并回调 [AniLoginListener.onFinished]. 取消返回的订阅即放弃登录.
     */
    fun startBangumiLogin(listener: AniLoginListener): AniSubscription {
        // ATOMIC: 即使立即取消, 也会进入函数体并通过 onFinished 报告取消
        val job: Job = scope.launch(start = CoroutineStart.ATOMIC) {
            val configurator = OAuthConfigurator(
                client = BangumiOAuthClient(koin.get<AniApiProvider>().bangumiApi, sessionStateProvider),
                sessionManager = sessionManager,
                sessionStateProvider = sessionStateProvider,
            )
            val result = try {
                val isRegister = sessionStateProvider.stateFlow.first() !is SessionState.Valid
                configurator.auth(isRegister) { url ->
                    withContext(callbackContext) { listener.onOpenUrl(url) }
                }
            } catch (e: CancellationException) {
                // 取消时也要通知, 否则 Swift 侧的等待永远不会结束
                withContext(NonCancellable + callbackContext) {
                    listener.onFinished(success = false, errorMessage = "Cancelled")
                }
                throw e
            }
            withContext(callbackContext) {
                when (result) {
                    is OAuthConfigurator.State.Success -> listener.onFinished(success = true, errorMessage = null)
                    is OAuthConfigurator.State.Failed -> listener.onFinished(
                        success = false,
                        errorMessage = result.error::class.simpleName,
                    )

                    else -> listener.onFinished(success = false, errorMessage = null)
                }
            }
        }
        return AniSubscription(job)
    }

    /**
     * 退出登录, 清除本地账号信息.
     */
    @Throws(Exception::class)
    suspend fun logout() {
        userRepository.clearSelfInfo()
    }

    // endregion

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

/**
 * 一次 `observe*` 订阅. 调用 [cancel] 后不再回调.
 */
class AniSubscription internal constructor(private val job: Job) {
    fun cancel() {
        job.cancel(CancellationException("AniSubscription cancelled"))
    }
}

interface AniSubjectDetailListener {
    fun onDetail(detail: AniSubjectDetail)
    fun onError(message: String)
}

interface AniCollectionsListener {
    fun onCollections(items: List<AniCollectionItem>)
    fun onError(message: String)
}

interface AniSessionListener {
    fun onSession(session: AniSession)
}

interface AniLoginListener {
    /** 打开授权页. */
    fun onOpenUrl(url: String)

    /**
     * 登录结束, 每次登录恰好回调一次. 失败时 [errorMessage] 是错误类型名 (如 `NetworkError`), 取消时为 `Cancelled`,
     * 可能为 `null`.
     */
    fun onFinished(success: Boolean, errorMessage: String?)
}
