/*
 * Copyright (C) 2024-2025 OpenAni and contributors.
 *
 * 此源代码的使用受 GNU AFFERO GENERAL PUBLIC LICENSE version 3 许可证的约束, 可以在以下链接找到该许可证.
 * Use of this source code is governed by the GNU AGPLv3 license, which can be found at the following link.
 *
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.ui.foundation.animation

import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.unit.IntOffset

/**
 * @see AniMotionScheme
 */
@Stable
@Immutable
data class NavigationMotionScheme(
    val enterTransition: EnterTransition,
    val exitTransition: ExitTransition,
    val popEnterTransition: EnterTransition,
    val popExitTransition: ExitTransition,
) {
    companion object {
        inline val current
            @Composable get() = LocalNavigationMotionScheme.current

        fun calculate(useSlide: Boolean): NavigationMotionScheme {
            if (!useSlide) {
                return NavigationMotionScheme(
                    enterTransition = fadeIn(tween(180)),
                    exitTransition = fadeOut(tween(180)),
                    popEnterTransition = fadeIn(tween(180)),
                    popExitTransition = fadeOut(tween(180)),
                )
            }
            val animation = tween<IntOffset>(durationMillis = 350, easing = CubicBezierEasing(0.22f, 0.8f, 0.25f, 1f))
            val enterTransition = slideInHorizontally(animation, initialOffsetX = { it })
            val exitTransition = slideOutHorizontally(animation, targetOffsetX = { -it / 3 }) + fadeOut(tween(350))
            val popEnterTransition = slideInHorizontally(animation, initialOffsetX = { -it / 3 }) + fadeIn(tween(350))
            val popExitTransition = slideOutHorizontally(animation, targetOffsetX = { it })

            return NavigationMotionScheme(
                enterTransition = enterTransition,
                exitTransition = exitTransition,
                popEnterTransition = popEnterTransition,
                popExitTransition = popExitTransition,
            )
        }
    }
}

@Stable
val LocalNavigationMotionScheme = staticCompositionLocalOf<NavigationMotionScheme> {
    error("No LocalNavigationMotionScheme provided")
}
