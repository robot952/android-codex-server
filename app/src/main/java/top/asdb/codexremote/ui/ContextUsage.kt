package top.asdb.codexremote.ui

import top.asdb.codexremote.data.TokenUsage

/** Server-reported usage for the current context window, not the cumulative thread total. */
internal data class ContextUsageSummary(
    val usedTokens: Long,
    val windowTokens: Long,
    val fraction: Float,
) {
    val remainingTokens: Long get() = (windowTokens - usedTokens).coerceAtLeast(0L)
    val usedPercent: Int get() = (fraction * 100).toInt().coerceIn(0, 100)
    val remainingPercent: Int get() = 100 - usedPercent
}

/** Mirrors the Codex VS Code client: the latest request, not the cumulative total, fills the ring. */
internal fun contextUsageFraction(usage: TokenUsage?): Float? {
    return contextUsageSummary(usage)?.fraction
}

internal fun contextUsageSummary(usage: TokenUsage?): ContextUsageSummary? {
    val window = usage?.modelContextWindow ?: return null
    val used = usage.last.totalTokens
    if (window <= 0L || used < 0L) return null
    val boundedUsed = used.coerceAtMost(window)
    val fraction = boundedUsed.toDouble() / window.toDouble()
    val safeFraction = fraction.takeIf(Double::isFinite)?.toFloat() ?: return null
    return ContextUsageSummary(
        usedTokens = boundedUsed,
        windowTokens = window,
        fraction = safeFraction,
    )
}

/** Compact token count for the context popover, for example 129k or 1.2m. */
internal fun formatContextTokenCount(tokens: Long): String {
    val safeTokens = tokens.coerceAtLeast(0)
    return when {
        safeTokens >= 1_000_000L -> formatContextTokenScale(safeTokens, 1_000_000L, "m")
        safeTokens >= 1_000L -> formatContextTokenScale(safeTokens, 1_000L, "k")
        else -> safeTokens.toString()
    }
}

private fun formatContextTokenScale(tokens: Long, scale: Long, suffix: String): String {
    val whole = tokens / scale
    val decimal = (tokens % scale) / (scale / 10L)
    return if (whole >= 100L || decimal == 0L) "$whole$suffix" else "$whole.$decimal$suffix"
}
