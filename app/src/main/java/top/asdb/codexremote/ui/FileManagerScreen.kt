package top.asdb.codexremote.ui

import android.content.Context
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.ContentCut
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import top.asdb.codexremote.data.AppUiState
import top.asdb.codexremote.data.RemoteFileEntry
import top.asdb.codexremote.data.RemoteFileKind
import top.asdb.codexremote.data.RemoteFileTransferMode
import top.asdb.codexremote.ui.theme.CodexBorder
import top.asdb.codexremote.ui.theme.CodexGreen
import top.asdb.codexremote.ui.theme.CodexSurfaceRaised
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun FileManagerScreen(
    state: AppUiState,
    onBack: () -> Unit,
    onBrowse: (String) -> Unit,
    onRefresh: () -> Unit,
    onUpload: (Context, List<Uri>) -> Unit,
    onDownload: (Context, String, Uri) -> Unit,
    onRename: (RemoteFileEntry, String) -> Unit,
    onDelete: (List<RemoteFileEntry>) -> Unit,
    onCopy: (List<RemoteFileEntry>) -> Unit,
    onCut: (List<RemoteFileEntry>) -> Unit,
    onPaste: () -> Unit,
) {
    val context = LocalContext.current
    val busy = state.fileManagerLoading || state.fileManagerOperation != null
    var selectedPaths by remember(state.fileManagerCurrentPath) { mutableStateOf<Set<String>>(emptySet()) }
    var actionEntries by remember { mutableStateOf<List<RemoteFileEntry>?>(null) }
    var renameEntry by remember { mutableStateOf<RemoteFileEntry?>(null) }
    var deleteEntries by remember { mutableStateOf<List<RemoteFileEntry>?>(null) }
    var pendingDownload by remember { mutableStateOf<RemoteFileEntry?>(null) }
    var moreVisible by remember { mutableStateOf(false) }

    val selectedEntries = state.fileManagerEntries.filter { it.path in selectedPaths }
    val uploadDocuments = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isNotEmpty()) onUpload(context, uris)
    }
    val createDocument = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/octet-stream"),
    ) { uri ->
        val entry = pendingDownload
        pendingDownload = null
        if (uri != null && entry != null) onDownload(context, entry.path, uri)
    }
    fun requestDownload(entry: RemoteFileEntry) {
        if (entry.kind != RemoteFileKind.File || busy) return
        pendingDownload = entry
        createDocument.launch(entry.name)
    }
    fun openActions(entries: List<RemoteFileEntry>) {
        if (entries.isEmpty() || busy) return
        actionEntries = entries
    }

    Scaffold(
        modifier = Modifier.fillMaxSize().statusBarsPadding(),
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(
                            if (selectedEntries.isEmpty()) "文件管理" else "已选择 ${selectedEntries.size} 项",
                            style = MaterialTheme.typography.titleMedium,
                        )
                        state.fileManagerOperation?.let { operation ->
                            Text(
                                operation,
                                style = MaterialTheme.typography.labelSmall,
                                color = CodexGreen,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                },
                navigationIcon = {
                    IconButton(
                        onClick = {
                            if (selectedEntries.isEmpty()) onBack() else selectedPaths = emptySet()
                        },
                    ) {
                        Icon(
                            if (selectedEntries.isEmpty()) Icons.AutoMirrored.Filled.ArrowBack else Icons.Default.Close,
                            contentDescription = if (selectedEntries.isEmpty()) "返回会话" else "取消选择",
                        )
                    }
                },
                actions = {
                    if (selectedEntries.isNotEmpty()) {
                        IconButton(onClick = { openActions(selectedEntries) }, enabled = !busy) {
                            Icon(Icons.Default.MoreVert, contentDescription = "所选文件操作")
                        }
                    }
                    IconButton(onClick = onRefresh, enabled = !busy) {
                        if (state.fileManagerLoading) {
                            CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                        } else {
                            Icon(Icons.Default.Refresh, contentDescription = "刷新目录")
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = androidx.compose.ui.graphics.Color.Transparent),
            )
        },
        floatingActionButton = {
            Box {
                FloatingActionButton(
                    onClick = { moreVisible = true },
                    containerColor = CodexSurfaceRaised,
                    contentColor = MaterialTheme.colorScheme.onSurface,
                ) {
                    Icon(Icons.Default.MoreVert, contentDescription = "更多文件操作")
                }
                DropdownMenu(
                    expanded = moreVisible,
                    onDismissRequest = { moreVisible = false },
                ) {
                    DropdownMenuItem(
                        text = { Text("上传文件") },
                        leadingIcon = { Icon(Icons.Default.ArrowUpward, contentDescription = null) },
                        enabled = !busy,
                        onClick = {
                            moreVisible = false
                            uploadDocuments.launch(arrayOf("*/*"))
                        },
                    )
                    val downloadable = selectedEntries.singleOrNull()?.takeIf { it.kind == RemoteFileKind.File }
                    DropdownMenuItem(
                        text = { Text("下载所选文件") },
                        leadingIcon = { Icon(Icons.Default.ArrowDownward, contentDescription = null) },
                        enabled = !busy && downloadable != null,
                        onClick = {
                            moreVisible = false
                            downloadable?.let(::requestDownload)
                            selectedPaths = emptySet()
                        },
                    )
                    DropdownMenuItem(
                        text = {
                            Text(
                                when (state.fileManagerClipboard?.mode) {
                                    RemoteFileTransferMode.Copy -> "粘贴复制项"
                                    RemoteFileTransferMode.Move -> "粘贴剪切项"
                                    null -> "粘贴"
                                },
                            )
                        },
                        leadingIcon = { Icon(Icons.Default.ContentPaste, contentDescription = null) },
                        enabled = !busy && state.fileManagerClipboard != null,
                        onClick = {
                            moreVisible = false
                            onPaste()
                        },
                    )
                }
            }
        },
    ) { padding ->
        Column(
            modifier = Modifier.padding(padding).fillMaxSize(),
        ) {
            SelectionContainer {
                Text(
                    state.fileManagerCurrentPath.ifBlank { "正在打开目录" },
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 8.dp),
                    style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            state.fileManagerClipboard?.let { clipboard ->
                Row(
                    modifier = Modifier.fillMaxWidth().background(CodexSurfaceRaised)
                        .padding(horizontal = 18.dp, vertical = 7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        if (clipboard.mode == RemoteFileTransferMode.Copy) {
                            Icons.Default.ContentCopy
                        } else {
                            Icons.Default.ContentCut
                        },
                        contentDescription = null,
                        modifier = Modifier.size(16.dp),
                        tint = CodexGreen,
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        "${clipboard.entries.size} 项待${if (clipboard.mode == RemoteFileTransferMode.Copy) "复制" else "移动"}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            state.fileManagerOperation?.let {
                LinearProgressIndicator(
                    modifier = Modifier.fillMaxWidth(),
                    color = CodexGreen,
                    trackColor = CodexBorder,
                )
            }
            state.fileManagerError?.takeIf { it.isNotBlank() }?.let { error ->
                Text(
                    error,
                    modifier = Modifier.padding(horizontal = 18.dp, vertical = 8.dp),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                )
            }
            Box(Modifier.fillMaxSize()) {
                LazyColumn(Modifier.fillMaxSize()) {
                    state.fileManagerParentPath?.let { parent ->
                        item(key = "parent:$parent") {
                            ParentDirectoryRow(onClick = { if (!busy) onBrowse(parent) })
                            HorizontalDivider(color = CodexBorder)
                        }
                    }
                    items(state.fileManagerEntries, key = RemoteFileEntry::path) { entry ->
                        RemoteFileRow(
                            entry = entry,
                            selected = entry.path in selectedPaths,
                            enabled = !busy,
                            onClick = {
                                if (selectedPaths.isNotEmpty()) {
                                    selectedPaths = selectedPaths.toggle(entry.path)
                                } else if (entry.kind == RemoteFileKind.Directory) {
                                    onBrowse(entry.path)
                                }
                            },
                            onLongClick = {
                                val updated = selectedPaths + entry.path
                                selectedPaths = updated
                                openActions(state.fileManagerEntries.filter { it.path in updated })
                            },
                        )
                        HorizontalDivider(modifier = Modifier.padding(start = 54.dp), color = CodexBorder)
                    }
                }
                if (state.fileManagerLoading) {
                    CircularProgressIndicator(
                        modifier = Modifier.align(Alignment.Center).size(28.dp),
                        color = CodexGreen,
                        strokeWidth = 2.dp,
                    )
                } else if (state.fileManagerEntries.isEmpty() && state.fileManagerError == null) {
                    Text(
                        "当前目录为空",
                        modifier = Modifier.align(Alignment.Center),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }

    actionEntries?.let { entries ->
        FileActionMenu(
            entries = entries,
            onDismiss = { actionEntries = null },
            onDownload = {
                actionEntries = null
                requestDownload(it)
                selectedPaths = emptySet()
            },
            onRename = {
                actionEntries = null
                renameEntry = it
            },
            onCopy = {
                actionEntries = null
                selectedPaths = emptySet()
                onCopy(entries)
            },
            onCut = {
                actionEntries = null
                selectedPaths = emptySet()
                onCut(entries)
            },
            onDelete = {
                actionEntries = null
                deleteEntries = entries
            },
        )
    }
    renameEntry?.let { entry ->
        RenameRemoteFileDialog(
            entry = entry,
            onDismiss = { renameEntry = null },
            onConfirm = { name ->
                renameEntry = null
                selectedPaths = emptySet()
                onRename(entry, name)
            },
        )
    }
    deleteEntries?.let { entries ->
        AlertDialog(
            onDismissRequest = { deleteEntries = null },
            title = { Text(if (entries.size == 1) "删除 ${entries.first().name}" else "删除 ${entries.size} 项") },
            text = { Text("删除后无法恢复。目录及其内容会一并删除。") },
            confirmButton = {
                TextButton(
                    onClick = {
                        deleteEntries = null
                        selectedPaths = emptySet()
                        onDelete(entries)
                    },
                ) {
                    Text("删除", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { deleteEntries = null }) { Text("取消") } },
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun RemoteFileRow(
    entry: RemoteFileEntry,
    selected: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth()
            .background(if (selected) CodexSurfaceRaised else androidx.compose.ui.graphics.Color.Transparent)
            .combinedClickable(enabled = enabled, onClick = onClick, onLongClick = onLongClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = fileIcon(entry.kind),
            contentDescription = null,
            modifier = Modifier.size(22.dp),
            tint = if (entry.kind == RemoteFileKind.Directory) CodexGreen else MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(
                entry.name,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = if (entry.kind == RemoteFileKind.Directory) FontWeight.Medium else FontWeight.Normal,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            val detail = buildList {
                add(fileKindLabel(entry.kind))
                if (entry.kind == RemoteFileKind.File) add(formatRemoteFileSize(entry.sizeBytes))
                entry.permissions.takeIf { it.isNotBlank() }?.let(::add)
                entry.modifiedAtEpochMillis?.let(::formatRemoteFileTime)?.let(::add)
            }.joinToString(" · ")
            Text(
                detail,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (selected) {
            Icon(
                Icons.Default.Check,
                contentDescription = "已选择",
                modifier = Modifier.size(18.dp),
                tint = CodexGreen,
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ParentDirectoryRow(onClick: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().combinedClickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            Icons.Default.KeyboardArrowUp,
            contentDescription = null,
            modifier = Modifier.size(22.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.width(14.dp))
        Text("上一级目录", style = MaterialTheme.typography.bodyLarge)
    }
}

@Composable
private fun FileActionMenu(
    entries: List<RemoteFileEntry>,
    onDismiss: () -> Unit,
    onDownload: (RemoteFileEntry) -> Unit,
    onRename: (RemoteFileEntry) -> Unit,
    onCopy: () -> Unit,
    onCut: () -> Unit,
    onDelete: () -> Unit,
) {
    val singleFile = entries.singleOrNull()?.takeIf { it.kind == RemoteFileKind.File }
    val singleEntry = entries.singleOrNull()
    val copySupported = entries.none { it.kind == RemoteFileKind.SymbolicLink || it.kind == RemoteFileKind.Other }
    Dialog(onDismissRequest = onDismiss) {
        Surface(
            color = CodexSurfaceRaised,
            shape = RoundedCornerShape(8.dp),
            modifier = Modifier.fillMaxWidth().heightIn(max = 520.dp),
        ) {
            Column(modifier = Modifier.padding(vertical = 6.dp)) {
                Text(
                    if (entries.size == 1) entries.first().name else "${entries.size} 个已选文件",
                    modifier = Modifier.padding(horizontal = 18.dp, vertical = 10.dp),
                    style = MaterialTheme.typography.titleMedium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                FileActionRow(
                    icon = Icons.Default.ArrowDownward,
                    title = "下载到本地",
                    enabled = singleFile != null,
                    onClick = { singleFile?.let(onDownload) },
                )
                FileActionRow(
                    icon = Icons.Default.Edit,
                    title = "重命名",
                    enabled = singleEntry != null,
                    onClick = { singleEntry?.let(onRename) },
                )
                FileActionRow(
                    icon = Icons.Default.ContentCopy,
                    title = "复制",
                    enabled = copySupported,
                    onClick = onCopy,
                )
                FileActionRow(
                    icon = Icons.Default.ContentCut,
                    title = "剪切",
                    onClick = onCut,
                )
                FileActionRow(
                    icon = Icons.Default.DeleteOutline,
                    title = "删除",
                    destructive = true,
                    onClick = onDelete,
                )
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun FileActionRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    enabled: Boolean = true,
    destructive: Boolean = false,
    onClick: () -> Unit,
) {
    val color = when {
        !enabled -> MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)
        destructive -> MaterialTheme.colorScheme.error
        else -> MaterialTheme.colorScheme.onSurface
    }
    Row(
        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(4.dp))
            .combinedClickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 18.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, modifier = Modifier.size(20.dp), tint = color)
        Spacer(Modifier.width(14.dp))
        Text(title, color = color, style = MaterialTheme.typography.bodyLarge)
    }
}

@Composable
private fun RenameRemoteFileDialog(
    entry: RemoteFileEntry,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    var name by rememberSaveable(entry.path) { mutableStateOf(entry.name) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("重命名") },
        text = {
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                singleLine = true,
                label = { Text("文件名") },
                modifier = Modifier.fillMaxWidth(),
            )
        },
        confirmButton = {
            TextButton(
                onClick = { onConfirm(name.trim()) },
                enabled = name.trim().isNotBlank() && name.trim() != entry.name,
            ) {
                Text("确定")
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}

private fun Set<String>.toggle(path: String): Set<String> =
    if (path in this) this - path else this + path

private fun fileIcon(kind: RemoteFileKind) = when (kind) {
    RemoteFileKind.Directory -> Icons.Default.Folder
    RemoteFileKind.SymbolicLink -> Icons.Default.Link
    RemoteFileKind.File, RemoteFileKind.Other -> Icons.Default.Description
}

private fun fileKindLabel(kind: RemoteFileKind): String = when (kind) {
    RemoteFileKind.Directory -> "文件夹"
    RemoteFileKind.File -> "文件"
    RemoteFileKind.SymbolicLink -> "符号链接"
    RemoteFileKind.Other -> "其他"
}

private fun formatRemoteFileSize(bytes: Long): String = when {
    bytes >= 1024L * 1024L * 1024L -> "%.1f GB".format(bytes / (1024f * 1024f * 1024f))
    bytes >= 1024L * 1024L -> "%.1f MB".format(bytes / (1024f * 1024f))
    bytes >= 1024L -> "%.1f KB".format(bytes / 1024f)
    else -> "$bytes B"
}

private fun formatRemoteFileTime(epochMillis: Long): String =
    Instant.ofEpochMilli(epochMillis)
        .atZone(ZoneId.of("Asia/Shanghai"))
        .format(DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm"))
