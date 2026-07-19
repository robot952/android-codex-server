package top.asdb.codexremote.ui

import androidx.activity.compose.BackHandler
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
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Fingerprint
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Security
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import top.asdb.codexremote.AppViewModel
import top.asdb.codexremote.data.AppScreen
import top.asdb.codexremote.data.AppUiState
import top.asdb.codexremote.data.ApprovalKind
import top.asdb.codexremote.data.ApprovalPrompt
import top.asdb.codexremote.ui.theme.CodexBorder

@Composable
fun CodexRemoteApp(viewModel: AppViewModel) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }

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

    BackHandler(enabled = state.screen != AppScreen.Servers) {
        when (state.screen) {
            AppScreen.Work -> viewModel.backToThreads()
            AppScreen.Threads -> viewModel.disconnect()
            AppScreen.Servers -> Unit
        }
    }

    Box(Modifier.fillMaxSize()) {
        when (state.screen) {
            AppScreen.Servers -> ServerScreen(
                state = state,
                onSelectProfile = viewModel::selectProfile,
                onNewProfile = viewModel::newProfile,
                onSave = viewModel::saveProfile,
                onDelete = viewModel::deleteProfile,
                onProbeFingerprint = viewModel::probeFingerprint,
                onConnect = viewModel::connect,
            )

            AppScreen.Threads -> ThreadListScreen(
                state = state,
                onSearchChange = viewModel::setThreadSearch,
                onRefresh = viewModel::refreshThreads,
                onCreate = viewModel::createThread,
                onOpen = viewModel::openThread,
                onSelectWorkspace = viewModel::showWorkspacePicker,
                onDisconnect = viewModel::disconnect,
            )

            AppScreen.Work -> WorkScreen(
                state = state,
                onBack = viewModel::backToThreads,
                onSend = viewModel::send,
                onStop = viewModel::stopTurn,
                onReview = viewModel::reviewChanges,
                onArchive = viewModel::archiveActiveThread,
                onRollback = viewModel::rollbackActiveThread,
                onRename = viewModel::renameActiveThread,
                onUpload = viewModel::uploadAttachment,
                onRemoveAttachment = viewModel::removeAttachment,
                onSelectModel = viewModel::selectModel,
                onSelectEffort = viewModel::selectEffort,
                onSelectApprovalMode = viewModel::selectApprovalMode,
                onSelectWorkspace = viewModel::showWorkspacePicker,
            )
        }
        SnackbarHost(
            hostState = snackbar,
            // The composer can grow to several rows, so place work-screen messages
            // below the app bar instead of guessing its current height.
            modifier = if (state.screen == AppScreen.Work) {
                Modifier.align(Alignment.TopCenter).statusBarsPadding().padding(
                    start = 12.dp,
                    end = 12.dp,
                    top = 68.dp,
                )
            } else {
                Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(12.dp)
            },
        )
    }

    state.pendingFingerprint?.let { fingerprint ->
        AlertDialog(
            onDismissRequest = viewModel::rejectFingerprint,
            icon = { Icon(Icons.Default.Fingerprint, contentDescription = null) },
            title = { Text("核对 SSH 主机指纹") },
            text = {
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
            },
            confirmButton = { TextButton(onClick = viewModel::trustFingerprint) { Text("信任并连接") } },
            dismissButton = { TextButton(onClick = viewModel::rejectFingerprint) { Text("取消") } },
        )
    }

    state.remoteSetup?.let { setup ->
        AlertDialog(
            onDismissRequest = {
                if (!state.setupInProgress) viewModel.cancelRemoteSetup()
            },
            icon = { Icon(Icons.Default.Download, contentDescription = null) },
            title = { Text(setup.title) },
            text = {
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
                    if (state.setupInProgress) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            CircularProgressIndicator(modifier = Modifier.width(22.dp), strokeWidth = 2.dp)
                            Spacer(Modifier.width(10.dp))
                            Text(state.setupProgress.ifBlank { "正在安装" })
                        }
                    }
                }
            },
            confirmButton = {
                Button(
                    onClick = viewModel::installRemoteSetup,
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

    state.approval?.let { prompt ->
        ApprovalDialog(
            prompt = prompt,
            onApprove = { answer -> viewModel.answerApproval(true, answer) },
            onDecline = viewModel::dismissApproval,
        )
    }
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
