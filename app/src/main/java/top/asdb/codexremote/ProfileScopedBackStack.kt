package top.asdb.codexremote

import java.util.ArrayDeque

/** Small in-memory back stack that keeps independent navigation chains for each caller scope. */
internal class ProfileScopedBackStack<T> {
    private val frames = mutableMapOf<String, ArrayDeque<T>>()
    private val pendingPops = mutableMapOf<String, T>()

    fun push(scopeId: String, frame: T) {
        if (scopeId.isBlank()) return
        frames.getOrPut(scopeId) { ArrayDeque<T>() }.addLast(frame)
    }

    fun peek(scopeId: String): T? = frames[scopeId]?.peekLast()

    fun pop(scopeId: String): T? {
        val stack = frames[scopeId] ?: return null
        val frame = stack.pollLast()
        if (pendingPops[scopeId] === frame) pendingPops.remove(scopeId)
        if (stack.isEmpty()) frames.remove(scopeId)
        return frame
    }

    /** Removes a frame only when it is still the active top frame for that scope. */
    fun popIfTop(scopeId: String, expected: T): T? {
        val stack = frames[scopeId] ?: return null
        if (stack.peekLast() !== expected) return null
        return pop(scopeId)
    }

    /** Uses identity so a late async callback cannot match a newer, equal-valued frame. */
    fun isTop(scopeId: String, expected: T): Boolean = frames[scopeId]?.peekLast() === expected

    /**
     * Resuming a parent thread is asynchronous. Keep its frame on the stack until the resume
     * succeeds, while making repeated back presses idempotent during that transition.
     */
    fun beginPendingPop(scopeId: String): T? {
        if (scopeId.isBlank() || pendingPops.containsKey(scopeId)) return null
        return peek(scopeId)?.also { pendingPops[scopeId] = it }
    }

    /** Completes the pending transition only when the same frame is still on top. */
    fun completePendingPop(scopeId: String, expected: T): T? {
        if (pendingPops[scopeId] !== expected) return null
        pendingPops.remove(scopeId)
        return popIfTop(scopeId, expected)
    }

    /** Leaves the frame available for a retry after a parent resume failure. */
    fun cancelPendingPop(scopeId: String, expected: T): Boolean {
        if (pendingPops[scopeId] !== expected) return false
        pendingPops.remove(scopeId)
        return true
    }

    fun isPopPending(scopeId: String): Boolean = pendingPops.containsKey(scopeId)

    fun clear(scopeId: String) {
        frames.remove(scopeId)
        pendingPops.remove(scopeId)
    }

    fun size(scopeId: String): Int = frames[scopeId]?.size ?: 0
}
