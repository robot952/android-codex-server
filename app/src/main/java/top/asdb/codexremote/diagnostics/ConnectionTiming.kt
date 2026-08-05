package top.asdb.codexremote.diagnostics

internal fun recordConnectionTiming(
    profileId: String,
    agent: String,
    stage: String,
    startedNanos: Long,
    status: String = "success",
    detail: String = "",
) {
    val elapsedMs = (System.nanoTime() - startedNanos).coerceAtLeast(0L) / 1_000_000L
    DiagnosticLogger.info(
        "ConnectionTiming",
        formatConnectionTiming(profileId, agent, stage, elapsedMs, status, detail),
    )
}

internal fun formatConnectionTiming(
    profileId: String,
    agent: String,
    stage: String,
    elapsedMs: Long,
    status: String = "success",
    detail: String = "",
): String = buildString {
    append("profile=").append(profileId.take(8).ifBlank { "unknown" })
    append(" agent=").append(agent)
    append(" stage=").append(stage)
    append(" elapsed_ms=").append(elapsedMs.coerceAtLeast(0L))
    append(" status=").append(status)
    detail.replace(Regex("\\s+"), " ").trim().takeIf(String::isNotBlank)?.let {
        append(" detail=").append(it.take(MAX_CONNECTION_TIMING_DETAIL_CHARS))
    }
}

private const val MAX_CONNECTION_TIMING_DETAIL_CHARS = 160
