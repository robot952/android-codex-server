package top.asdb.codexremote.ui

import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Badge
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.DeleteForever
import androidx.compose.material.icons.filled.DeleteSweep
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Fingerprint
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Save
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import top.asdb.codexremote.BuildConfig
import top.asdb.codexremote.data.AppScreen
import top.asdb.codexremote.data.AppUiState
import top.asdb.codexremote.data.AuthMode
import top.asdb.codexremote.data.ConnectionPhase
import top.asdb.codexremote.data.ConnectionState
import top.asdb.codexremote.data.ServerProfile
import top.asdb.codexremote.diagnostics.DebugTapCounter
import top.asdb.codexremote.diagnostics.DiagnosticLogger
import top.asdb.codexremote.ui.theme.CodexAmber
import top.asdb.codexremote.ui.theme.CodexBorder
import top.asdb.codexremote.ui.theme.CodexGreen
import top.asdb.codexremote.ui.theme.CodexMuted
import top.asdb.codexremote.ui.theme.CodexSurfaceRaised
import java.io.ByteArrayOutputStream

private val FieldShape = RoundedCornerShape(7.dp)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ServerScreen(
    state: AppUiState,
    onSelectProfile: (String) -> Unit,
    onNewProfile: () -> ServerProfile,
    onSave: (ServerProfile) -> Unit,
    onDelete: (String) -> Unit,
    onDisconnectProfile: (String) -> Unit,
    onUninstallRemote: (String) -> Unit,
    onProbeFingerprint: (ServerProfile) -> Unit,
    onConnect: (ServerProfile) -> Unit,
    onEnableDebugMode: () -> Unit,
    onDisableDebugMode: () -> Unit,
) {
    val selected = state.profiles.firstOrNull { it.id == state.selectedProfileId }
    val unsavedDrafts = remember { mutableStateMapOf<String, ServerProfile>() }
    var draft by rememberSaveable(selected?.id, stateSaver = ServerProfileSaver) {
        mutableStateOf(selected?.let { unsavedDrafts[it.id] ?: it } ?: onNewProfile())
    }
    // Saved-state bundles are not the encrypted profile store. Restore credentials from the
    // already-persisted profile after a configuration/process recreation, while intentionally
    // keeping passwords and PEM contents out of the Bundle itself. Unsaved credentials may be
    // requested again after a process is killed, which is safer than leaving them in system state.
    val credentialsOmittedFromSavedState = draft.password == SAVED_STATE_CREDENTIAL_OMITTED ||
        draft.privateKeyPem == SAVED_STATE_CREDENTIAL_OMITTED ||
        draft.privateKeyPassphrase == SAVED_STATE_CREDENTIAL_OMITTED
    LaunchedEffect(draft.id, credentialsOmittedFromSavedState, state.profiles) {
        if (credentialsOmittedFromSavedState) {
            val persisted = state.profiles.firstOrNull { it.id == draft.id }
            draft = draft.copy(
                password = persisted?.password.orEmpty(),
                privateKeyPem = persisted?.privateKeyPem.orEmpty(),
                privateKeyPassphrase = persisted?.privateKeyPassphrase.orEmpty(),
            )
        }
    }
    var advanced by remember(draft.id) { mutableStateOf(false) }
    var passwordVisible by remember(draft.id) { mutableStateOf(false) }
    var deleteRequested by remember { mutableStateOf(false) }
    var uninstallRequested by remember { mutableStateOf(false) }
    var connectRequested by remember { mutableStateOf<ServerProfile?>(null) }
    var disconnectRequested by remember { mutableStateOf<ServerProfile?>(null) }
    var keyImportError by remember { mutableStateOf<String?>(null) }
    var showDebugLogs by remember { mutableStateOf(false) }
    var editorVisible by rememberSaveable { mutableStateOf(false) }
    var newDraftStarted by rememberSaveable { mutableStateOf(false) }
    val debugTapCounter = remember { DebugTapCounter() }
    val focusManager = LocalFocusManager.current
    fun cacheCurrentDraft() {
        val persisted = state.profiles.firstOrNull { it.id == draft.id }
        if (persisted == null || persisted != draft) {
            unsavedDrafts[draft.id] = draft
        } else {
            unsavedDrafts.remove(draft.id)
        }
    }
    fun showDraft(next: ServerProfile) {
        focusManager.clearFocus(force = true)
        if (next.id == draft.id) return
        if (editorVisible || newDraftStarted) cacheCurrentDraft()
        draft = unsavedDrafts[next.id] ?: next
    }
    fun showSettings(profile: ServerProfile) {
        showDraft(profile)
        editorVisible = true
    }
    fun showNewDraft() {
        focusManager.clearFocus(force = true)
        val pending = unsavedDrafts.values.firstOrNull { candidate ->
            state.profiles.none { it.id == candidate.id }
        }
        val currentNewDraft = draft.takeIf {
            newDraftStarted && state.profiles.none { profile -> profile.id == it.id }
        }
        showDraft(currentNewDraft ?: pending ?: onNewProfile())
        newDraftStarted = true
        editorVisible = true
    }
    fun closeEditor() {
        focusManager.clearFocus(force = true)
        cacheCurrentDraft()
        editorVisible = false
    }
    val savedProfile = state.profiles.firstOrNull { it.id == draft.id }
    val savedDraft = savedProfile != null
    val hasUnsavedChanges = savedProfile != null && savedProfile != draft
    LaunchedEffect(savedProfile?.hostFingerprint, savedProfile?.host, savedProfile?.port) {
        val persisted = savedProfile ?: return@LaunchedEffect
        val draftPort = draft.port.takeIf { it in 1..65535 } ?: 22
        val persistedPort = persisted.port.takeIf { it in 1..65535 } ?: 22
        if (draft.host.trim() == persisted.host.trim() && draftPort == persistedPort &&
            draft.hostFingerprint != persisted.hostFingerprint
        ) {
            val synchronized = draft.copy(hostFingerprint = persisted.hostFingerprint)
            draft = synchronized
            if (unsavedDrafts.containsKey(synchronized.id)) {
                unsavedDrafts[synchronized.id] = synchronized
            }
        }
    }
    val pendingNewDraft = if (newDraftStarted && !savedDraft) {
        draft
    } else {
        unsavedDrafts.values.firstOrNull { candidate ->
            state.profiles.none { it.id == candidate.id }
        }
    }
    val activeConnection = state.connectionStates[draft.id]
        ?: if (draft.id == state.selectedProfileId) state.connection else ConnectionState()
    val connectedCount = state.connectionStates.values.count { it.phase == ConnectionPhase.Connected }
    val connectionForProfile: (ServerProfile) -> ConnectionState = { profile ->
        state.connectionStates[profile.id]
            ?: if (profile.id == state.selectedProfileId) state.connection else ConnectionState()
    }
    val busyProfile = state.profiles.firstOrNull { profile ->
        connectionForProfile(profile).phase in setOf(
            ConnectionPhase.Probing,
            ConnectionPhase.Connecting,
        )
    }
    var connectionHandoffProfileId by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(busyProfile?.id, state.screen) {
        when {
            busyProfile != null -> connectionHandoffProfileId = busyProfile.id
            state.screen != AppScreen.Threads -> connectionHandoffProfileId = null
        }
    }
    val connectedHandoffProfile = state.profiles.firstOrNull { profile ->
        state.screen == AppScreen.Threads && profile.id == connectionHandoffProfileId &&
            profile.id == state.selectedProfileId &&
            connectionForProfile(profile).phase == ConnectionPhase.Connected
    }
    val blockingProfile = busyProfile ?: connectedHandoffProfile
    val blockingConnection = blockingProfile?.let { connectionForProfile(it) }
    val context = LocalContext.current
    val coroutineScope = rememberCoroutineScope()

    BackHandler(enabled = editorVisible, onBack = ::closeEditor)
    val keyPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        // ContentResolver providers may perform blocking I/O. Keep the picker callback on the
        // main thread, but read the bounded file on Dispatchers.IO so a slow provider cannot
        // freeze the form or trigger an ANR. Capture the profile id so a late result cannot
        // overwrite another server after the user switches tabs.
        val importProfileId = draft.id
        unsavedDrafts[importProfileId] = draft
        coroutineScope.launch {
            try {
                val pem = withContext(Dispatchers.IO) {
                    context.contentResolver.openInputStream(uri)?.use { stream ->
                        val output = ByteArrayOutputStream()
                        val buffer = ByteArray(8 * 1024)
                        while (true) {
                            val count = stream.read(buffer)
                            if (count < 0) break
                            require(output.size() + count <= MAX_PRIVATE_KEY_BYTES) { "私钥文件过大" }
                            output.write(buffer, 0, count)
                        }
                        output.toString(Charsets.UTF_8.name())
                    } ?: error("无法读取私钥")
                }
                val base = unsavedDrafts[importProfileId]
                    ?: state.profiles.firstOrNull { it.id == importProfileId }
                if (draft.id == importProfileId) {
                    draft = draft.copy(privateKeyPem = pem)
                } else if (base != null) {
                    unsavedDrafts[importProfileId] = base.copy(privateKeyPem = pem)
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                keyImportError = error.message ?: "无法导入私钥"
            }
        }
    }

    Scaffold(
        modifier = Modifier.fillMaxSize().statusBarsPadding(),
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                navigationIcon = {
                    if (editorVisible) {
                        IconButton(onClick = ::closeEditor) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回服务器列表")
                        }
                    }
                },
                title = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Surface(
                            color = MaterialTheme.colorScheme.onSurface,
                            contentColor = MaterialTheme.colorScheme.surface,
                            shape = RoundedCornerShape(6.dp),
                            modifier = Modifier.size(34.dp).clickable {
                                if (state.debugModeEnabled) {
                                    showDebugLogs = true
                                } else if (debugTapCounter.registerTap(SystemClock.elapsedRealtime())) {
                                    onEnableDebugMode()
                                }
                            },
                        ) {
                            Box(contentAlignment = Alignment.Center) {
                                Icon(
                                    Icons.Default.Terminal,
                                    contentDescription = null,
                                    modifier = Modifier.size(19.dp),
                                )
                            }
                        }
                        Spacer(Modifier.width(10.dp))
                        Column {
                            Text("Codex", fontWeight = FontWeight.SemiBold)
                            Text(
                                if (editorVisible) {
                                    if (savedDraft) "服务器设置" else "添加服务器"
                                } else {
                                    "服务器列表"
                                },
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                },
                actions = {
                    Text(
                        "v${BuildConfig.VERSION_NAME}",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(end = 14.dp),
                    )
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent),
            )
        },
    ) { padding ->
        AnimatedContent(
            targetState = editorVisible,
            modifier = Modifier.padding(padding).navigationBarsPadding().fillMaxSize(),
            transitionSpec = {
                if (targetState) {
                    (slideInHorizontally { it / 5 } + fadeIn()) togetherWith
                        (slideOutHorizontally { -it / 8 } + fadeOut())
                } else {
                    (slideInHorizontally { -it / 5 } + fadeIn()) togetherWith
                        (slideOutHorizontally { it / 8 } + fadeOut())
                }
            },
            label = "server-detail-transition",
        ) { showingEditor ->
            if (!showingEditor) {
                Column(
                    modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()),
                ) {
                    ServerSessionPanel(
                        profiles = state.profiles,
                        pendingNewDraft = pendingNewDraft,
                        connectedCount = connectedCount,
                        connectionFor = connectionForProfile,
                        onSettings = ::showSettings,
                        onOpen = { profile, connection ->
                            if (connection.phase == ConnectionPhase.Connected) {
                                onSelectProfile(profile.id)
                            } else {
                                connectRequested = profile
                            }
                        },
                        onDisconnect = { disconnectRequested = it },
                        onAdd = ::showNewDraft,
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp),
                    )

                    if (state.debugModeEnabled) {
                        DebugLogBar(
                            onOpen = { showDebugLogs = true },
                            onShare = { shareDiagnosticLog(context) },
                        )
                        HorizontalDivider(color = CodexBorder)
                    }
                    if (state.profiles.isEmpty() && pendingNewDraft == null) {
                        EmptyServerState(onAdd = ::showNewDraft)
                    }
                    Spacer(Modifier.height(14.dp))
                }
            } else {
                Column(
                    modifier = Modifier.fillMaxSize().imePadding().verticalScroll(rememberScrollState()),
                ) {
                    Surface(
                        color = MaterialTheme.colorScheme.surface,
                        shape = RoundedCornerShape(10.dp),
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp)
                            .border(1.dp, CodexBorder, RoundedCornerShape(10.dp)),
                    ) {
                        Column(
                            modifier = Modifier.fillMaxWidth().animateContentSize().padding(14.dp),
                            verticalArrangement = Arrangement.spacedBy(13.dp),
                        ) {
                    SectionHeading(
                        title = if (savedDraft) "连接设置" else "新建服务器",
                        detail = if (savedDraft) draft.name else "填写 SSH 登录信息",
                    )

                    ServerTextField(
                        value = draft.name,
                        onValueChange = { draft = draft.copy(name = it) },
                        label = "服务器名称",
                        leadingIcon = Icons.Default.Badge,
                        modifier = Modifier.fillMaxWidth().bringAboveKeyboard(),
                    )
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        ServerTextField(
                            value = draft.host,
                            onValueChange = { value ->
                                draft = draft.copy(
                                    host = value,
                                    hostFingerprint = if (value == draft.host) draft.hostFingerprint else "",
                                )
                            },
                            label = "服务器地址",
                            leadingIcon = Icons.Default.Dns,
                            modifier = Modifier.weight(1f).bringAboveKeyboard(),
                        )
                        ServerTextField(
                            value = draft.port.toString(),
                            onValueChange = { value ->
                                if (value.isEmpty()) {
                                    draft = draft.copy(port = 0, hostFingerprint = "")
                                } else {
                                    value.toIntOrNull()?.takeIf { it in 1..65535 }?.let { port ->
                                        draft = draft.copy(
                                            port = port,
                                            hostFingerprint = if (port == draft.port) draft.hostFingerprint else "",
                                        )
                                    }
                                }
                            },
                            label = "端口",
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                            modifier = Modifier.width(96.dp).bringAboveKeyboard(),
                        )
                    }
                    ServerTextField(
                        value = draft.username,
                        onValueChange = { draft = draft.copy(username = it) },
                        label = "用户名",
                        leadingIcon = Icons.Default.Person,
                        modifier = Modifier.fillMaxWidth().bringAboveKeyboard(),
                    )

                    SectionLabel("身份验证")
                    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                        AuthMode.entries.forEachIndexed { index, mode ->
                            SegmentedButton(
                                selected = draft.authMode == mode,
                                onClick = { draft = draft.copy(authMode = mode) },
                                shape = SegmentedButtonDefaults.itemShape(index, AuthMode.entries.size),
                                icon = {
                                    Icon(
                                        if (mode == AuthMode.PrivateKey) Icons.Default.Key else Icons.Default.Lock,
                                        contentDescription = null,
                                        modifier = Modifier.size(17.dp),
                                    )
                                },
                                label = { Text(if (mode == AuthMode.PrivateKey) "私钥" else "密码") },
                            )
                        }
                    }

                    if (draft.authMode == AuthMode.Password) {
                        ServerTextField(
                            value = draft.password,
                            onValueChange = { draft = draft.copy(password = it) },
                            label = "SSH 密码",
                            leadingIcon = Icons.Default.Lock,
                            visualTransformation = if (passwordVisible) {
                                VisualTransformation.None
                            } else {
                                PasswordVisualTransformation()
                            },
                            trailingIcon = {
                                IconButton(onClick = { passwordVisible = !passwordVisible }) {
                                    Icon(
                                        if (passwordVisible) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                                        contentDescription = if (passwordVisible) "隐藏密码" else "显示密码",
                                    )
                                }
                            },
                            modifier = Modifier.fillMaxWidth().bringAboveKeyboard(),
                        )
                    } else {
                        OutlinedButton(
                            onClick = { keyPicker.launch(arrayOf("application/x-pem-file", "text/plain", "*/*")) },
                            shape = FieldShape,
                            modifier = Modifier.fillMaxWidth().height(54.dp),
                        ) {
                            Icon(Icons.Default.Key, contentDescription = null)
                            Spacer(Modifier.width(8.dp))
                            Text(if (draft.privateKeyPem.isBlank()) "选择 SSH 私钥" else "已导入 SSH 私钥")
                        }
                        if (draft.privateKeyPem.isNotBlank()) {
                            ServerTextField(
                                value = draft.privateKeyPassphrase,
                                onValueChange = { draft = draft.copy(privateKeyPassphrase = it) },
                                label = "私钥口令（可选）",
                                leadingIcon = Icons.Default.Lock,
                                visualTransformation = PasswordVisualTransformation(),
                                modifier = Modifier.fillMaxWidth().bringAboveKeyboard(),
                            )
                        }
                    }

                    FingerprintRow(
                        fingerprint = draft.hostFingerprint,
                        probing = activeConnection.phase == ConnectionPhase.Probing,
                        enabled = draft.host.isNotBlank() && draft.username.isNotBlank(),
                        onProbe = {
                            val normalized = draft.copy(port = draft.port.takeIf { it in 1..65535 } ?: 22)
                            draft = normalized
                            unsavedDrafts.remove(normalized.id)
                            focusManager.clearFocus(force = true)
                            onProbeFingerprint(normalized)
                        },
                    )

                    TextButton(
                        onClick = { advanced = !advanced },
                        modifier = Modifier.align(Alignment.Start),
                    ) {
                        Icon(Icons.Default.Tune, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(7.dp))
                        Text("高级设置")
                        Spacer(Modifier.width(3.dp))
                        Icon(
                            if (advanced) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                            contentDescription = null,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                    AnimatedVisibility(
                        visible = advanced,
                        enter = expandVertically() + fadeIn(),
                        exit = shrinkVertically() + fadeOut(),
                    ) {
                        Column(verticalArrangement = Arrangement.spacedBy(13.dp)) {
                            ServerTextField(
                                value = draft.workspace,
                                onValueChange = { draft = draft.copy(workspace = it) },
                                label = "默认工作目录",
                                placeholder = "/home/user/project",
                                modifier = Modifier.fillMaxWidth().bringAboveKeyboard(),
                            )
                            ServerTextField(
                                value = draft.remoteCommand,
                                onValueChange = { draft = draft.copy(remoteCommand = it) },
                                label = "Codex app-server 命令",
                                singleLine = false,
                                minLines = 2,
                                maxLines = 4,
                                monospace = true,
                                modifier = Modifier.fillMaxWidth().bringAboveKeyboard(),
                            )
                            ServerTextField(
                                value = draft.proxyUrl,
                                onValueChange = { draft = draft.copy(proxyUrl = it) },
                                label = "下载代理（可选）",
                                placeholder = "http://127.0.0.1:7890",
                                supportingText = "仅在安装 Node.js 和 Codex 时使用",
                                modifier = Modifier.fillMaxWidth().bringAboveKeyboard(),
                            )
                        }
                    }

                    ConnectionStatus(
                        connection = activeConnection,
                        onDisconnect = { onDisconnectProfile(draft.id) },
                    )

                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        OutlinedButton(
                            onClick = {
                                focusManager.clearFocus(force = true)
                                unsavedDrafts.remove(draft.id)
                                val normalized = draft.copy(port = draft.port.takeIf { it in 1..65535 } ?: 22)
                                draft = normalized
                                newDraftStarted = false
                                onSave(normalized)
                                editorVisible = false
                            },
                            shape = FieldShape,
                            modifier = Modifier.weight(1f).height(50.dp),
                        ) {
                            Icon(Icons.Default.Save, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(7.dp))
                            Text("保存")
                        }
                        Button(
                            onClick = {
                                focusManager.clearFocus(force = true)
                                if (activeConnection.phase == ConnectionPhase.Connected && !hasUnsavedChanges) {
                                    onSelectProfile(draft.id)
                                } else {
                                    unsavedDrafts.remove(draft.id)
                                    newDraftStarted = false
                                    onConnect(draft.copy(port = draft.port.takeIf { it in 1..65535 } ?: 22))
                                    editorVisible = false
                                }
                            },
                            enabled = draft.host.isNotBlank() && draft.username.isNotBlank() &&
                                activeConnection.phase !in setOf(
                                    ConnectionPhase.Connecting,
                                    ConnectionPhase.Installing,
                                    ConnectionPhase.Probing,
                                ),
                            shape = FieldShape,
                            modifier = Modifier.weight(1f).height(50.dp),
                        ) {
                            if (activeConnection.phase in setOf(
                                    ConnectionPhase.Connecting,
                                    ConnectionPhase.Installing,
                                )
                            ) {
                                CircularProgressIndicator(
                                    Modifier.size(19.dp),
                                    color = MaterialTheme.colorScheme.onPrimary,
                                    strokeWidth = 2.dp,
                                )
                            } else {
                                Icon(Icons.Default.Wifi, contentDescription = null, modifier = Modifier.size(18.dp))
                                Spacer(Modifier.width(7.dp))
                                Text(
                                    when {
                                        activeConnection.phase == ConnectionPhase.Connected && hasUnsavedChanges ->
                                            "保存并重连"
                                        activeConnection.phase == ConnectionPhase.Connected -> "进入"
                                        else -> "连接"
                                    },
                                )
                            }
                        }
                    }
                    if (savedDraft) {
                        TextButton(
                            onClick = { uninstallRequested = true },
                            enabled = !hasUnsavedChanges && activeConnection.phase !in setOf(
                                    ConnectionPhase.Connecting,
                                    ConnectionPhase.Installing,
                                    ConnectionPhase.Probing,
                                ),
                            modifier = Modifier.align(Alignment.CenterHorizontally),
                        ) {
                            Icon(
                                Icons.Default.DeleteForever,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.error,
                                modifier = Modifier.size(18.dp),
                            )
                            Spacer(Modifier.width(6.dp))
                            Text("卸载远端服务并断开", color = MaterialTheme.colorScheme.error)
                        }
                        TextButton(
                            onClick = { deleteRequested = true },
                            modifier = Modifier.align(Alignment.CenterHorizontally),
                        ) {
                            Icon(
                                Icons.Default.DeleteOutline,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.error,
                                modifier = Modifier.size(18.dp),
                            )
                            Spacer(Modifier.width(6.dp))
                            Text("删除服务器", color = MaterialTheme.colorScheme.error)
                        }
                    }
                    Spacer(Modifier.height(6.dp))
                        }
                    }
                    Spacer(Modifier.height(14.dp))
                }
            }
        }
    }

    if (blockingProfile != null && blockingConnection != null) {
        BackHandler { }
        Box(
            modifier = Modifier.fillMaxSize()
                .background(MaterialTheme.colorScheme.scrim.copy(alpha = 0.5f))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = {},
                )
                .semantics {
                    contentDescription = "正在连接服务器，暂时无法操作"
                },
            contentAlignment = Alignment.Center,
        ) {
            Surface(
                color = MaterialTheme.colorScheme.surface,
                shape = RoundedCornerShape(8.dp),
                tonalElevation = 6.dp,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 42.dp),
            ) {
                Column(
                    modifier = Modifier.padding(horizontal = 18.dp, vertical = 22.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(36.dp),
                        color = CodexAmber,
                        strokeWidth = 3.dp,
                    )
                    Text(
                        blockingProfile.name.ifBlank { "未命名服务器" },
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        if (connectedHandoffProfile != null && blockingProfile.id == connectedHandoffProfile.id) {
                            "正在打开会话列表"
                        } else {
                            blockingConnection.message.ifBlank { blockingConnection.shortLabel() }
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }

    if (showDebugLogs && state.debugModeEnabled) {
        DiagnosticLogSheet(
            onDismiss = { showDebugLogs = false },
            onDisable = {
                showDebugLogs = false
                onDisableDebugMode()
            },
        )
    }

    connectRequested?.let { profile ->
        AlertDialog(
            onDismissRequest = { connectRequested = null },
            title = { Text("连接服务器") },
            text = { Text("确定连接到“${profile.name.ifBlank { "未命名服务器" }}”吗？") },
            confirmButton = {
                TextButton(onClick = {
                    connectRequested = null
                    onConnect(profile.copy(port = profile.port.takeIf { it in 1..65535 } ?: 22))
                }) { Text("连接") }
            },
            dismissButton = {
                TextButton(onClick = { connectRequested = null }) { Text("取消") }
            },
        )
    }

    disconnectRequested?.let { profile ->
        AlertDialog(
            onDismissRequest = { disconnectRequested = null },
            title = { Text("断开服务器") },
            text = { Text("确定断开与“${profile.name.ifBlank { "未命名服务器" }}”的连接吗？") },
            confirmButton = {
                TextButton(onClick = {
                    disconnectRequested = null
                    onDisconnectProfile(profile.id)
                }) { Text("断开", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { disconnectRequested = null }) { Text("取消") }
            },
        )
    }

    if (uninstallRequested) {
        AlertDialog(
            onDismissRequest = { uninstallRequested = false },
            title = { Text("卸载远端 App Service？") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(
                        "将从“${savedProfile?.name.orEmpty()}”" +
                            "（${savedProfile?.username.orEmpty()}@${savedProfile?.host.orEmpty()}）删除本 App 管理的 " +
                            "Node.js 与 Codex 运行时，并断开连接。",
                    )
                    Text(
                        "不会删除 ~/.codex 中的会话或登录信息，也不会影响 VS Code Codex 和服务器上的其他 Codex 安装。",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    uninstallRequested = false
                    onUninstallRemote(draft.id)
                }) {
                    Text("卸载并断开", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { uninstallRequested = false }) { Text("取消") }
            },
        )
    }

    if (deleteRequested) {
        AlertDialog(
            onDismissRequest = { deleteRequested = false },
            title = { Text("删除服务器") },
            text = { Text("确定删除“${savedProfile?.name.orEmpty()}”吗？") },
            confirmButton = {
                TextButton(onClick = {
                    onDelete(draft.id)
                    unsavedDrafts.remove(draft.id)
                    draft = onNewProfile()
                    newDraftStarted = false
                    editorVisible = false
                    deleteRequested = false
                }) { Text("删除", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { deleteRequested = false }) { Text("取消") } },
        )
    }

    keyImportError?.let { message ->
        AlertDialog(
            onDismissRequest = { keyImportError = null },
            title = { Text("私钥导入失败") },
            text = { Text(message) },
            confirmButton = {
                TextButton(onClick = { keyImportError = null }) { Text("确定") }
            },
        )
    }
}

@Composable
private fun DebugLogBar(onOpen: () -> Unit, onShare: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onOpen)
            .padding(horizontal = 16.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            Icons.Default.BugReport,
            contentDescription = null,
            tint = CodexGreen,
            modifier = Modifier.size(21.dp),
        )
        Spacer(Modifier.width(11.dp))
        Column(Modifier.weight(1f)) {
            Text("Debug 模式", style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold)
            Text(
                "运行日志正在记录",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        IconButton(onClick = onShare, modifier = Modifier.size(40.dp)) {
            Icon(Icons.Default.Share, contentDescription = "分享诊断日志", modifier = Modifier.size(20.dp))
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DiagnosticLogSheet(onDismiss: () -> Unit, onDisable: () -> Unit) {
    val context = LocalContext.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var snapshot by remember { mutableStateOf(DiagnosticLogger.snapshot()) }
    var clearRequested by remember { mutableStateOf(false) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier.fillMaxWidth().navigationBarsPadding()
                .padding(start = 18.dp, end = 18.dp, bottom = 18.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.BugReport, contentDescription = null, tint = CodexGreen)
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text("诊断日志", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    Text(
                        "${formatLogSize(snapshot.bytes)} · 自动轮转",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                IconButton(onClick = { snapshot = DiagnosticLogger.snapshot() }) {
                    Icon(Icons.Default.Refresh, contentDescription = "刷新日志")
                }
            }

            Surface(
                color = Color(0xFF111111),
                shape = RoundedCornerShape(6.dp),
                modifier = Modifier.fillMaxWidth().height(260.dp)
                    .border(1.dp, CodexBorder, RoundedCornerShape(6.dp)),
            ) {
                SelectionContainer {
                    Text(
                        snapshot.preview.ifBlank { "暂无日志" },
                        modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                            .padding(11.dp),
                        style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedButton(onClick = { clearRequested = true }, modifier = Modifier.weight(1f)) {
                    Icon(Icons.Default.DeleteSweep, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(7.dp))
                    Text("清空")
                }
                Button(onClick = { shareDiagnosticLog(context) }, modifier = Modifier.weight(1f)) {
                    Icon(Icons.Default.Share, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(7.dp))
                    Text("分享")
                }
            }

            TextButton(onClick = onDisable, modifier = Modifier.align(Alignment.CenterHorizontally)) {
                Text("关闭 Debug 模式", color = MaterialTheme.colorScheme.error)
            }
        }
    }

    if (clearRequested) {
        AlertDialog(
            onDismissRequest = { clearRequested = false },
            title = { Text("清空诊断日志") },
            text = { Text("确定删除当前设备上的诊断日志吗？") },
            confirmButton = {
                TextButton(onClick = {
                    DiagnosticLogger.clear()
                    snapshot = DiagnosticLogger.snapshot()
                    clearRequested = false
                }) { Text("清空", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { clearRequested = false }) { Text("取消") }
            },
        )
    }
}

private fun shareDiagnosticLog(context: Context) {
    DiagnosticLogger.info("Debug", "diagnostic_log_share_requested")
    runCatching {
        val shareIntent = DiagnosticLogger.createShareIntent(context)
        context.startActivity(Intent.createChooser(shareIntent, "分享诊断日志"))
    }.onFailure {
        DiagnosticLogger.error("Debug", "diagnostic_log_share_failed", it)
        Toast.makeText(context, "无法打开系统分享", Toast.LENGTH_SHORT).show()
    }
}

private fun formatLogSize(bytes: Long): String = when {
    bytes >= 1024L * 1024L -> "%.1f MB".format(bytes / (1024f * 1024f))
    bytes >= 1024L -> "%.1f KB".format(bytes / 1024f)
    else -> "$bytes B"
}

@Composable
private fun ServerSessionPanel(
    profiles: List<ServerProfile>,
    pendingNewDraft: ServerProfile?,
    connectedCount: Int,
    connectionFor: (ServerProfile) -> ConnectionState,
    onSettings: (ServerProfile) -> Unit,
    onOpen: (ServerProfile, ConnectionState) -> Unit,
    onDisconnect: (ServerProfile) -> Unit,
    onAdd: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val shape = RoundedCornerShape(10.dp)
    Surface(
        color = MaterialTheme.colorScheme.surface,
        shape = shape,
        modifier = modifier.border(1.dp, CodexBorder, shape),
    ) {
        Column(Modifier.animateContentSize()) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(start = 12.dp, end = 6.dp, top = 8.dp, bottom = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    Icons.Default.Star,
                    contentDescription = null,
                    tint = CodexAmber,
                    modifier = Modifier.size(22.dp),
                )
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        "服务器会话",
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        if (profiles.isEmpty()) {
                            "添加第一台 SSH 服务器"
                        } else if (pendingNewDraft != null) {
                            "${profiles.size} 台服务器 · 1 个草稿"
                        } else {
                            "${profiles.size} 台服务器 · $connectedCount 台已连接"
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                IconButton(onClick = onAdd, modifier = Modifier.size(40.dp)) {
                    Icon(Icons.Default.Add, contentDescription = "添加服务器", modifier = Modifier.size(21.dp))
                }
            }
            HorizontalDivider(color = CodexBorder)
            profiles.forEachIndexed { index, profile ->
                val connection = connectionFor(profile)
                ServerSessionRow(
                    profile = profile,
                    connection = connection,
                    unsaved = false,
                    onSettings = { onSettings(profile) },
                    onOpen = { onOpen(profile, connection) },
                    onDisconnect = { onDisconnect(profile) },
                )
                if (index != profiles.lastIndex || pendingNewDraft != null) {
                    HorizontalDivider(color = CodexBorder.copy(alpha = 0.72f), modifier = Modifier.padding(start = 52.dp))
                }
            }
            pendingNewDraft?.let { pending ->
                ServerSessionRow(
                    profile = pending,
                    connection = ConnectionState(),
                    unsaved = true,
                    onSettings = { onSettings(pending) },
                    onOpen = null,
                    onDisconnect = null,
                )
            }
        }
    }
}

@Composable
private fun ServerSessionRow(
    profile: ServerProfile,
    connection: ConnectionState,
    unsaved: Boolean,
    onSettings: () -> Unit,
    onOpen: (() -> Unit)?,
    onDisconnect: (() -> Unit)?,
) {
    val name = profile.name.trim()
    val title = name.ifBlank { if (unsaved) "新服务器" else "未命名服务器" }
    val busy = connection.phase in setOf(
        ConnectionPhase.Probing,
        ConnectionPhase.Connecting,
        ConnectionPhase.Installing,
    )
    Row(
        modifier = Modifier.fillMaxWidth()
            .clickable(enabled = onOpen != null && !busy, onClick = { onOpen?.invoke() })
            .padding(horizontal = 11.dp, vertical = 10.dp)
            .semantics {
                contentDescription = buildString {
                    append(if (unsaved) "未保存服务器" else "服务器")
                    append("：")
                    append(title)
                    append("，")
                    append(connection.message)
                }
            },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Surface(
            color = CodexSurfaceRaised,
            contentColor = CodexAmber,
            shape = RoundedCornerShape(5.dp),
            modifier = Modifier.size(28.dp),
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(Icons.Default.Key, contentDescription = null, modifier = Modifier.size(16.dp))
            }
        }
        Spacer(Modifier.width(6.dp))
        Box(
            modifier = Modifier.size(14.dp),
            contentAlignment = Alignment.Center,
        ) {
            if (busy) {
                CircularProgressIndicator(
                    modifier = Modifier.size(14.dp),
                    color = CodexAmber,
                    strokeWidth = 1.6.dp,
                )
            } else {
                Box(
                    Modifier.size(8.dp).clip(CircleShape).background(
                        if (connection.phase == ConnectionPhase.Connected) {
                            CodexGreen
                        } else {
                            CodexMuted.copy(alpha = 0.62f)
                        },
                    ),
                )
            }
        }
        Spacer(Modifier.width(6.dp))
        Column(Modifier.weight(1f)) {
            Text(
                title,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                "${profile.username.ifBlank { "root" }} · ${connection.shortLabel()}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (connection.phase == ConnectionPhase.Connected && onDisconnect != null) {
            Spacer(Modifier.width(6.dp))
            OutlinedButton(
                onClick = onDisconnect,
                shape = FieldShape,
                colors = ButtonDefaults.outlinedButtonColors(
                    contentColor = MaterialTheme.colorScheme.error,
                ),
                border = BorderStroke(1.dp, MaterialTheme.colorScheme.error),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 9.dp),
                modifier = Modifier.height(40.dp),
            ) {
                Text("断开", maxLines = 1)
            }
        }
        Spacer(Modifier.width(6.dp))
        ServerSettingsButton(onClick = onSettings)
    }
}

private fun ConnectionState.shortLabel(): String = when (phase) {
    ConnectionPhase.Disconnected -> "未连接"
    ConnectionPhase.Probing -> "读取指纹"
    ConnectionPhase.Connecting -> "连接中"
    ConnectionPhase.Installing -> "安装中"
    ConnectionPhase.Connected -> "已连接"
    ConnectionPhase.Failed -> "连接失败"
}

@Composable
private fun ServerSettingsButton(onClick: () -> Unit) {
    IconButton(
        onClick = onClick,
        modifier = Modifier.size(width = 42.dp, height = 40.dp).border(1.dp, CodexBorder, FieldShape),
    ) {
        Icon(
            Icons.Default.Settings,
            contentDescription = "服务器设置",
            modifier = Modifier.size(18.dp),
        )
    }
}

@Composable
private fun EmptyServerState(onAdd: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 28.dp, vertical = 40.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Surface(
            color = CodexSurfaceRaised,
            contentColor = CodexAmber,
            shape = CircleShape,
            modifier = Modifier.size(54.dp),
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(Icons.Default.Dns, contentDescription = null, modifier = Modifier.size(26.dp))
            }
        }
        Text("还没有服务器", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Text(
            "添加 SSH 服务器后，可在这里直接连接、断开或进入设置。",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Button(onClick = onAdd, shape = FieldShape) {
            Icon(Icons.Default.Add, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(7.dp))
            Text("添加服务器")
        }
    }
}

@Composable
private fun ConnectionDot(phase: ConnectionPhase, loadingSize: Dp) {
    if (phase in setOf(ConnectionPhase.Connecting, ConnectionPhase.Installing, ConnectionPhase.Probing)) {
        CircularProgressIndicator(Modifier.size(loadingSize), strokeWidth = 1.5.dp)
    } else {
        Box(
            Modifier.size(8.dp).clip(CircleShape).background(
                when (phase) {
                    ConnectionPhase.Connected -> CodexGreen
                    ConnectionPhase.Failed -> MaterialTheme.colorScheme.error
                    else -> CodexMuted.copy(alpha = 0.62f)
                },
            ),
        )
    }
}

@Composable
private fun SectionHeading(title: String, detail: String) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
        Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.width(9.dp))
        Text(
            detail,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@Composable
private fun ServerTextField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    modifier: Modifier = Modifier,
    leadingIcon: ImageVector? = null,
    placeholder: String? = null,
    supportingText: String? = null,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    visualTransformation: VisualTransformation = VisualTransformation.None,
    trailingIcon: (@Composable () -> Unit)? = null,
    singleLine: Boolean = true,
    minLines: Int = 1,
    maxLines: Int = 1,
    monospace: Boolean = false,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        leadingIcon = leadingIcon?.let { icon ->
            { Icon(icon, contentDescription = null, modifier = Modifier.size(19.dp)) }
        },
        placeholder = placeholder?.let { placeholderValue -> { Text(placeholderValue) } },
        supportingText = supportingText?.let { supportingValue -> { Text(supportingValue) } },
        keyboardOptions = keyboardOptions,
        visualTransformation = visualTransformation,
        trailingIcon = trailingIcon,
        singleLine = singleLine,
        minLines = minLines,
        maxLines = maxLines,
        textStyle = if (monospace) {
            MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace)
        } else {
            MaterialTheme.typography.bodyMedium
        },
        shape = FieldShape,
        colors = OutlinedTextFieldDefaults.colors(
            focusedBorderColor = MaterialTheme.colorScheme.onSurfaceVariant,
            unfocusedBorderColor = CodexBorder,
        ),
        modifier = modifier,
    )
}

@Composable
private fun FingerprintRow(
    fingerprint: String,
    probing: Boolean,
    enabled: Boolean,
    onProbe: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(start = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            Icons.Default.Fingerprint,
            contentDescription = null,
            modifier = Modifier.size(20.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text("SSH 主机指纹", style = MaterialTheme.typography.labelLarge)
            Text(
                fingerprint.ifBlank { "尚未核对" },
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                color = if (fingerprint.isBlank()) MaterialTheme.colorScheme.onSurfaceVariant else CodexGreen,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        IconButton(onClick = onProbe, enabled = enabled && !probing) {
            if (probing) {
                CircularProgressIndicator(Modifier.size(19.dp), strokeWidth = 2.dp)
            } else {
                Icon(Icons.Default.Fingerprint, contentDescription = "读取主机指纹")
            }
        }
    }
}

@Composable
private fun ConnectionStatus(connection: ConnectionState, onDisconnect: () -> Unit) {
    val shape = RoundedCornerShape(7.dp)
    Surface(
        color = CodexSurfaceRaised,
        shape = shape,
        modifier = Modifier.fillMaxWidth().border(1.dp, CodexBorder, shape),
    ) {
        Row(
            modifier = Modifier.padding(start = 13.dp, end = 5.dp, top = 10.dp, bottom = 10.dp)
                .semantics { contentDescription = "SSH 连接状态：${connection.message}" },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ConnectionDot(connection.phase, loadingSize = 18.dp)
            Spacer(Modifier.width(11.dp))
            Column(Modifier.weight(1f)) {
                Text(connection.message, style = MaterialTheme.typography.bodyMedium)
                connection.cliVersion?.takeIf { it.isNotBlank() }?.let { version ->
                    Text(
                        version,
                        style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            if (connection.phase == ConnectionPhase.Connected) {
                IconButton(onClick = onDisconnect, modifier = Modifier.size(40.dp)) {
                    Icon(Icons.Default.Close, contentDescription = "断开此服务器")
                }
            }
        }
    }
}

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
private fun Modifier.bringAboveKeyboard(): Modifier = composed {
    val requester = remember { BringIntoViewRequester() }
    var focused by remember { mutableStateOf(false) }
    LaunchedEffect(focused) {
        if (focused) {
            // Wait for adjustResize/IME insets to settle, then bring the field into the resized viewport.
            delay(220)
            requester.bringIntoView()
        }
    }
    bringIntoViewRequester(requester).onFocusChanged { focusState ->
        focused = focusState.isFocused
    }
}

/** Keeps non-sensitive server form fields across Activity recreation without leaking credentials. */
private val ServerProfileSaver = Saver<ServerProfile, ArrayList<String>>(
    save = { profile ->
        arrayListOf(
            profile.id,
            profile.name,
            profile.host,
            profile.port.toString(),
            profile.username,
            profile.authMode.name,
            SAVED_STATE_CREDENTIAL_OMITTED,
            SAVED_STATE_CREDENTIAL_OMITTED,
            SAVED_STATE_CREDENTIAL_OMITTED,
            profile.hostFingerprint,
            profile.workspace,
            profile.proxyUrl,
            profile.approvalMode.name,
            profile.remoteCommand,
            profile.workspacePromptShown.toString(),
            profile.preferredModel,
            profile.preferredEffort,
        )
    },
    restore = { values ->
        if (values.size != SAVED_PROFILE_FIELD_COUNT) {
            null
        } else {
            ServerProfile(
                id = values[0],
                name = values[1],
                host = values[2],
                port = values[3].toIntOrNull() ?: 22,
                username = values[4],
                authMode = runCatching { AuthMode.valueOf(values[5]) }.getOrDefault(AuthMode.PrivateKey),
                password = values[6],
                privateKeyPem = values[7],
                privateKeyPassphrase = values[8],
                hostFingerprint = values[9],
                workspace = values[10],
                proxyUrl = values[11],
                approvalMode = runCatching {
                    top.asdb.codexremote.data.ApprovalMode.valueOf(values[12])
                }.getOrDefault(top.asdb.codexremote.data.ApprovalMode.RequestApproval),
                remoteCommand = values[13],
                workspacePromptShown = values[14].toBooleanStrictOrNull() ?: false,
                preferredModel = values[15],
                preferredEffort = values[16],
            )
        }
    },
)

private const val SAVED_PROFILE_FIELD_COUNT = 17
private const val SAVED_STATE_CREDENTIAL_OMITTED = "\u0000codex-remote-credential-omitted\u0000"
private const val MAX_PRIVATE_KEY_BYTES = 128 * 1024
