/*
 * Copyright (C) 2026 OpenAni and contributors.
 * Use of this source code is governed by the GNU AGPLv3 license.
 */

package me.him188.ani.app.ui.foundation.theme

import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class IosDesignSystemTest {
    @Test
    fun `light and dark content meet normal text contrast on grouped surfaces`() {
        for (dark in listOf(false, true)) {
            val scheme = iosColorScheme(if (dark) darkColorScheme() else lightColorScheme(), dark, false)
            for (surface in listOf(scheme.background, scheme.surface, scheme.surfaceContainerHigh)) {
                assertTrue(contrast(scheme.onSurface, surface) >= 4.5)
                assertTrue(contrast(scheme.onSurfaceVariant, surface) >= 4.5)
            }
        }
    }

    @Test
    fun `user accent survives neutral surface styling`() {
        val accent = Color(0xFF007AFF)
        val scheme = iosColorScheme(lightColorScheme(primary = accent), isDark = false, useBlackBackground = false)
        assertEquals(accent, scheme.primary)
    }

    @Test
    fun `pure black preference applies only to dark mode`() {
        assertEquals(Color.Black, iosColorScheme(darkColorScheme(), true, true).background)
        assertEquals(Color(0xFFF2F2F7), iosColorScheme(lightColorScheme(), false, true).background)
    }

    private fun contrast(a: Color, b: Color): Float =
        (maxOf(a.luminance(), b.luminance()) + 0.05f) / (minOf(a.luminance(), b.luminance()) + 0.05f)
}
