package top.asdb.codexremote

import java.util.ArrayDeque

/** Small in-memory back stack that keeps independent navigation chains for each SSH profile. */
internal class ProfileScopedBackStack<T> {
    private val frames = mutableMapOf<String, ArrayDeque<T>>()
    private val pendingPops = mutableMapOf<String, T>()

    fun push(profileId: String, frame: T) {
        if (profileId.isBlank()) return
        frames.getOrPut(profileId) { ArrayDeque<T>() }.addLast(frame)
    }

    fun peek(profileId: String): T? = frames[profileId]?.peekLast()

    fun pop(profileId: String): T? {
        val stack = frames[profileId] ?: return null
        val frame = stack.pollLast()
        if (pendingPops[profileId] === frame) pendingPops.remove(profileId)
        if (stack.isEmpty()) frames.remove(profileId)
        return frame
    }

    /** Removes a frame only when it is still the active top frame for that profile. */
    fun popIfTop(profileId: String, expected: T): T? {
        val stack = frames[profileId] ?: return null
        if (stack.peekLast() !== expected) return null
        return pop(profileId)
    }

    /** Uses identity so a late async callback cannot match a newer, equal-valued frame. */
    fun isTop(profileId: String, expected: T): Boolean = frames[profileId]?.peekLast() === expected

    /**
     * Resuming a parent thread is asynchronous. Keep its frame on the stack until the resume
     * succeeds, while making repeated back presses idempotent during that transition.
     */
    fun beginPendingPop(profileId: String): T? {
        if (profileId.isBlank() || pendingPops.containsKey(profileId)) return null
        return peek(profileId)?.also { pendingPops[profileId] = it }
    }

    /** Completes the pending transition only when the same frame is still on top. */
    fun completePendingPop(profileId: String, expected: T): T? {
        if (pendingPops[profileId] !== expected) return null
        pendingPops.remove(profileId)
        return popIfTop(profileId, expected)
    }

    /** Leaves the frame available for a retry after a parent resume failure. */
    fun cancelPendingPop(profileId: String, expected: T): Boolean {
        if (pendingPops[profileId] !== expected) return false
        pendingPops.remove(profileId)
        return true
    }

    fun isPopPending(profileId: String): Boolean = pendingPops.containsKey(profileId)

    fun clear(profileId: String) {
        frames.remove(profileId)
        pendingPops.remove(profileId)
    }

    fun size(profileId: String): Int = frames[profileId]?.size ?: 0
}
