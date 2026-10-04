/*
 * Copyright (C) 2026 OpenAni and contributors.
 * Use of this source code is governed by the GNU AGPLv3 license.
 */

package me.him188.ani.app.ui.settings.framework.components

import androidx.compose.material3.Text
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.isToggleable
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.click
import androidx.compose.ui.test.performTouchInput
import me.him188.ani.app.ui.foundation.ProvideCompositionLocalsForPreview
import me.him188.ani.app.ui.framework.runAniComposeUiTest
import kotlin.test.Test
import kotlin.test.assertEquals

class SwitchItemTest {
    @Test
    fun `disabled setting cannot be changed from its row or switch`() = runAniComposeUiTest {
        var changes = 0
        val scope = object : SettingsScope() {}
        setContent {
            ProvideCompositionLocalsForPreview {
                scope.SwitchItem(
                    checked = false,
                    onCheckedChange = { changes++ },
                    enabled = false,
                    title = { Text("玻璃效果") },
                )
            }
        }
        onNodeWithText("玻璃效果").assertIsNotEnabled().performTouchInput { click() }
        onNode(isToggleable(), useUnmergedTree = true).assertIsNotEnabled().performTouchInput { click() }
        runOnIdle { assertEquals(0, changes) }
    }
}
