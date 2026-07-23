package top.asdb.codexremote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import top.asdb.codexremote.data.TimelineEntry
import top.asdb.codexremote.data.TimelineKind
import top.asdb.codexremote.ui.SubAgentDisplayStatus
import top.asdb.codexremote.ui.TimelineRenderRow
import top.asdb.codexremote.ui.toSubAgentActivityGroupPresentation
import top.asdb.codexremote.ui.toSubAgentPresentations
import top.asdb.codexremote.ui.toTimelineRenderRows

class SubAgentPresentationTest {
    @Test
    fun groupsAdjacentAgentActivitiesFromTheSameTurn() {
        val rows = listOf(
            TimelineEntry("user", TimelineKind.UserMessage, turnId = "turn-1"),
            agent("agent-a", "thread-a", "turn-1", "started"),
            agent("agent-b", "thread-b", "turn-1", "started"),
            TimelineEntry("answer", TimelineKind.AgentMessage, turnId = "turn-1"),
            agent("agent-c", "thread-c", "turn-2", "started"),
        ).toTimelineRenderRows()

        assertEquals(4, rows.size)
        assertTrue(rows[0] is TimelineRenderRow.Entry)
        assertEquals(2, (rows[1] as TimelineRenderRow.SubAgents).entries.size)
        assertTrue(rows[2] is TimelineRenderRow.Entry)
        assertEquals(1, (rows[3] as TimelineRenderRow.SubAgents).entries.size)
    }

    @Test
    fun usesLeafPathNameAndDoesNotOpenEntriesWithoutThreadIds() {
        val agent = listOf(
            agent("agent", "", "turn", "started", path = "team/review-agent"),
        ).toSubAgentPresentations().single()

        assertEquals("review-agent", agent.name)
        assertFalse(agent.isOpenable)
    }

    @Test
    fun laterRunningActivityDoesNotRegressACompletedAgent() {
        val agent = listOf(
            agent("completed", "thread", "turn", "completed", activity = "completed"),
            agent("late", "thread", "turn", "running", activity = "started"),
        ).toSubAgentPresentations().single()

        assertEquals(SubAgentDisplayStatus.Completed, agent.status)
        assertEquals("已完成", agent.status.label)
    }

    @Test
    fun laterTurnCanReactivateACompletedAgent() {
        val agent = listOf(
            agent("completed", "thread", "turn-1", "completed", activity = "completed"),
            agent("resumed", "thread", "turn-2", "running", activity = "started"),
        ).toSubAgentPresentations().single()

        assertEquals(SubAgentDisplayStatus.Started, agent.status)
        assertEquals("已开始工作", agent.status.label)
    }

    @Test
    fun mapsStartedAndInteractionActivitiesToReferenceLabels() {
        val started = listOf(agent("started", "thread-a", "turn", "running", activity = "started"))
            .toSubAgentActivityGroupPresentation()
        val updated = listOf(agent("updated", "thread-b", "turn", "running", activity = "interacted"))
            .toSubAgentActivityGroupPresentation()

        assertEquals("已开始工作", started.statusLabel)
        assertEquals(SubAgentDisplayStatus.Started, started.status)
        assertTrue(started.isActive)
        assertEquals("已更新", updated.statusLabel)
        assertEquals(SubAgentDisplayStatus.Updated, updated.status)
        assertTrue(updated.isActive)
    }

    @Test
    fun failureWinsOverCompletedWhenAGroupHasMixedTerminalStates() {
        val group = listOf(
            agent("complete", "thread-a", "turn", "completed"),
            agent("failed", "thread-b", "turn", "failed"),
        ).toSubAgentActivityGroupPresentation()

        assertEquals("失败", group.statusLabel)
        assertEquals(SubAgentDisplayStatus.Failed, group.status)
        assertFalse(group.isActive)
    }

    @Test
    fun avatarColorStaysStableWhenAgentStatusChanges() {
        val running = listOf(agent("running", "shared-thread", "turn", "running"))
            .toSubAgentPresentations().single()
        val completed = listOf(agent("completed", "shared-thread", "turn", "completed"))
            .toSubAgentPresentations().single()

        assertEquals("shared-thread", running.avatarIdentityKey)
        assertEquals(running.avatarColorIndex(7), completed.avatarColorIndex(7))
    }

    @Test
    fun avatarFallsBackToPathWhenThreadIdIsUnavailable() {
        val running = listOf(
            agent("review", "", "turn", "running", path = "team/review-agent"),
        ).toSubAgentPresentations().single()
        val completed = listOf(
            agent("review-completed", "", "turn", "completed", path = "team/review-agent"),
        ).toSubAgentPresentations().single()

        assertEquals("team/review-agent", running.avatarIdentityKey)
        assertEquals(running.avatarColorIndex(7), completed.avatarColorIndex(7))
    }

    @Test
    fun avatarPaletteSpreadsSequentialThreadIdsAcrossPalette() {
        val colorIndexes = ('a'..'g').map { suffix ->
            listOf(agent("agent-$suffix", "thread-$suffix", "turn", "running"))
                .toSubAgentPresentations().single()
                .avatarColorIndex(7)
        }

        assertEquals(7, colorIndexes.toSet().size)
    }

    private fun agent(
        id: String,
        threadId: String,
        turnId: String,
        status: String,
        activity: String = status,
        path: String = "team/$id",
    ) = TimelineEntry(
        id = id,
        kind = TimelineKind.SubAgent,
        status = status,
        turnId = turnId,
        subAgentPath = path,
        subAgentThreadId = threadId,
        subAgentActivity = activity,
    )
}
