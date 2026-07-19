package top.asdb.codexremote.codex

/**
 * Invalidates late UI callbacks without cancelling useful work on other server profiles.
 * Exclusive lanes additionally ensure that only the latest operation of that kind can publish.
 */
internal class ProfileOperationTracker {
    data class Ticket internal constructor(
        val profileId: String,
        val lane: String,
        internal val profileEpoch: Long,
        internal val token: Long,
        internal val exclusive: Boolean,
    )

    private val profileEpochs = mutableMapOf<String, Long>()
    private val latestTokens = mutableMapOf<Pair<String, String>, Long>()
    private var nextToken = 0L

    @Synchronized
    fun begin(profileId: String, lane: String, exclusive: Boolean = true): Ticket {
        val token = ++nextToken
        val ticket = Ticket(
            profileId = profileId,
            lane = lane,
            profileEpoch = profileEpochs[profileId] ?: 0L,
            token = token,
            exclusive = exclusive,
        )
        if (exclusive) latestTokens[profileId to lane] = token
        return ticket
    }

    @Synchronized
    fun isCurrent(ticket: Ticket): Boolean {
        if ((profileEpochs[ticket.profileId] ?: 0L) != ticket.profileEpoch) return false
        return !ticket.exclusive || latestTokens[ticket.profileId to ticket.lane] == ticket.token
    }

    @Synchronized
    fun finish(ticket: Ticket) {
        if (ticket.exclusive) latestTokens.remove(ticket.profileId to ticket.lane, ticket.token)
    }

    @Synchronized
    fun invalidateLane(profileId: String, lane: String) {
        latestTokens.remove(profileId to lane)
    }

    @Synchronized
    fun invalidateProfile(profileId: String) {
        profileEpochs[profileId] = (profileEpochs[profileId] ?: 0L) + 1L
        latestTokens.keys.removeAll { it.first == profileId }
    }
}
