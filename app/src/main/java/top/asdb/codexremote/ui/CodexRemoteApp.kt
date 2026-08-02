package top.asdb.codexremote.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.ExperimentalAnimationApi
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Fingerprint
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.NetworkCheck
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.repeatOnLifecycle
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import top.asdb.codexremote.AppViewModel
import top.asdb.codexremote.data.AppScreen
import top.asdb.codexremote.data.AppUiState
import top.asdb.codexremote.data.ApprovalKind
import top.asdb.codexremote.data.ApprovalPrompt
import top.asdb.codexremote.data.ConnectionPhase
import top.asdb.codexremote.update.AppUpdateManager
import top.asdb.codexremote.ui.theme.CodexBorder
import top.asdb.codexremote.ui.theme.CodexGreen
import top.asdb.codexremote.ui.theme.CodexMuted
import top.asdb.codexremote.ui.theme.CodexSurfaceRaised

@OptIn(ExperimentalAnimationApi::class)
@Composable
fun CodexRemoteApp(viewModel: AppViewModel) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val terminalState by viewModel.terminalState.collectAsStateWithLifecycle()
    val updateState by AppUpdateManager.state.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    var serverSwitcherVisible by remember { mutableStateOf(false) }
    var threadSettingsActionsVisible by remember { mutableStateOf(false) }
    var updateDialogVisible by rememberSaveable { mutableStateOf(false) }
    var deferredUpdateVersionName by rememberSaveable { mutableStateOf<String?>(null) }
    val context = LocalContext.current
    val connectedMetricProfileIds = state.connectionStates
        .filterValues { it.phase == ConnectionPhase.Connected }
        .keys
        .sorted()
    val lifecycleOwner = LocalLifecycleOwner.current
    val navigationTarget = ScreenAnimationTarget(
        screen = state.screen,
        threadId = state.activeThread?.id,
        subAgentBackNavigation = state.subAgentBackNavigation,
    )

    LaunchedEffect(state.error) {
        state.error?.let {
            snackbar.showSnackbar(it)
            viewModel.clearError()
        }
    }
    LaunchedEffect(state.diagnostic) {
        state.diagnostic?.let {
            snackbar.showSnackbar(it.take(300))
            viewModel.clearDiagnostic()
        }
    }
    LaunchedEffect(updateState.availableUpdate?.versionName, updateState.shouldPromptUpdate) {
        val update = updateState.availableUpdate ?: return@LaunchedEffect
        if (updateState.shouldPromptUpdate && deferredUpdateVersionName != update.versionName) {
            updateDialogVisible = true
        }
    }

    LaunchedEffect(lifecycleOwner, state.screen, state.selectedProfileId, connectedMetricProfileIds) {
        if (state.screen !in setOf(AppScreen.Servers, AppScreen.Threads)) return@LaunchedEffect
        lifecycleOwner.lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            while (isActive) {
                val profileIds = if (state.screen == AppScreen.Servers) {
                    connectedMetricProfileIds
                } else {
                    listOfNotNull(state.selectedProfileId)
                }
                profileIds.forEach(viewModel::refreshServerMetrics)
                delay(10_000L)
            }
        }
    }

    BackHandler(enabled = state.screen != AppScreen.Servers) {
        when (state.screen) {
            AppScreen.Work -> viewModel.backToThreads()
            AppScreen.AgentWork -> viewModel.backFromSubAgentThread()
            AppScreen.Threads -> viewModel.showServers()
            AppScreen.Servers -> Unit
        }
    }

    Box(Modifier.fillMaxSize()) {
        AnimatedContent(
            targetState = navigationTarget,
            modifier = Modifier.fillMaxSize(),
            transitionSpec = {
                val movesForward = when {
                    targetState.screen == initialState.screen &&
                        targetState.threadId != initialState.threadId -> !targetState.subAgentBackNavigation
                    else -> targetState.screen.ordinal > initialState.screen.ordinal
                }
                if (movesForward) {
                    (slideInHorizontally { it / 5 } + fadeIn()) togetherWith
                        (slideOutHorizontally { -it / 8 } + fadeOut())
                } else {
                    (slideInHorizontally { -it / 5 } + fadeIn()) togetherWith
                        (slideOutHorizontally { it / 8 } + fadeOut())
                }
            },
            label = "screen-transition",
        ) { target ->
            val screen = target.screen
            when (screen) {
            AppScreen.Servers -> ServerScreen(
                state = state,
                onSelectProfile = viewModel::selectProfile,
                onNewProfile = viewModel::newProfile,
                onSave = viewModel::saveProfile,
                onDelete = viewModel::deleteProfile,
                onDisconnectProfile = viewModel::disconnectProfile,
                onUninstallRemote = viewModel::uninstallRemote,
                onProbeFingerprint = viewModel::probeFingerprint,
                onConnect = viewModel::connect,
                onEnableDebugMode = viewModel::enableDebugMode,
                onDisableDebugMode = viewModel::disableDebugMode,
                updateAvailable = updateState.availableUpdate != null,
                updateChecking = updateState.checking,
                onShowUpdate = {
                    if (updateState.availableUpdate != null) {
                        updateDialogVisible = true
                    } else {
                        AppUpdateManager.checkForUpdates()
                    }
                },
            )

            AppScreen.Threads -> ThreadListScreen(
                state = state,
                onSearchChange = viewModel::setThreadSearch,
                onRefresh = viewModel::refreshThreads,
                onCreate = viewModel::createThread,
                onOpen = viewModel::openThread,
                onOpenSettings = { threadSettingsActionsVisible = true },
                onShowServers = { serverSwitcherVisible = true },
                onBackToServers = viewModel::showServers,
                terminalSession = state.selectedProfileId?.let(terminalState.sessions::get),
                onOpenTerminal = viewModel::openTerminal,
            )

            AppScreen.Work, AppScreen.AgentWork -> key(target.threadId) {
                WorkScreen(
                    state = state,
                    onBack = {
                        if (screen == AppScreen.AgentWork) {
                            viewModel.backFromSubAgentThread()
                        } else {
                            viewModel.backToThreads()
                        }
                    },
                    onSend = viewModel::send,
                    onStop = viewModel::stopTurn,
                    onReview = viewModel::reviewChanges,
                    onArchive = viewModel::archiveActiveThread,
                    onRollback = viewModel::rollbackActiveThread,
                    onRename = viewModel::renameActiveThread,
                    onUpload = viewModel::uploadAttachments,
                    onAddDebugLog = viewModel::addDebugLogAttachments,
                    onRemoveAttachment = viewModel::removeAttachment,
                    onComposerChange = viewModel::updateComposerDraft,
                    onSelectModel = viewModel::selectModel,
                    onSelectEffort = viewModel::selectEffort,
                    onSelectApprovalMode = viewModel::selectApprovalMode,
                    onSetGoal = viewModel::setActiveGoal,
                    onToggleGoalPause = viewModel::toggleActiveGoalPause,
                    onClearGoal = viewModel::clearActiveGoal,
                    onCompact = viewModel::compactActiveThread,
                    onLoadOlder = viewModel::loadOlderThreadHistory,
                    onLoadRemoteImage = viewModel::loadImagePreview,
                    onOpenSubAgent = viewModel::openSubAgentThread,
                )
            }
            }
        }
        updateState.availableUpdate?.let { update ->
            if (updateDialogVisible) {
                AppUpdateDialog(
                    update = update,
                    download = updateState.download,
                    onDownload = {
                        AppUpdateManager.startDownload(context, update)
                    },
                    onInstall = { AppUpdateManager.installDownloadedUpdate(context) },
                    onLater = {
                        deferredUpdateVersionName = update.versionName
                        updateDialogVisible = false
                    },
                    onIgnore = {
                        AppUpdateManager.ignoreVersion(update.versionName)
                        updateDialogVisible = false
                    },
                )
            }
        }
        SnackbarHost(
            hostState = snackbar,
            snackbar = { data ->
                Snackbar(
                    snackbarData = data,
                    modifier = Modifier.widthIn(max = 420.dp),
                    shape = RoundedCornerShape(8.dp),
                    containerColor = CodexSurfaceRaised,
                    contentColor = MaterialTheme.colorScheme.onSurface,
                    actionColor = CodexGreen,
                )
            },
            // The composer can grow to several rows, so place work-screen messages
            // below the app bar instead of guessing its current height.
            modifier = if (state.screen == AppScreen.Work || state.screen == AppScreen.AgentWork) {
                Modifier.align(Alignment.TopCenter).statusBarsPadding().padding(
                    start = 12.dp,
                    end = 12.dp,
                    top = 68.dp,
                )
            } else {
                Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(12.dp)
            },
        )
        terminalState.visibleProfileId?.let { profileId ->
            terminalState.sessions[profileId]?.let { terminalSession ->
                SshTerminalScreen(
                    session = terminalSession,
                    outputSignals = viewModel.terminalOutputSignals,
                    onReadOutput = viewModel::terminalOutputAfter,
                    onSend = viewModel::sendTerminalInput,
                    onResize = viewModel::resizeTerminal,
                    onRetry = viewModel::retryTerminal,
                    onHide = viewModel::hideTerminal,
                    onClose = viewModel::closeTerminal,
                )
            }
        }
    }

    if (serverSwitcherVisible) {
        ServerSwitcherDialog(
            state = state,
            onSelect = { profileId ->
                serverSwitcherVisible = false
                viewModel.selectProfile(profileId)
            },
            onManage = {
                serverSwitcherVisible = false
                viewModel.showServers()
            },
            onDismiss = { serverSwitcherVisible = false },
        )
    }

    if (threadSettingsActionsVisible) {
        ThreadSettingsActionsDialog(
            onSelectWorkspace = {
                threadSettingsActionsVisible = false
                viewModel.showWorkspacePicker()
            },
            onConfigureCodex = {
                threadSettingsActionsVisible = false
                viewModel.showCodexSettings()
            },
            onDismiss = { threadSettingsActionsVisible = false },
        )
    }

    state.pendingFingerprint?.let { fingerprint ->
        val fingerprintProfile = state.profiles.firstOrNull { it.id == state.selectedProfileId }
        AlertDialog(
            onDismissRequest = viewModel::rejectFingerprint,
            icon = { Icon(Icons.Default.Fingerprint, contentDescription = null) },
            title = { Text("核对 SSH 主机指纹") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    fingerprintProfile?.let { profile ->
                        Column {
                            Text(
                                profile.name.ifBlank { profile.host },
                                style = MaterialTheme.typography.titleSmall,
                            )
                            Text(
                                "${profile.username}@${profile.host}:${profile.port.takeIf { it in 1..65535 } ?: 22}",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                fontFamily = FontFamily.Monospace,
                            )
                        }
                    }
                    Surface(
                        color = MaterialTheme.colorScheme.surfaceVariant,
                        shape = RoundedCornerShape(6.dp),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        SelectionContainer {
                            Text(
                                fingerprint,
                                fontFamily = FontFamily.Monospace,
                                modifier = Modifier.padding(12.dp),
                            )
                        }
                    }
                    Text(
                        "请与服务器端显示的指纹核对一致后再信任。",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            },
            confirmButton = { TextButton(onClick = viewModel::trustFingerprint) { Text("信任并连接") } },
            dismissButton = { TextButton(onClick = viewModel::rejectFingerprint) { Text("取消") } },
        )
    }

    state.remoteSetup?.let { setup ->
        val profileId = state.selectedProfileId
        val savedProxy = state.profiles.firstOrNull { it.id == profileId }?.proxyUrl.orEmpty()
        var setupProxy by remember(profileId, setup) { mutableStateOf(savedProxy) }
        var proxyFocused by remember(profileId, setup) { mutableStateOf(false) }
        AlertDialog(
            modifier = Modifier.imePadding(),
            onDismissRequest = {
                if (!state.setupInProgress) viewModel.cancelRemoteSetup()
            },
            icon = { Icon(Icons.Default.Download, contentDescription = null) },
            title = { Text(setup.title) },
            text = {
                Column(
                    modifier = Modifier.verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    AnimatedVisibility(visible = !proxyFocused) {
                        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            Text(setup.detail)
                            Surface(
                                color = MaterialTheme.colorScheme.surfaceVariant,
                                shape = RoundedCornerShape(6.dp),
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Column(
                                    modifier = Modifier.padding(12.dp),
                                    verticalArrangement = Arrangement.spacedBy(5.dp),
                                ) {
                                    Text(
                                        "${setup.os} · ${setup.architecture}",
                                        style = MaterialTheme.typography.labelLarge,
                                    )
                                    Text(
                                        "Codex ${top.asdb.codexremote.BuildConfig.PINNED_CODEX_VERSION} · " +
                                            "Node ${top.asdb.codexremote.BuildConfig.PINNED_NODE_VERSION}",
                                        style = MaterialTheme.typography.bodySmall,
                                    )
                                    Text(
                                        "${setup.home}/.local/share/codex-remote",
                                        style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                }
                            }
                        }
                    }
                    OutlinedTextField(
                        value = setupProxy,
                        onValueChange = { setupProxy = it },
                        modifier = Modifier.fillMaxWidth().onFocusChanged { proxyFocused = it.isFocused },
                        enabled = !state.setupInProgress,
                        singleLine = true,
                        label = { Text("下载代理（可选）") },
                        placeholder = { Text("http://127.0.0.1:7890") },
                        supportingText = { Text("仅用于本次远程 Node.js 和 Codex 下载，并保存到此服务器") },
                    )
                    if (state.setupInProgress) {
                        val progress = if (state.setupProgressPercent > 0) {
                            state.setupProgressPercent.coerceIn(0, 100) / 100f
                        } else {
                            setupProgressFraction(state.setupProgress)
                        }
                        val progressPercent = (progress * 100).toInt()
                        Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                CircularProgressIndicator(modifier = Modifier.width(20.dp), strokeWidth = 2.dp)
                                Spacer(Modifier.width(10.dp))
                                Text(
                                    state.setupProgress.ifBlank { "正在安装" },
                                    modifier = Modifier.weight(1f),
                                    maxLines = 2,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                Text(
                                    "$progressPercent%",
                                    style = MaterialTheme.typography.labelMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            Text(
                                "总体安装进度",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            LinearProgressIndicator(
                                progress = { progress },
                                modifier = Modifier.fillMaxWidth().heightIn(min = 5.dp, max = 6.dp),
                            )
                            state.setupProgressDetail.takeIf(String::isNotBlank)?.let { detail ->
                                Text(
                                    detail,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            state.setupDownloadPercent?.let { downloadPercent ->
                                val currentDownload = downloadPercent.coerceIn(0, 100) / 100f
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(
                                        "当前下载进度",
                                        modifier = Modifier.weight(1f),
                                        style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                    Text(
                                        "${downloadPercent.coerceIn(0, 100)}%",
                                        style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                }
                                LinearProgressIndicator(
                                    progress = { currentDownload },
                                    modifier = Modifier.fillMaxWidth().heightIn(min = 4.dp, max = 5.dp),
                                    color = CodexGreen,
                                )
                            }
                        }
                    }
                }
            },
            confirmButton = {
                Button(
                    onClick = { viewModel.installRemoteSetup(setupProxy) },
                    enabled = !state.setupInProgress,
                ) { Text(if (state.setupInProgress) "安装中" else "安装并连接") }
            },
            dismissButton = {
                TextButton(
                    onClick = viewModel::cancelRemoteSetup,
                    enabled = !state.setupInProgress,
                ) { Text("取消") }
            },
        )
    }

    if (state.workspacePickerVisible) {
        WorkspacePickerDialog(
            state = state,
            onBrowse = viewModel::browseWorkspace,
            onConfirm = viewModel::confirmWorkspace,
            onDismiss = viewModel::dismissWorkspacePicker,
        )
    }

    if (state.codexSettingsVisible) {
        CodexSettingsDialog(
            state = state,
            onSave = viewModel::saveCodexSettings,
            onTest = viewModel::testCodexSettings,
            onDismiss = viewModel::dismissCodexSettings,
        )
    }

    state.approval?.let { prompt ->
        ApprovalDialog(
            prompt = prompt,
            onApprove = { answer -> viewModel.answerApproval(true, answer) },
            onDecline = viewModel::dismissApproval,
        )
    }
}

private data class ScreenAnimationTarget(
    val screen: AppScreen,
    val threadId: String?,
    val subAgentBackNavigation: Boolean,
)

@Composable
private fun ThreadSettingsActionsDialog(
    onSelectWorkspace: () -> Unit,
    onConfigureCodex: () -> Unit,
    onDismiss: () -> Unit,
) {
    Dialog(onDismissRequest = onDismiss) {
        Surface(
            color = CodexSurfaceRaised,
            shape = RoundedCornerShape(8.dp),
            modifier = Modifier.fillMaxWidth().widthIn(max = 360.dp),
        ) {
            Column(modifier = Modifier.padding(vertical = 6.dp)) {
                Text(
                    "设置",
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.padding(horizontal = 18.dp, vertical = 10.dp),
                )
                SettingsActionRow(
                    icon = { Icon(Icons.Default.Folder, contentDescription = null) },
                    title = "选择工作目录",
                    detail = "切换新会话默认使用的目录",
                    onClick = onSelectWorkspace,
                )
                SettingsActionRow(
                    icon = { Icon(Icons.Default.Settings, contentDescription = null) },
                    title = "配置 Codex",
                    detail = "模型地址、API 密钥和代理",
                    onClick = onConfigureCodex,
                )
            }
        }
    }
}

@Composable
private fun SettingsActionRow(
    icon: @Composable () -> Unit,
    title: String,
    detail: String,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick)
            .padding(horizontal = 18.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier.size(34.dp),
            contentAlignment = Alignment.Center,
        ) { icon() }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            Text(
                detail,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun ServerSwitcherDialog(
    state: AppUiState,
    onSelect: (String) -> Unit,
    onManage: () -> Unit,
    onDismiss: () -> Unit,
) {
    Dialog(onDismissRequest = onDismiss) {
        Surface(
            color = CodexSurfaceRaised,
            shape = RoundedCornerShape(8.dp),
            modifier = Modifier.fillMaxWidth().widthIn(max = 440.dp),
        ) {
            Column {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(start = 18.dp, end = 8.dp, top = 10.dp, bottom = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            "切换服务器",
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold,
                        )
                        Text(
                            "${state.connectionStates.values.count { it.phase == ConnectionPhase.Connected }} 台已连接",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    androidx.compose.material3.IconButton(onClick = onDismiss) {
                        Icon(Icons.Default.Close, contentDescription = "关闭")
                    }
                }
                HorizontalDivider(color = CodexBorder)
                LazyColumn(
                    modifier = Modifier.fillMaxWidth().heightIn(max = 360.dp),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = 4.dp),
                ) {
                    items(state.profiles, key = { it.id }) { profile ->
                        val connected = state.connectionStates[profile.id]?.phase == ConnectionPhase.Connected
                        Row(
                            modifier = Modifier.fillMaxWidth().clickable { onSelect(profile.id) }
                                .padding(horizontal = 18.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Box(
                                Modifier.size(8.dp).clip(CircleShape)
                                    .background(if (connected) CodexGreen else CodexMuted.copy(alpha = 0.62f)),
                            )
                            Spacer(Modifier.width(12.dp))
                            Column(Modifier.weight(1f)) {
                                Text(
                                    profile.name.ifBlank { "未命名服务器" },
                                    style = MaterialTheme.typography.bodyMedium,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                Text(
                                    "${profile.username}@${profile.host.ifBlank { "待配置" }}:${profile.port}",
                                    style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                            if (profile.id == state.selectedProfileId) {
                                Icon(
                                    Icons.Default.Check,
                                    contentDescription = "当前服务器",
                                    modifier = Modifier.size(19.dp),
                                )
                            }
                        }
                    }
                }
                HorizontalDivider(color = CodexBorder)
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp),
                    horizontalArrangement = Arrangement.End,
                ) {
                    TextButton(onClick = onManage) { Text("管理服务器") }
                }
            }
        }
    }
}

private fun setupProgressFraction(message: String): Float {
    val normalized = message.trim()
    if (normalized.isBlank()) return 0.04f
    Regex("^(\\d{1,3})(?:%|\\|)").find(normalized)?.groupValues?.getOrNull(1)
        ?.toIntOrNull()?.let { return (it.coerceIn(0, 100) / 100f).coerceAtLeast(0.02f) }
    return when {
        normalized.contains("下载") -> 0.18f
        normalized.contains("校验") -> 0.36f
        normalized.contains("安装 Codex") -> 0.58f
        normalized.contains("验证") -> 0.86f
        normalized.contains("完成") -> 1f
        else -> 0.08f
    }
}

@Composable
private fun CodexSettingsDialog(
    state: AppUiState,
    onSave: (
        baseUrl: String,
        apiKey: String,
        proxyUrl: String,
        defaultModel: String,
        defaultReasoningEffort: String,
        testModel: String,
        preserveCurrentProvider: Boolean,
    ) -> Unit,
    onTest: (baseUrl: String, apiKey: String, proxyUrl: String, testModel: String) -> Unit,
    onDismiss: () -> Unit,
) {
    val remoteSettings = state.codexSettings
    val savedTestModel = state.profiles.firstOrNull { it.id == state.selectedProfileId }?.testModel.orEmpty()
    var baseUrl by remember(remoteSettings) { mutableStateOf(remoteSettings?.baseUrl.orEmpty()) }
    var apiKey by remember(remoteSettings) { mutableStateOf(remoteSettings?.apiKey.orEmpty()) }
    var apiKeyVisible by remember(remoteSettings) { mutableStateOf(false) }
    var proxyUrl by remember(remoteSettings) { mutableStateOf(remoteSettings?.proxyUrl.orEmpty()) }
    var defaultModel by remember(remoteSettings) { mutableStateOf(remoteSettings?.model.orEmpty()) }
    var defaultReasoningEffort by remember(remoteSettings) {
        mutableStateOf(remoteSettings?.reasoningEffort.orEmpty())
    }
    var defaultReasoningEffortMenuVisible by remember(remoteSettings) { mutableStateOf(false) }
    var testModel by remember(remoteSettings, savedTestModel) {
        mutableStateOf(savedTestModel.ifBlank { remoteSettings?.model.orEmpty() })
    }
    var confirmSave by remember(remoteSettings) { mutableStateOf(false) }
    var testResultStale by remember(remoteSettings) { mutableStateOf(false) }
    val scrollState = rememberScrollState()
    val testResult = state.codexSettingsTestResult?.takeUnless { testResultStale }
    val testFeedback = testResult?.message ?: state.codexSettingsError?.takeIf { it.isNotBlank() }
    val busy = state.codexSettingsLoading || state.codexSettingsSaving || state.codexSettingsTesting
    val settingsReady = remoteSettings != null
    val customProviderInUse = remoteSettings?.modelProvider?.let { it != "openai" } == true
    val preserveCurrentProvider = customProviderInUse &&
        baseUrl.trim().trimEnd('/') == remoteSettings?.baseUrl.orEmpty().trim().trimEnd('/')

    LaunchedEffect(testFeedback) {
        if (testFeedback != null) {
            withFrameNanos { }
            scrollState.animateScrollTo(scrollState.maxValue)
        }
    }

    AlertDialog(
        modifier = Modifier.imePadding(),
        onDismissRequest = { if (!busy) onDismiss() },
        icon = { Icon(Icons.Default.Settings, contentDescription = null) },
        title = { Text("配置 Codex") },
        text = {
            Column(
                modifier = Modifier.verticalScroll(scrollState),
                verticalArrangement = Arrangement.spacedBy(11.dp),
            ) {
                if (state.codexSettingsLoading) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(modifier = Modifier.size(19.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(10.dp))
                        Text("正在读取服务器上的全局配置")
                    }
                } else {
                    Text(
                        "这些设置作用于当前服务器用户的全部 Codex CLI、IDE 插件和本应用会话。",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Surface(
                        color = MaterialTheme.colorScheme.surfaceVariant,
                        shape = RoundedCornerShape(6.dp),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Column(
                            modifier = Modifier.padding(11.dp),
                            verticalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            Text("服务器当前配置", style = MaterialTheme.typography.labelLarge)
                            Text(
                                "Provider：${remoteSettings?.modelProvider.orEmpty().ifBlank { "openai" }}",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            Text(
                                "默认模型：${remoteSettings?.model.orEmpty().ifBlank { "未配置，使用 Codex 默认值" }}",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            Text(
                                "默认思考强度：${defaultReasoningEffortLabel(remoteSettings?.reasoningEffort.orEmpty())}",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            if (customProviderInUse) {
                                Text(
                                    if (preserveCurrentProvider) {
                                        "当前使用自定义 Provider；仅修改默认模型和思考强度会保留该 Provider。"
                                    } else {
                                        "修改模型 URL 后会切换到内置 OpenAI Provider。"
                                    },
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.error,
                                )
                            }
                        }
                    }
                    OutlinedTextField(
                        value = defaultModel,
                        onValueChange = { defaultModel = it },
                        modifier = Modifier.fillMaxWidth(),
                        enabled = !busy && settingsReady,
                        singleLine = true,
                        label = { Text("默认模型") },
                        placeholder = { Text("gpt-5.6-sol") },
                        supportingText = { Text("留空使用 Codex 默认模型；保存后对新会话生效") },
                    )
                    Text(
                        "默认思考强度",
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Box(Modifier.fillMaxWidth()) {
                        OutlinedButton(
                            onClick = { defaultReasoningEffortMenuVisible = true },
                            enabled = !busy && settingsReady,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(
                                    defaultReasoningEffortLabel(defaultReasoningEffort),
                                    modifier = Modifier.weight(1f),
                                )
                                Icon(Icons.Default.ExpandMore, contentDescription = null)
                            }
                        }
                        DropdownMenu(
                            expanded = defaultReasoningEffortMenuVisible,
                            onDismissRequest = { defaultReasoningEffortMenuVisible = false },
                        ) {
                            DEFAULT_REASONING_EFFORT_OPTIONS.forEach { effort ->
                                DropdownMenuItem(
                                    text = { Text(defaultReasoningEffortLabel(effort)) },
                                    onClick = {
                                        defaultReasoningEffort = effort
                                        defaultReasoningEffortMenuVisible = false
                                    },
                                )
                            }
                        }
                    }
                    Text(
                        "留空使用 Codex 默认思考强度。",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    OutlinedTextField(
                        value = baseUrl,
                        onValueChange = {
                            baseUrl = it
                            testResultStale = true
                        },
                        modifier = Modifier.fillMaxWidth(),
                        enabled = !busy && settingsReady,
                        singleLine = true,
                        label = { Text("模型 URL") },
                        placeholder = { Text("https://api.openai.com/v1") },
                        supportingText = { Text("留空使用 Codex 默认 OpenAI 地址") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                    )
                    OutlinedTextField(
                        value = apiKey,
                        onValueChange = {
                            apiKey = it
                            testResultStale = true
                        },
                        modifier = Modifier.fillMaxWidth(),
                        enabled = !busy && settingsReady,
                        singleLine = true,
                        label = { Text("API 密钥") },
                        visualTransformation = if (apiKeyVisible) {
                            VisualTransformation.None
                        } else {
                            PasswordVisualTransformation()
                        },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                        trailingIcon = {
                            IconButton(
                                onClick = { apiKeyVisible = !apiKeyVisible },
                                enabled = !busy && settingsReady,
                            ) {
                                Icon(
                                    imageVector = if (apiKeyVisible) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                                    contentDescription = if (apiKeyVisible) "隐藏 API 密钥" else "显示 API 密钥",
                                )
                            }
                        },
                        supportingText = {
                            Text(
                                when {
                                    remoteSettings?.apiKey?.isNotBlank() == true ->
                                        "已读取服务器 API 密钥，仅在当前设置页面的内存中保留。"
                                    remoteSettings?.hasStoredAuthentication == true ->
                                        "服务器使用非 API 密钥登录，无法显示密钥；填写可替换登录。"
                                    else -> "留空不会创建或修改登录信息。"
                                },
                            )
                        },
                    )
                    OutlinedTextField(
                        value = proxyUrl,
                        onValueChange = {
                            proxyUrl = it
                            testResultStale = true
                        },
                        modifier = Modifier.fillMaxWidth(),
                        enabled = !busy && settingsReady,
                        singleLine = true,
                        label = { Text("Codex 代理（可选）") },
                        placeholder = { Text("http://127.0.0.1:7890") },
                        supportingText = { Text("支持 HTTP/HTTPS；留空会清除 Codex 代理") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                    )
                    OutlinedTextField(
                        value = testModel,
                        onValueChange = {
                            testModel = it
                            testResultStale = true
                        },
                        modifier = Modifier.fillMaxWidth(),
                        enabled = !busy && settingsReady,
                        singleLine = true,
                        label = { Text("测试模型") },
                        placeholder = { Text("gpt-5.6-sol") },
                        supportingText = { Text("保存后按当前服务器记住") },
                    )
                    OutlinedButton(
                        onClick = {
                            testResultStale = false
                            onTest(baseUrl, apiKey, proxyUrl, testModel)
                        },
                        modifier = Modifier.fillMaxWidth(),
                        enabled = !busy && settingsReady,
                    ) {
                        if (state.codexSettingsTesting) {
                            CircularProgressIndicator(modifier = Modifier.size(17.dp), strokeWidth = 2.dp)
                            Spacer(Modifier.width(8.dp))
                            Text("正在测试")
                        } else {
                            Icon(Icons.Default.NetworkCheck, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("测试连接")
                        }
                    }
                    testFeedback?.let { message ->
                        val successful = testResult?.successful == true
                        Surface(
                            color = if (successful) {
                                CodexGreen.copy(alpha = 0.14f)
                            } else {
                                MaterialTheme.colorScheme.errorContainer
                            },
                            shape = RoundedCornerShape(6.dp),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Row(
                                modifier = Modifier.padding(11.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Icon(
                                    imageVector = if (successful) Icons.Default.Check else Icons.Default.Close,
                                    contentDescription = null,
                                    modifier = Modifier.size(18.dp),
                                    tint = if (successful) CodexGreen else MaterialTheme.colorScheme.error,
                                )
                                Spacer(Modifier.width(9.dp))
                                Text(
                                    message,
                                    color = if (successful) CodexGreen else MaterialTheme.colorScheme.error,
                                    style = MaterialTheme.typography.bodySmall,
                                )
                            }
                        }
                    }
                    Surface(
                        color = MaterialTheme.colorScheme.surfaceVariant,
                        shape = RoundedCornerShape(6.dp),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(
                            "测试不会保存或断开连接。保存后会断开当前服务器；修改 API 密钥才会替换该用户现有的 Codex 登录。",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(11.dp),
                        )
                    }
                }
            }
        },
        confirmButton = {
            Button(
                onClick = { confirmSave = true },
                enabled = !busy && settingsReady,
            ) { Text("保存") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, enabled = !busy) { Text("取消") }
        },
    )

    if (confirmSave) {
        AlertDialog(
            onDismissRequest = { confirmSave = false },
            title = { Text("确认保存全局配置") },
            text = {
                Text("保存会更新此服务器用户的 Codex 配置并断开当前连接。已填写的 API 密钥会替换现有登录。")
            },
            confirmButton = {
                Button(
                    onClick = {
                        confirmSave = false
                        onSave(
                            baseUrl,
                            apiKey.takeUnless { it == remoteSettings?.apiKey }.orEmpty(),
                            proxyUrl,
                            defaultModel,
                            defaultReasoningEffort,
                            testModel,
                            preserveCurrentProvider,
                        )
                    },
                ) { Text("确认保存") }
            },
            dismissButton = {
                TextButton(onClick = { confirmSave = false }) { Text("返回修改") }
            },
        )
    }
}

private val DEFAULT_REASONING_EFFORT_OPTIONS = listOf("", "minimal", "low", "medium", "high", "xhigh")

private fun defaultReasoningEffortLabel(effort: String): String = when (effort) {
    "" -> "默认（使用 Codex 默认值）"
    "minimal" -> "极低"
    "low" -> "低"
    "medium" -> "中"
    "high" -> "高"
    "xhigh" -> "极高"
    else -> effort
}

@Composable
private fun WorkspacePickerDialog(
    state: AppUiState,
    onBrowse: (String) -> Unit,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        icon = { Icon(Icons.Default.Folder, contentDescription = null) },
        title = { Text("选择工作目录") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Surface(
                    color = MaterialTheme.colorScheme.surfaceVariant,
                    shape = RoundedCornerShape(6.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    SelectionContainer {
                        Text(
                            state.workspaceCurrentPath.ifBlank { "/" },
                            style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                            modifier = Modifier.padding(horizontal = 11.dp, vertical = 9.dp),
                        )
                    }
                }
                state.workspaceError?.takeIf { it.isNotBlank() }?.let { message ->
                    Text(
                        message,
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                Box(Modifier.fillMaxWidth().heightIn(min = 150.dp, max = 380.dp)) {
                    LazyColumn(Modifier.fillMaxWidth()) {
                        state.workspaceParentPath?.let { parent ->
                            item(key = "parent:$parent") {
                                DirectoryRow(
                                    name = "上一级",
                                    parent = true,
                                    onClick = { onBrowse(parent) },
                                )
                                HorizontalDivider()
                            }
                        }
                        items(state.workspaceDirectories, key = { it.path }) { directory ->
                            DirectoryRow(
                                name = directory.name,
                                parent = false,
                                onClick = { onBrowse(directory.path) },
                            )
                        }
                        if (!state.workspaceLoading && state.workspaceDirectories.isEmpty() &&
                            state.workspaceParentPath == null
                        ) {
                            item {
                                Text(
                                    "当前目录没有子目录",
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    style = MaterialTheme.typography.bodySmall,
                                    modifier = Modifier.padding(vertical = 18.dp),
                                )
                            }
                        }
                    }
                    if (state.workspaceLoading) {
                        CircularProgressIndicator(
                            modifier = Modifier.align(Alignment.Center),
                            strokeWidth = 2.dp,
                        )
                    }
                }
            }
        },
        confirmButton = {
            Button(
                onClick = onConfirm,
                enabled = state.workspaceCurrentPath.isNotBlank() && !state.workspaceLoading,
            ) {
                Text("使用此目录")
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("稍后") } },
    )
}

@Composable
private fun DirectoryRow(name: String, parent: Boolean, onClick: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick)
            .padding(horizontal = 4.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            if (parent) Icons.Default.KeyboardArrowUp else Icons.Default.Folder,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.width(10.dp))
        Text(name, maxLines = 1, modifier = Modifier.weight(1f))
    }
}

@Composable
private fun ApprovalDialog(
    prompt: ApprovalPrompt,
    onApprove: (Map<String, String>) -> Unit,
    onDecline: () -> Unit,
) {
    // Keep one answer per question. The server expects the question id as the key,
    // so a single shared text field would lose answers when several questions arrive.
    // Do not preselect the first option: the protocol does not define it as a default,
    // and silently choosing it could submit an unintended answer.
    val answers = remember(prompt.requestId) {
        androidx.compose.runtime.mutableStateMapOf<String, String>()
    }
    val allQuestionsAnswered = prompt.questions.all { question ->
        answers[question.id].orEmpty().isNotBlank()
    }
    AlertDialog(
        modifier = Modifier.imePadding(),
        onDismissRequest = {},
        icon = { Icon(Icons.Default.Security, contentDescription = null) },
        title = { Text(prompt.title) },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                if (prompt.detail.isNotBlank()) Text(prompt.detail)
                if (prompt.cwd.isNotBlank()) {
                    Text(prompt.cwd, style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (prompt.command.isNotBlank()) {
                    Surface(
                        color = MaterialTheme.colorScheme.surfaceVariant,
                        shape = RoundedCornerShape(6.dp),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        SelectionContainer {
                            Text(
                                prompt.command,
                                fontFamily = FontFamily.Monospace,
                                style = MaterialTheme.typography.bodySmall,
                                modifier = Modifier.padding(11.dp),
                            )
                        }
                    }
                }
                if (prompt.kind == ApprovalKind.UserInput) {
                    prompt.questions.forEach { question ->
                        if (question.header.isNotBlank()) {
                            Text(question.header, style = MaterialTheme.typography.labelLarge)
                        }
                        if (question.question.isNotBlank()) {
                            Text(question.question, style = MaterialTheme.typography.bodyMedium)
                        }
                        if (question.options.isNotEmpty()) {
                            Row(
                                modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                                horizontalArrangement = Arrangement.spacedBy(7.dp),
                            ) {
                                question.options.forEach { option ->
                                    FilterChip(
                                        selected = option.label == answers[question.id],
                                        onClick = { answers[question.id] = option.label },
                                        label = { Text(option.label) },
                                    )
                                }
                            }
                            question.options.firstOrNull { it.label == answers[question.id] }
                                ?.description?.takeIf { it.isNotBlank() }?.let { description ->
                                    Text(
                                        description,
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                }
                        }
                        OutlinedTextField(
                            value = answers[question.id].orEmpty(),
                            onValueChange = { answers[question.id] = it },
                            modifier = Modifier.fillMaxWidth(),
                            label = { Text("回答") },
                            singleLine = !question.isSecret,
                            visualTransformation = if (question.isSecret) {
                                PasswordVisualTransformation()
                            } else androidx.compose.ui.text.input.VisualTransformation.None,
                        )
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onApprove(answers.toMap()) },
                enabled = prompt.kind != ApprovalKind.UserInput || allQuestionsAnswered,
            ) { Text(if (prompt.kind == ApprovalKind.UserInput) "提交" else "允许一次") }
        },
        dismissButton = {
            TextButton(onClick = onDecline) {
                Text(if (prompt.kind == ApprovalKind.UserInput) "取消" else "拒绝")
            }
        },
    )
}
