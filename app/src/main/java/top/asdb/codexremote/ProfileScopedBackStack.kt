package top.asdb.codexremote

import java.util.ArrayDeque

/** Small in-memory back stack that keeps independent navigation chains for each SSH profile. */
internal class ProfileScopedBackStack<T> {
    private val frames = mutableMapOf<String, ArrayDeque<T>>()

    fun push(profileId: String, frame: T) {
        if (profileId.isBlank()) return
        frames.getOrPut(profileId) { ArrayDeque<T>() }.addLast(frame)
    }

    fun peek(profileId: String): T? = frames[profileId]?.peekLast()

    fun pop(profileId: String): T? {
        val stack = frames[profileId] ?: return null
        val frame = stack.pollLast()
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

    fun clear(profileId: String) {
        frames.remove(profileId)
    }

    fun size(profileId: String): Int = frames[profileId]?.size ?: 0
}
