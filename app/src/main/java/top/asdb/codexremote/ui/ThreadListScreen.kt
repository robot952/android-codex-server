package top.asdb.codexremote.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddComment
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import top.asdb.codexremote.data.AppUiState
import top.asdb.codexremote.data.AgentConnectionKey
import top.asdb.codexremote.data.AgentKind
import top.asdb.codexremote.data.CodexThread
import top.asdb.codexremote.data.ConnectionPhase
import top.asdb.codexremote.ssh.SshTerminalPhase
import top.asdb.codexremote.ssh.SshTerminalSessionState
import top.asdb.codexremote.ui.theme.CodexBorder
import top.asdb.codexremote.ui.theme.CodexGreen
import top.asdb.codexremote.ui.theme.CodexSurfaceRaised
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ThreadListScreen(
    state: AppUiState,
    onSearchChange: (String) -> Unit,
    onRefresh: () -> Unit,
    onCreate: () -> Unit,
    onOpen: (CodexThread) -> Unit,
    onOpenSettings: () -> Unit,
    onShowServers: () -> Unit,
    onBackToServers: () -> Unit,
    terminalSession: SshTerminalSessionState?,
    onOpenTerminal: () -> Unit,
    onSelectAgent: (AgentKind) -> Unit,
) {
    val query = state.threadSearch.trim()
    val profile = state.profiles.firstOrNull { it.id == state.selectedProfileId }
    val availability = serverPageAvailability(state)
    val hostConnected = availability.hostConnected

    Scaffold(
        modifier = Modifier.fillMaxSize().statusBarsPadding(),
        topBar = {
            TopAppBar(
                title = {
                    Column(
                        modifier = Modifier
                            .clickable(onClick = onBackToServers)
                            .semantics { contentDescription = "返回服务器列表" },
                    ) {
                        Text("Agent", fontWeight = FontWeight.SemiBold)
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Box(
                                Modifier.size(6.dp).clip(CircleShape).background(
                                    if (hostConnected) {
                                        CodexGreen
                                    } else {
                                        MaterialTheme.colorScheme.onSurfaceVariant
                                    },
                                ),
                            )
                            Spacer(Modifier.width(6.dp))
                            Text(
                                profile?.name.orEmpty().ifBlank { "远程服务器" },
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                },
                actions = {
                    IconButton(onClick = onOpenTerminal, enabled = profile != null && availability.terminalEnabled) {
                        val terminalActive = terminalSession?.phase in setOf(
                            SshTerminalPhase.Connecting,
                            SshTerminalPhase.Connected,
                        )
                        Icon(
                            Icons.Default.Terminal,
                            contentDescription = if (terminalActive) "显示 SSH 终端" else "打开 SSH 终端",
                            tint = if (terminalActive) CodexGreen else MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    IconButton(onClick = onRefresh, enabled = availability.agentConnected) {
                        if (state.loading) {
                            CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                        } else {
                            Icon(Icons.Default.Refresh, contentDescription = "刷新")
                        }
                    }
                    IconButton(
                        onClick = onCreate,
                        enabled = newThreadActionEnabled(availability, state.loading),
                    ) {
                        Icon(Icons.Default.AddComment, contentDescription = "新任务")
                    }
                    IconButton(onClick = onOpenSettings, enabled = hostConnected) {
                        Icon(Icons.Default.Settings, contentDescription = "${state.activeAgent.label} 设置")
                    }
                    IconButton(onClick = onShowServers) {
                        Icon(Icons.Default.Dns, contentDescription = "切换服务器")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent),
            )
        },
    ) { padding ->
        Column(
            Modifier.padding(padding).navigationBarsPadding().imePadding().fillMaxSize(),
        ) {
            ServerMetricsText(
                state.serverMetrics[state.selectedProfileId],
                modifier = Modifier.padding(start = 18.dp, end = 18.dp, bottom = 1.dp),
                showResourceDetails = true,
            )
            if (profile != null) {
                AgentSwitcher(
                    state = state,
                    profileId = profile.id,
                    enabled = availability.agentSelectionEnabled,
                    onSelectAgent = onSelectAgent,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 7.dp),
                )
            }
            SearchBox(
                value = state.threadSearch,
                onValueChange = onSearchChange,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
            )
            AnimatedContent(
                targetState = state.activeAgent,
                modifier = Modifier.fillMaxSize(),
                transitionSpec = {
                    val movingRight = targetState.ordinal > initialState.ordinal
                    val enter = slideInHorizontally(tween(220)) { width ->
                        if (movingRight) width else -width
                    } + fadeIn(tween(160))
                    val exit = slideOutHorizontally(tween(220)) { width ->
                        if (movingRight) -width else width
                    } + fadeOut(tween(120))
                    enter togetherWith exit
                },
                label = "agent-task-list",
            ) { agent ->
                val key = AgentConnectionKey(profile?.id.orEmpty(), agent)
                val agentThreads = state.agentThreadLists[key]
                    ?: state.threads.takeIf { agent == state.activeAgent }
                    ?: emptyList()
                val connected = state.agentConnectionStates[key]?.phase == ConnectionPhase.Connected
                val threads = visibleAgentThreads(agentThreads, query, connected)
                AgentThreadList(
                    agent = agent,
                    threads = threads,
                    query = query,
                    hostConnected = hostConnected,
                    agentConnected = connected,
                    loading = agent == state.activeAgent && state.loading,
                    onOpen = onOpen,
                )
            }
        }
    }
}

internal fun visibleAgentThreads(
    cachedThreads: List<CodexThread>,
    query: String,
    agentConnected: Boolean,
): List<CodexThread> {
    if (!agentConnected) return emptyList()
    val normalizedQuery = query.trim()
    return cachedThreads.filter { thread ->
        normalizedQuery.isBlank() || thread.title.contains(normalizedQuery, true) ||
            thread.preview.contains(normalizedQuery, true) || thread.cwd.contains(normalizedQuery, true)
    }
}

@Composable
private fun AgentSwitcher(
    state: AppUiState,
    profileId: String,
    enabled: Boolean,
    onSelectAgent: (AgentKind) -> Unit,
    modifier: Modifier = Modifier,
) {
    val agents = AgentKind.entries
    val selectedIndex = agents.indexOf(state.activeAgent).coerceAtLeast(0)
    val outerShape = RoundedCornerShape(10.dp)
    BoxWithConstraints(
        modifier = modifier.height(54.dp).clip(outerShape)
            .background(MaterialTheme.colorScheme.surface)
            .border(1.dp, CodexBorder, outerShape),
    ) {
        val segmentWidth = maxWidth / agents.size
        val indicatorOffset by animateDpAsState(
            targetValue = segmentWidth * selectedIndex,
            animationSpec = tween(durationMillis = 220),
            label = "agent-selector-position",
        )
        val indicatorShape = RoundedCornerShape(7.dp)
        Box(
            modifier = Modifier.offset(x = indicatorOffset).width(segmentWidth).fillMaxHeight()
                .padding(3.dp).clip(indicatorShape)
                .background(MaterialTheme.colorScheme.primaryContainer)
                .border(1.dp, CodexGreen.copy(alpha = 0.72f), indicatorShape),
        )
        Row(Modifier.fillMaxSize()) {
            agents.forEach { agent ->
                val key = AgentConnectionKey(profileId, agent)
                val phase = state.agentConnectionStates[key]?.phase ?: ConnectionPhase.Disconnected
                val setup = state.agentSetupStates[key]
                val selected = state.activeAgent == agent
                val setupStatus = when {
                    setup?.inProgress == true && setup.progress.startsWith("等待") -> "等待"
                    setup?.inProgress == true -> "${setup.percent.coerceIn(0, 100)}%"
                    phase == ConnectionPhase.Failed && setup?.prompt != null -> "失败"
                    setup?.prompt != null -> "待安装"
                    else -> null
                }
                val statusColor = when (phase) {
                    ConnectionPhase.Connected -> CodexGreen
                    ConnectionPhase.Failed -> MaterialTheme.colorScheme.error
                    ConnectionPhase.Installing -> MaterialTheme.colorScheme.tertiary
                    else -> MaterialTheme.colorScheme.onSurfaceVariant
                }
                Column(
                    modifier = Modifier.weight(1f).fillMaxHeight()
                        .selectable(
                            selected = selected,
                            enabled = enabled,
                            role = Role.Tab,
                            onClick = { onSelectAgent(agent) },
                        )
                        .semantics {
                            contentDescription = buildString {
                                append(agent.label)
                                setupStatus?.let { append("，安装进度 $it") }
                            }
                        }
                        .padding(horizontal = 12.dp, vertical = 7.dp),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(7.dp).clip(CircleShape).background(statusColor))
                        Spacer(Modifier.width(7.dp))
                        Text(
                            agent.label,
                            style = MaterialTheme.typography.labelLarge,
                            fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
                            color = if (selected) {
                                MaterialTheme.colorScheme.onSurface
                            } else {
                                MaterialTheme.colorScheme.onSurfaceVariant
                            },
                            maxLines = 1,
                        )
                        setupStatus?.let { status ->
                            Spacer(Modifier.width(7.dp))
                            Text(
                                status,
                                style = MaterialTheme.typography.labelMedium,
                                fontWeight = FontWeight.SemiBold,
                                color = if (setup?.inProgress == true) CodexGreen else statusColor,
                                maxLines = 1,
                            )
                        }
                    }
                    if (setup?.inProgress == true) {
                        Spacer(Modifier.height(5.dp))
                        LinearProgressIndicator(
                            progress = { setup.percent.coerceIn(0, 100) / 100f },
                            modifier = Modifier.fillMaxWidth().height(3.dp),
                            color = CodexGreen,
                            trackColor = CodexBorder,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun AgentThreadList(
    agent: AgentKind,
    threads: List<CodexThread>,
    query: String,
    hostConnected: Boolean,
    agentConnected: Boolean,
    loading: Boolean,
    onOpen: (CodexThread) -> Unit,
) {
    Column(Modifier.fillMaxSize()) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 7.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                if (query.isBlank()) "最近任务" else "搜索结果",
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.weight(1f))
            Text(
                "${threads.size}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Box(Modifier.fillMaxSize()) {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(
                    start = 10.dp,
                    end = 10.dp,
                    bottom = 16.dp,
                ),
                verticalArrangement = Arrangement.spacedBy(0.dp),
            ) {
                items(threads, key = { it.id }) { thread ->
                    ThreadRow(thread, onClick = { onOpen(thread) })
                }
            }
            if (threads.isEmpty() && !loading) {
                Column(
                    Modifier.align(Alignment.Center),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Icon(
                        Icons.Default.Terminal,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(30.dp),
                    )
                    Spacer(Modifier.height(9.dp))
                    Text(
                        when {
                            !hostConnected -> "SSH 尚未连接"
                            !agentConnected -> "${agent.label} 尚未连接"
                            query.isBlank() -> "暂无任务"
                            else -> "没有匹配任务"
                        },
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            if (loading) {
                CircularProgressIndicator(
                    modifier = Modifier.align(Alignment.Center).size(26.dp),
                    strokeWidth = 2.dp,
                )
            }
        }
    }
}

internal data class ServerPageAvailability(
    val hostConnected: Boolean,
    val agentConnected: Boolean,
    val agentBusy: Boolean = false,
) {
    val terminalEnabled: Boolean get() = hostConnected
    val fileManagerEnabled: Boolean get() = hostConnected
    val workspaceEnabled: Boolean get() = agentConnected
    val modelSettingsEnabled: Boolean get() = agentConnected
    val agentSelectionEnabled: Boolean get() = hostConnected && !agentBusy
}

internal fun serverPageAvailability(state: AppUiState): ServerPageAvailability {
    val profileId = state.selectedProfileId
    val hostConnected = profileId != null &&
        state.connectionStates[profileId]?.phase == ConnectionPhase.Connected
    val agentConnected = profileId != null &&
        state.agentConnectionStates[AgentConnectionKey(profileId, state.activeAgent)]?.phase ==
        ConnectionPhase.Connected
    val agentBusy = profileId != null &&
        state.agentConnectionStates[AgentConnectionKey(profileId, state.activeAgent)]?.phase in setOf(
            ConnectionPhase.Probing,
            ConnectionPhase.Connecting,
        )
    return ServerPageAvailability(hostConnected, agentConnected, agentBusy)
}

internal fun newThreadActionEnabled(
    availability: ServerPageAvailability,
    loading: Boolean,
): Boolean = availability.agentConnected && !loading

@Composable
private fun SearchBox(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.height(44.dp).clip(RoundedCornerShape(7.dp))
            .background(CodexSurfaceRaised).padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            Icons.Default.Search,
            contentDescription = null,
            modifier = Modifier.size(19.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.width(9.dp))
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            singleLine = true,
            textStyle = MaterialTheme.typography.bodyMedium.copy(
                color = MaterialTheme.colorScheme.onSurface,
            ),
            cursorBrush = androidx.compose.ui.graphics.SolidColor(MaterialTheme.colorScheme.onSurface),
            modifier = Modifier.weight(1f),
            decorationBox = { inner ->
                Box(contentAlignment = Alignment.CenterStart) {
                    if (value.isBlank()) {
                        Text(
                            "搜索最近任务",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    inner()
                }
            },
        )
    }
}

@Composable
private fun ThreadRow(thread: CodexThread, onClick: () -> Unit) {
    val active = thread.activeTurnId != null || thread.status.lowercase() in setOf(
        "active",
        "running",
        "working",
        "inprogress",
        "in_progress",
    )
    Column {
        Row(
            modifier = Modifier.fillMaxWidth()
                .background(if (active) CodexSurfaceRaised else Color.Transparent)
                .clickable(onClick = onClick).padding(horizontal = 10.dp, vertical = 11.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Box(
                modifier = Modifier.size(28.dp).semantics {
                    contentDescription = if (active) "任务正在工作" else "任务空闲"
                },
                contentAlignment = Alignment.Center,
            ) {
                if (active) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(17.dp),
                        strokeWidth = 2.dp,
                        color = CodexGreen,
                        trackColor = CodexBorder,
                    )
                } else {
                    Icon(
                        Icons.Default.Terminal,
                        contentDescription = null,
                        modifier = Modifier.size(17.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            Spacer(Modifier.width(8.dp))
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        thread.title.ifBlank { "未命名任务" },
                        modifier = Modifier.weight(1f),
                        style = MaterialTheme.typography.bodyLarge,
                        fontWeight = if (active) FontWeight.Medium else FontWeight.Normal,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Spacer(Modifier.width(10.dp))
                    Text(
                        relativeTime(thread.updatedAt),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                thread.preview.takeIf { it.isNotBlank() }?.let { preview ->
                    Spacer(Modifier.height(3.dp))
                    Text(
                        preview,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Spacer(Modifier.height(6.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        Icons.Default.FolderOpen,
                        contentDescription = null,
                        modifier = Modifier.size(14.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.width(5.dp))
                    Text(
                        thread.cwd.ifBlank { "未指定目录" },
                        modifier = Modifier.weight(1f),
                        style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    thread.source.takeIf { it.isNotBlank() }?.let { source ->
                        Spacer(Modifier.width(8.dp))
                        Icon(
                            Icons.Default.Code,
                            contentDescription = null,
                            modifier = Modifier.size(13.dp),
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Spacer(Modifier.width(4.dp))
                        Text(
                            source,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }
        HorizontalDivider(
            modifier = Modifier.padding(start = 46.dp),
            color = CodexBorder,
        )
    }
}

private fun relativeTime(epochSeconds: Long): String {
    if (epochSeconds <= 0) return ""
    val normalizedEpoch = if (epochSeconds > 100_000_000_000L) epochSeconds / 1_000 else epochSeconds
    val delta = (Instant.now().epochSecond - normalizedEpoch).coerceAtLeast(0)
    return when {
        delta < 60 -> "刚刚"
        delta < 3_600 -> "${delta / 60} 分钟"
        delta < 86_400 -> "${delta / 3_600} 小时"
        delta < 604_800 -> "${delta / 86_400} 天"
        delta < 2_592_000 -> "${delta / 604_800} 周"
        else -> DateTimeFormatter.ofPattern("yyyy-MM-dd")
            .withZone(ZoneId.systemDefault())
            .format(Instant.ofEpochSecond(normalizedEpoch))
    }
}
