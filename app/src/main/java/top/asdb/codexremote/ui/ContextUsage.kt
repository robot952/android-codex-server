package top.asdb.codexremote.ui

import top.asdb.codexremote.data.TokenUsage

/** Mirrors the Codex VS Code client: the latest request, not the cumulative total, fills the ring. */
internal fun contextUsageFraction(usage: TokenUsage?): Float? {
    val window = usage?.modelContextWindow ?: return null
    val used = usage.last.totalTokens
    if (window <= 0L || used < 0L) return null
    val fraction = used.coerceAtMost(window).toDouble() / window.toDouble()
    return fraction.takeIf(Double::isFinite)?.toFloat()
}
