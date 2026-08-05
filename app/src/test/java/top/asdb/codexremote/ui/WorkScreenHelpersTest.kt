package top.asdb.codexremote.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import top.asdb.codexremote.data.ApiModelOption
import top.asdb.codexremote.data.ThreadGoalStatus

class WorkScreenHelpersTest {
    @Test
    fun onlyActiveGoalRequiresPauseConfirmation() {
        assertTrue(shouldConfirmGoalPause(ThreadGoalStatus.Active))
        assertFalse(shouldConfirmGoalPause(ThreadGoalStatus.Paused))
        assertFalse(shouldConfirmGoalPause(ThreadGoalStatus.Complete))
        assertFalse(shouldConfirmGoalPause(null))
    }

    @Test
    fun bottomOverscrollKeepsFollowingAndHidesJumpButton() {
        val followOutput = updatedFollowOutput(
            current = false,
            userDragging = true,
            canScrollForward = false,
        )

        assertTrue(followOutput)
        assertFalse(
            shouldShowJumpToLatest(
                followOutput = followOutput,
                canScrollForward = false,
                hasTimeline = true,
            ),
        )
    }

    @Test
    fun draggingAwayFromBottomPausesFollowingAndShowsJumpButton() {
        val followOutput = updatedFollowOutput(
            current = true,
            userDragging = true,
            canScrollForward = true,
        )

        assertFalse(followOutput)
        assertTrue(
            shouldShowJumpToLatest(
                followOutput = followOutput,
                canScrollForward = true,
                hasTimeline = true,
            ),
        )
        assertFalse(updatedFollowOutput(followOutput, userDragging = false, canScrollForward = true))
    }

    @Test
    fun formatsTurnElapsedWithCompactUnits() {
        val startedAtMillis = 1_700_000_000_000L

        assertEquals("0s", formatTurnElapsed(startedAtMillis, startedAtMillis + 999L))
        assertEquals("59s", formatTurnElapsed(startedAtMillis, startedAtMillis + 59_999L))
        assertEquals("1m 0s", formatTurnElapsed(startedAtMillis, startedAtMillis + 60_000L))
        assertEquals("1m 1s", formatTurnElapsed(startedAtMillis, startedAtMillis + 61_000L))
        assertEquals("1h 0m 0s", formatTurnElapsed(startedAtMillis, startedAtMillis + 3_600_000L))
        assertEquals("1h 2m 3s", formatTurnElapsed(startedAtMillis, startedAtMillis + 3_723_000L))
    }

    @Test
    fun filtersApiModelsByIdOrDisplayName() {
        val models = listOf(
            ApiModelOption(modelId = "custom-api/gpt-5", displayName = "GPT 5"),
            ApiModelOption(modelId = "anthropic/claude-sonnet", displayName = "Claude Sonnet"),
        )

        assertEquals(listOf(models[0]), filterApiModelOptions(models, "GPT"))
        assertEquals(listOf(models[1]), filterApiModelOptions(models, "anthropic"))
        assertTrue(filterApiModelOptions(models, "missing").isEmpty())
    }

    @Test
    fun selectingApiModelFillsAvailableMetadataWithoutOverwritingManualValues() {
        val selected = applyApiModelOption(
            option = ApiModelOption(
                modelId = "custom-api/gpt-5",
                displayName = "GPT 5",
                contextWindowTokens = 200_000,
                maxOutputTokens = 32_000,
            ),
            currentDisplayName = "",
            currentContextWindow = "1000",
            currentMaxOutput = "2000",
        )

        assertEquals("custom-api/gpt-5", selected.modelId)
        assertEquals("GPT 5", selected.displayName)
        assertEquals("200000", selected.contextWindow)
        assertEquals("32000", selected.maxOutput)

        val incomplete = applyApiModelOption(
            option = ApiModelOption(modelId = "custom-api/plain"),
            currentDisplayName = "手动名称",
            currentContextWindow = "4096",
            currentMaxOutput = "1024",
        )
        assertEquals("手动名称", incomplete.displayName)
        assertEquals("4096", incomplete.contextWindow)
        assertEquals("1024", incomplete.maxOutput)
    }
}
