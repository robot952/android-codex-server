package top.asdb.codexremote.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Fingerprint
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Save
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import top.asdb.codexremote.data.AppUiState
import top.asdb.codexremote.data.AuthMode
import top.asdb.codexremote.data.ConnectionPhase
import top.asdb.codexremote.data.ServerProfile
import top.asdb.codexremote.ui.theme.CodexBorder
import top.asdb.codexremote.ui.theme.CodexGreen

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ServerScreen(
    state: AppUiState,
    onSelectProfile: (String) -> Unit,
    onNewProfile: () -> ServerProfile,
    onSave: (ServerProfile) -> Unit,
    onDelete: (String) -> Unit,
    onProbeFingerprint: (ServerProfile) -> Unit,
    onConnect: (ServerProfile) -> Unit,
) {
    val selected = state.profiles.firstOrNull { it.id == state.selectedProfileId }
    var draft by remember(selected?.id, selected?.hashCode()) {
        mutableStateOf(selected ?: onNewProfile())
    }
    var advanced by remember { mutableStateOf(false) }
    var passwordVisible by remember { mutableStateOf(false) }
    var deleteRequested by remember { mutableStateOf(false) }
    var keyImportError by remember { mutableStateOf<String?>(null) }
    val context = LocalContext.current
    val keyPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        runCatching {
            context.contentResolver.openInputStream(uri)?.use { stream ->
                val bytes = stream.readBytes()
                require(bytes.size <= 128 * 1024) { "私钥文件过大" }
                bytes.toString(Charsets.UTF_8)
            } ?: error("无法读取私钥")
        }.onSuccess { pem ->
            draft = draft.copy(privateKeyPem = pem)
        }.onFailure { error ->
            keyImportError = error.message ?: "无法导入私钥"
        }
    }

    Scaffold(
        modifier = Modifier.fillMaxSize().statusBarsPadding(),
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text("CODEX REMOTE", fontWeight = FontWeight.SemiBold)
                        Text("SSH 服务器", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.padding(padding).navigationBarsPadding().fillMaxSize()
                .verticalScroll(rememberScrollState()),
        ) {
            if (state.profiles.isNotEmpty()) {
                Row(
                    modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    state.profiles.forEach { profile ->
                        FilterChip(
                            selected = profile.id == draft.id,
                            onClick = { onSelectProfile(profile.id) },
                            label = { Text(profile.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                            leadingIcon = { Icon(Icons.Default.Terminal, contentDescription = null) },
                        )
                    }
                    IconButton(onClick = { draft = onNewProfile() }) {
                        Icon(Icons.Default.Add, contentDescription = "添加服务器")
                    }
                }
                HorizontalDivider(color = CodexBorder)
            }

            Column(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 18.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Text("连接", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                OutlinedTextField(
                    value = draft.name,
                    onValueChange = { draft = draft.copy(name = it) },
                    label = { Text("名称") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedTextField(
                        value = draft.host,
                        onValueChange = { draft = draft.copy(host = it) },
                        label = { Text("服务器地址") },
                        singleLine = true,
                        modifier = Modifier.weight(1f),
                    )
                    OutlinedTextField(
                        value = draft.port.toString(),
                        onValueChange = { value -> value.toIntOrNull()?.let { draft = draft.copy(port = it) } },
                        label = { Text("端口") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        modifier = Modifier.width(94.dp),
                    )
                }
                OutlinedTextField(
                    value = draft.username,
                    onValueChange = { draft = draft.copy(username = it) },
                    label = { Text("用户名") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )

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
                                )
                            },
                            label = { Text(if (mode == AuthMode.PrivateKey) "私钥" else "密码") },
                        )
                    }
                }

                if (draft.authMode == AuthMode.Password) {
                    OutlinedTextField(
                        value = draft.password,
                        onValueChange = { draft = draft.copy(password = it) },
                        label = { Text("SSH 密码") },
                        singleLine = true,
                        visualTransformation = if (passwordVisible) VisualTransformation.None else PasswordVisualTransformation(),
                        trailingIcon = {
                            IconButton(onClick = { passwordVisible = !passwordVisible }) {
                                Icon(
                                    if (passwordVisible) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                                    contentDescription = if (passwordVisible) "隐藏密码" else "显示密码",
                                )
                            }
                        },
                        modifier = Modifier.fillMaxWidth(),
                    )
                } else {
                    OutlinedButton(
                        onClick = { keyPicker.launch(arrayOf("application/x-pem-file", "text/plain", "*/*")) },
                        modifier = Modifier.fillMaxWidth().height(52.dp),
                    ) {
                        Icon(Icons.Default.Key, contentDescription = null)
                        Spacer(Modifier.width(8.dp))
                        Text(if (draft.privateKeyPem.isBlank()) "选择 SSH 私钥" else "已导入 SSH 私钥")
                    }
                    if (draft.privateKeyPem.isNotBlank()) {
                        OutlinedTextField(
                            value = draft.privateKeyPassphrase,
                            onValueChange = { draft = draft.copy(privateKeyPassphrase = it) },
                            label = { Text("私钥口令（可选）") },
                            singleLine = true,
                            visualTransformation = PasswordVisualTransformation(),
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }

                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("SSH 主机指纹", style = MaterialTheme.typography.labelLarge)
                        Text(
                            draft.hostFingerprint.ifBlank { "尚未核对" },
                            style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                            color = if (draft.hostFingerprint.isBlank()) {
                                MaterialTheme.colorScheme.onSurfaceVariant
                            } else CodexGreen,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    IconButton(
                        onClick = { onProbeFingerprint(draft) },
                        enabled = draft.host.isNotBlank() && draft.username.isNotBlank() &&
                            state.connection.phase != ConnectionPhase.Probing,
                    ) {
                        if (state.connection.phase == ConnectionPhase.Probing) {
                            CircularProgressIndicator(Modifier.width(20.dp), strokeWidth = 2.dp)
                        } else {
                            Icon(Icons.Default.Fingerprint, contentDescription = "读取主机指纹")
                        }
                    }
                }

                TextButton(onClick = { advanced = !advanced }, modifier = Modifier.align(Alignment.Start)) {
                    Text("高级")
                    Icon(if (advanced) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                        contentDescription = null)
                }
                AnimatedVisibility(advanced) {
                    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                        OutlinedTextField(
                            value = draft.workspace,
                            onValueChange = { draft = draft.copy(workspace = it) },
                            label = { Text("默认工作目录") },
                            placeholder = { Text("/home/user/project") },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                        OutlinedTextField(
                            value = draft.remoteCommand,
                            onValueChange = { draft = draft.copy(remoteCommand = it) },
                            label = { Text("Codex app-server 命令") },
                            textStyle = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                            minLines = 2,
                            maxLines = 4,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }

                Box(
                    modifier = Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceVariant)
                        .padding(horizontal = 12.dp, vertical = 10.dp),
                ) {
                    Row(
                        modifier = Modifier.semantics {
                            contentDescription = "SSH 连接状态：${state.connection.message}"
                        },
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.Default.Wifi, contentDescription = null,
                            tint = if (state.connection.phase == ConnectionPhase.Failed) {
                                MaterialTheme.colorScheme.error
                            } else MaterialTheme.colorScheme.onSurfaceVariant)
                        Spacer(Modifier.width(10.dp))
                        Text(state.connection.message, style = MaterialTheme.typography.bodySmall)
                    }
                }

                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedButton(
                        onClick = { onSave(draft) },
                        modifier = Modifier.weight(1f).height(50.dp),
                    ) {
                        Icon(Icons.Default.Save, contentDescription = null)
                        Spacer(Modifier.width(7.dp))
                        Text("保存")
                    }
                    Button(
                        onClick = { onConnect(draft) },
                        enabled = draft.host.isNotBlank() && draft.username.isNotBlank() &&
                            state.connection.phase !in setOf(
                                ConnectionPhase.Connecting,
                                ConnectionPhase.Installing,
                                ConnectionPhase.Probing,
                            ),
                        modifier = Modifier.weight(1f).height(50.dp),
                    ) {
                        if (state.connection.phase in setOf(
                                ConnectionPhase.Connecting,
                                ConnectionPhase.Installing,
                            )
                        ) {
                            CircularProgressIndicator(Modifier.width(20.dp), strokeWidth = 2.dp)
                        } else {
                            Icon(Icons.Default.Wifi, contentDescription = null)
                            Spacer(Modifier.width(7.dp))
                            Text("连接")
                        }
                    }
                }
                if (state.profiles.any { it.id == draft.id }) {
                    TextButton(
                        onClick = { deleteRequested = true },
                        modifier = Modifier.align(Alignment.CenterHorizontally),
                    ) {
                        Icon(Icons.Default.DeleteOutline, contentDescription = null,
                            tint = MaterialTheme.colorScheme.error)
                        Spacer(Modifier.width(6.dp))
                        Text("删除服务器", color = MaterialTheme.colorScheme.error)
                    }
                }
            }
        }
    }

    if (deleteRequested) {
        AlertDialog(
            onDismissRequest = { deleteRequested = false },
            title = { Text("删除服务器") },
            text = { Text(draft.name) },
            confirmButton = {
                TextButton(onClick = {
                    onDelete(draft.id)
                    draft = onNewProfile()
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
