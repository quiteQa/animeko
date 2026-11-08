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
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.first
import me.him188.ani.app.data.network.AniSubjectSearchService
import me.him188.ani.app.data.repository.subject.SubjectCollectionRepository
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
     * 读取条目与其全部剧集. 登录后剧集带有观看状态.
     */
    @Throws(Exception::class)
    suspend fun subjectDetail(subjectId: Int): AniSubjectDetail {
        val collection = subjectCollectionRepository.subjectCollectionFlow(subjectId).first()
        return AniSubjectDetail(
            subject = collection.subjectInfo.toAniSubject(),
            episodes = collection.episodes.map { it.toAniEpisode() },
        )
    }

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
