package top.asdb.codexremote.ui

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.DragInteraction
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Pending
import androidx.compose.material.icons.filled.PanTool
import androidx.compose.material.icons.filled.PauseCircleOutline
import androidx.compose.material.icons.filled.PlayCircleOutline
import androidx.compose.material.icons.filled.Photo
import androidx.compose.material.icons.filled.RateReview
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.SmartToy
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.TrackChanges
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Divider
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.pulltorefresh.PullToRefreshContainer
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlin.math.roundToInt
import top.asdb.codexremote.data.AppUiState
import top.asdb.codexremote.data.AppScreen
import top.asdb.codexremote.data.ApprovalMode
import top.asdb.codexremote.data.ApiModelOption
import top.asdb.codexremote.data.CodexModel
import top.asdb.codexremote.data.CustomModelDefinition
import top.asdb.codexremote.data.FileChange
import top.asdb.codexremote.data.MessageAttachment
import top.asdb.codexremote.data.ThreadGoal
import top.asdb.codexremote.data.ThreadGoalStatus
import top.asdb.codexremote.data.TimelineEntry
import top.asdb.codexremote.data.TimelineKind
import top.asdb.codexremote.data.normalizeEpochMillis
import top.asdb.codexremote.data.modelSettings
import top.asdb.codexremote.data.withCompactAttachmentDisplay
import top.asdb.codexremote.ui.components.MarkdownText
import top.asdb.codexremote.ui.components.remoteFilePathFromLink
import top.asdb.codexremote.ui.theme.CodexAmber
import top.asdb.codexremote.ui.theme.CodexBorder
import top.asdb.codexremote.ui.theme.CodexGreen
import top.asdb.codexremote.ui.theme.CodexRed
import top.asdb.codexremote.ui.theme.CodexSurfaceRaised

@OptIn(
    ExperimentalMaterial3Api::class,
    ExperimentalLayoutApi::class,
    ExperimentalComposeUiApi::class,
    ExperimentalFoundationApi::class,
)
@Composable
fun WorkScreen(
    state: AppUiState,
    onBack: () -> Unit,
    onSend: (String) -> Unit,
    onStop: () -> Unit,
    onReview: () -> Unit,
    onRollback: () -> Unit,
    onArchive: () -> Unit,
    onRename: (String) -> Unit,
    onUpload: (Context, List<Uri>) -> Unit,
    onDownloadLinkedRemoteFile: (Context, String, Uri) -> Unit,
    onAddDebugLog: (List<String>) -> Unit,
    onRemoveAttachment: (String) -> Unit,
    onComposerChange: (String) -> Unit,
    onSelectModel: (String, String?) -> Unit,
    onSelectEffort: (String) -> Unit,
    onSaveCustomModel: (String?, CustomModelDefinition) -> Unit,
    onDeleteCustomModel: (String) -> Unit,
    onSetModelHidden: (String, Boolean) -> Unit,
    onFetchApiModelOptions: () -> Unit,
    onSelectApprovalMode: (ApprovalMode) -> Unit,
    onSetGoal: (String) -> Unit,
    onToggleGoalPause: () -> Unit,
    onClearGoal: () -> Unit,
    onCompact: () -> Unit = {},
    onLoadOlder: () -> Unit = {},
    onLoadRemoteImage: suspend (String) -> ByteArray = { error("图片预览不可用") },
    onOpenSubAgent: (threadId: String, agentName: String) -> Unit = { _, _ -> },
) {
    val timelineRows = remember(state.timeline) { state.timeline.toTimelineRenderRows() }
    val backgroundAgents = remember(state.timeline, state.activeAgentCapabilities.subAgents) {
        if (state.activeAgentCapabilities.subAgents) state.timeline.toSubAgentPresentations() else emptyList()
    }
    val canOpenSubAgents = state.activeAgentCapabilities.subAgents &&
        !state.loading && !state.submitting && state.approvalQueue.isEmpty()
    val listState = remember(state.activeThread?.id) { LazyListState() }
    val canLoadOlder by rememberUpdatedState(
        state.olderTurnsCursor != null && !state.loading && !state.olderTurnsLoading,
    )
    val olderTurnsLoading by rememberUpdatedState(state.olderTurnsLoading)
    val pullToRefreshState = rememberPullToRefreshState {
        canLoadOlder
    }
    val pullIndicatorVisible = pullToRefreshState.verticalOffset > 0f || state.olderTurnsLoading
    val pullContentTopPadding = if (pullIndicatorVisible) {
        with(LocalDensity.current) { pullToRefreshState.verticalOffset.toDp() } + 28.dp
    } else {
        0.dp
    }
    val coroutineScope = rememberCoroutineScope()
    val lifecycleOwner = LocalLifecycleOwner.current
    val focusManager = LocalFocusManager.current
    val keyboardController = LocalSoftwareKeyboardController.current
    var selectedDiff by remember { mutableStateOf<FileChange?>(null) }
    var showModels by remember { mutableStateOf(false) }
    var showModelManager by remember { mutableStateOf(false) }
    var showPermissions by remember { mutableStateOf(false) }
    var showMenu by remember { mutableStateOf(false) }
    var renameRequested by remember { mutableStateOf(false) }
    var rollbackRequested by remember { mutableStateOf(false) }
    var archiveRequested by remember { mutableStateOf(false) }
    var fullAccessRequested by remember { mutableStateOf(false) }
    var compactRequested by remember { mutableStateOf(false) }
    var goalEditorVisible by remember { mutableStateOf(false) }
    var goalPauseRequested by remember { mutableStateOf(false) }
    var goalDeleteRequested by remember { mutableStateOf(false) }
    var stopRequested by remember { mutableStateOf(false) }
    var imagePreview by remember { mutableStateOf<RemoteImagePreview?>(null) }
    var imageLoadingPath by remember { mutableStateOf<String?>(null) }
    var imagePreviewError by remember { mutableStateOf<String?>(null) }
    var imageSaveError by remember { mutableStateOf<String?>(null) }
    var imageSaving by remember { mutableStateOf(false) }
    var pendingImageSave by remember { mutableStateOf<RemoteImagePreview?>(null) }
    var pendingRemoteFileDownloadPath by remember { mutableStateOf<String?>(null) }
    var linkToOpen by remember { mutableStateOf<String?>(null) }
    var linkOpenError by remember { mutableStateOf<String?>(null) }
    var showDebugLogPicker by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val canAddDebugLog = state.debugModeEnabled
    val imagePicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isNotEmpty()) onUpload(context, uris)
    }
    val documentPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isNotEmpty()) onUpload(context, uris)
    }
    val remoteFileDownloadPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("*/*"),
    ) { destination ->
        val path = pendingRemoteFileDownloadPath
        pendingRemoteFileDownloadPath = null
        if (destination != null && path != null) {
            onDownloadLinkedRemoteFile(context, path, destination)
        }
    }
    val saveImage: (RemoteImagePreview) -> Unit = saveImage@{ preview ->
        if (imageSaving) return@saveImage
        imageSaveError = null
        imageSaving = true
        coroutineScope.launch {
            try {
                withContext(Dispatchers.IO) { saveImageToPhone(context, preview) }
                Toast.makeText(context, "已保存到手机相册", Toast.LENGTH_SHORT).show()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                imageSaveError = error.message ?: "无法保存图片"
            } finally {
                imageSaving = false
            }
        }
    }
    val storagePermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        val preview = pendingImageSave
        pendingImageSave = null
        if (granted && preview != null) {
            saveImage(preview)
        } else if (preview != null) {
            imageSaveError = "未授予保存图片所需的存储权限"
        }
    }
    fun requestImageSave(preview: RemoteImagePreview) {
        val needsLegacyPermission = Build.VERSION.SDK_INT <= Build.VERSION_CODES.P &&
            context.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED
        if (needsLegacyPermission) {
            pendingImageSave = preview
            storagePermissionLauncher.launch(Manifest.permission.WRITE_EXTERNAL_STORAGE)
        } else {
            saveImage(preview)
        }
    }
    fun openImagePreview(path: String) {
        if (imageLoadingPath != null) return
        imagePreviewError = null
        imageLoadingPath = path
        coroutineScope.launch {
            try {
                val bytes = onLoadRemoteImage(path)
                val bitmap = withContext(Dispatchers.Default) { decodeImagePreview(bytes) }
                imagePreview = RemoteImagePreview(path, bytes, bitmap)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                imagePreviewError = error.message ?: "无法加载图片"
            } finally {
                imageLoadingPath = null
            }
        }
    }

    val requestGoalPauseToggle: () -> Unit = {
        if (shouldConfirmGoalPause(state.activeGoal?.status)) {
            goalPauseRequested = true
        } else {
            onToggleGoalPause()
        }
    }

    LaunchedEffect(state.running) {
        if (!state.running) stopRequested = false
    }
    LaunchedEffect(state.activeGoal?.status) {
        if (!shouldConfirmGoalPause(state.activeGoal?.status)) goalPauseRequested = false
    }

    DisposableEffect(lifecycleOwner, focusManager, keyboardController) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_PAUSE) {
                focusManager.clearFocus(force = true)
                keyboardController?.hide()
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    val latestFileChangeId = state.timeline.lastOrNull { it.kind == TimelineKind.FileChange }?.id
    val activeThreadId = state.activeThread?.id.orEmpty()
    val matchingTurnTiming = state.turnTiming?.takeIf { it.threadId == activeThreadId }
    var turnClockMillis by remember(activeThreadId, matchingTurnTiming?.startedAtMillis, state.activeTurnId) {
        mutableStateOf(System.currentTimeMillis())
    }
    LaunchedEffect(state.running, activeThreadId, matchingTurnTiming?.startedAtMillis, state.activeTurnId) {
        turnClockMillis = System.currentTimeMillis()
        if (state.running) {
            while (true) {
                delay(1_000)
                turnClockMillis = System.currentTimeMillis()
            }
        }
    }
    val runningTurnStartedAtMillis = matchingTurnTiming
        ?.takeIf { it.completedAtMillis == null }
        ?.startedAtMillis
    val completedTurnTiming = matchingTurnTiming?.takeIf {
        !state.running && it.completedAtMillis != null
    }
    val hasTurnTimingFooter = state.running || completedTurnTiming != null
    var followOutput by remember(state.activeThread?.id) { mutableStateOf(true) }
    val trailingItemIndex = timelineRows.size +
        (if (state.aggregateDiff.isNotBlank()) 1 else 0) +
        (if (hasTurnTimingFooter) 1 else 0)

    LaunchedEffect(pullToRefreshState.isRefreshing) {
        if (pullToRefreshState.isRefreshing) {
            followOutput = false
            if (state.olderTurnsCursor != null && !state.loading && !state.olderTurnsLoading) {
                onLoadOlder()
                // The ViewModel marks the request as loading synchronously. If it cannot start
                // (for example after a disconnect), restore the resting pull state instead.
                delay(500)
                if (!olderTurnsLoading && pullToRefreshState.isRefreshing) {
                    pullToRefreshState.endRefresh()
                }
            } else if (state.olderTurnsCursor == null || state.loading) {
                pullToRefreshState.endRefresh()
            }
        }
    }

    LaunchedEffect(state.olderTurnsLoading) {
        if (state.olderTurnsLoading) {
            pullToRefreshState.startRefresh()
        } else if (pullToRefreshState.isRefreshing) {
            pullToRefreshState.endRefresh()
        }
    }

    // Only a physical drag should pause output following. Programmatic scrolling used to keep
    // the transcript pinned must not be mistaken for a user navigating away from the end.
    LaunchedEffect(listState) {
        listState.interactionSource.interactions.collect { interaction ->
            if (interaction is DragInteraction.Start) followOutput = false
        }
    }

    // Re-enable following when the user reaches the end manually.
    LaunchedEffect(listState) {
        snapshotFlow {
            val layout = listState.layoutInfo
            val lastVisible = layout.visibleItemsInfo.lastOrNull()?.index ?: -1
            layout.totalItemsCount == 0 || lastVisible >= layout.totalItemsCount - 1
        }.distinctUntilChanged().collect { atEnd ->
            if (atEnd) followOutput = true
        }
    }

    LaunchedEffect(
        state.timeline,
        state.aggregateDiff,
        hasTurnTimingFooter,
        trailingItemIndex,
    ) {
        if (followOutput && trailingItemIndex > 0) {
            // Stream deltas arrive faster than an animated scroll can finish. Waiting one frame
            // for the new height and jumping to the fixed trailing spacer keeps an anchored view
            // at the actual end instead of leaving it stranded above newly appended output.
            withFrameNanos { }
            listState.scrollToItem(trailingItemIndex)
        }
    }

    // The IME changes the LazyColumn's measured viewport without consistently exposing a
    // composable inset value on all devices. Keep the trailing item aligned on every shrinking
    // frame so the transcript moves together with the composer during the keyboard animation.
    LaunchedEffect(listState, trailingItemIndex) {
        var previousViewportHeight = 0
        snapshotFlow {
            val layout = listState.layoutInfo
            (layout.viewportEndOffset - layout.viewportStartOffset).coerceAtLeast(0)
        }.distinctUntilChanged().collect { viewportHeight ->
            val previousHeight = previousViewportHeight
            previousViewportHeight = viewportHeight
            if (viewportHeight > 0 && previousHeight > 0 && viewportHeight < previousHeight &&
                followOutput && trailingItemIndex > 0
            ) {
                listState.scrollToItem(trailingItemIndex)
            }
        }
    }

    Scaffold(
        modifier = Modifier.fillMaxSize().statusBarsPadding(),
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(
                            state.activeAgentName ?: state.activeThread?.title ?: "新任务",
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(
                            state.activeThread?.cwd.orEmpty(),
                            style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
                    }
                },
                actions = {
                    Box {
                        IconButton(onClick = { showMenu = true }, enabled = !state.loading) {
                            Icon(Icons.Default.MoreVert, contentDescription = "更多")
                        }
                        DropdownMenu(expanded = showMenu, onDismissRequest = { showMenu = false }) {
                            if (state.activeAgentCapabilities.renameThread) {
                                DropdownMenuItem(
                                    text = { Text("重命名") },
                                    leadingIcon = { Icon(Icons.Default.Edit, contentDescription = null) },
                                    enabled = !state.loading && !state.submitting,
                                    onClick = { showMenu = false; renameRequested = true },
                                )
                            }
                            if (state.activeAgentCapabilities.archiveThread && state.screen != AppScreen.AgentWork) {
                                DropdownMenuItem(
                                    text = { Text("归档") },
                                    leadingIcon = { Icon(Icons.Default.Archive, contentDescription = null) },
                                    enabled = !state.loading && !state.submitting && !state.running,
                                    onClick = { showMenu = false; archiveRequested = true },
                                )
                            }
                            if (state.activeAgentCapabilities.threadGoals) {
                                DropdownMenuItem(
                                    text = { Text(if (state.activeGoal == null) "设置目标" else "编辑目标") },
                                    leadingIcon = { Icon(Icons.Default.TrackChanges, contentDescription = null) },
                                    enabled = !state.loading && !state.submitting,
                                    onClick = { showMenu = false; goalEditorVisible = true },
                                )
                            }
                            if (canAddDebugLog) {
                                HorizontalDivider()
                                DropdownMenuItem(
                                    text = { Text("添加 Debug 日志") },
                                    leadingIcon = { Icon(Icons.Default.BugReport, contentDescription = null) },
                                    enabled = !state.loading && !state.submitting,
                                    onClick = {
                                        showMenu = false
                                        showDebugLogPicker = true
                                    },
                                )
                            }
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent),
            )
        },
        bottomBar = {
            WorkComposer(
                state = state,
                value = state.composerDraft,
                onValueChange = onComposerChange,
                onAttachImage = { imagePicker.launch(arrayOf("image/*")) },
                onAttachFile = { documentPicker.launch(arrayOf("*/*")) },
                onRemoveAttachment = onRemoveAttachment,
                onSend = { onSend(state.composerDraft) },
                onStop = { stopRequested = true },
                onShowModels = { showModels = true },
                onShowPermissions = { showPermissions = true },
                onCompact = { compactRequested = true },
                onEditGoal = { goalEditorVisible = true },
                onToggleGoalPause = requestGoalPauseToggle,
                onClearGoal = { goalDeleteRequested = true },
                agents = backgroundAgents,
                onOpenSubAgent = onOpenSubAgent,
                canOpenSubAgents = canOpenSubAgents,
            )
        },
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize()) {
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize().nestedScroll(pullToRefreshState.nestedScrollConnection),
                // Reserve pull distance plus a label row above the transcript. The indicator and
                // its hint therefore never overlap the first message while the user is pulling.
                contentPadding = PaddingValues(
                    start = 9.dp,
                    top = 10.dp + pullContentTopPadding,
                    end = 9.dp,
                    bottom = 10.dp,
                ),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                items(
                    items = timelineRows,
                    key = { row ->
                        "${state.activeThread?.id}:${row.stableKey}"
                    },
                    contentType = { row ->
                        if (row is TimelineRenderRow.Entry) row.entry.kind else TimelineKind.SubAgent
                    },
                ) { row ->
                    when (row) {
                        is TimelineRenderRow.Entry -> {
                            val entry = row.entry
                            TimelineItem(
                                entry = entry,
                                onOpenDiff = { selectedDiff = it },
                                onReview = onReview,
                                canReview = state.activeAgentCapabilities.reviewChanges &&
                                    !state.loading && !state.submitting && !state.running,
                                canRollback = state.activeAgentCapabilities.rollbackThread &&
                                    !state.loading && !state.submitting &&
                                    !state.running && entry.id == latestFileChangeId,
                                onRollback = { rollbackRequested = true },
                                onOpenImage = ::openImagePreview,
                                imageLoadingPath = imageLoadingPath,
                                onOpenLink = { link ->
                                    val remotePath = remoteFilePathFromLink(link)
                                    if (remotePath != null) {
                                        if (pendingRemoteFileDownloadPath == null) {
                                            pendingRemoteFileDownloadPath = remotePath
                                            remoteFileDownloadPicker.launch(
                                                remotePath.substringAfterLast('/').ifBlank { "download" },
                                            )
                                        }
                                    } else {
                                        linkToOpen = link
                                    }
                                },
                                onOpenSubAgent = onOpenSubAgent,
                                canOpenSubAgents = canOpenSubAgents,
                            )
                        }

                        is TimelineRenderRow.SubAgents -> SubAgentActivityGroupBlock(
                            entries = row.entries,
                            onOpenSubAgent = onOpenSubAgent,
                            enabled = canOpenSubAgents,
                        )
                    }
                }
                if (state.aggregateDiff.isNotBlank()) {
                    item(key = "aggregate-diff") {
                        val aggregate = remember(state.aggregateDiff) {
                            FileChange(path = "工作区差异", kind = "diff", diff = state.aggregateDiff)
                        }
                        AggregateDiffBlock(
                            change = aggregate,
                            onOpen = { selectedDiff = aggregate },
                        )
                    }
                }
                if (state.running) {
                    item(key = "running-indicator") {
                        val elapsed = runningTurnStartedAtMillis?.let { startedAtMillis ->
                            formatTurnElapsed(startedAtMillis, turnClockMillis)
                        }
                        Row(
                            modifier = Modifier.semantics {
                                contentDescription = if (elapsed == null) {
                                    "Codex 正在处理"
                                } else {
                                    "Codex 正在处理，已运行 $elapsed"
                                }
                            },
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                            Spacer(Modifier.width(9.dp))
                            ProcessingStatusText(elapsed = elapsed)
                        }
                    }
                } else if (completedTurnTiming != null) {
                    item(key = "turn-completion") {
                        val completedAtMillis = checkNotNull(completedTurnTiming.completedAtMillis)
                        val elapsed = formatTurnElapsed(
                            completedTurnTiming.startedAtMillis,
                            completedAtMillis,
                        )
                        val stopped = completedTurnTiming.stopped
                        Row(
                            modifier = Modifier.semantics {
                                contentDescription = if (stopped) {
                                    "已停止，已处理 $elapsed"
                                } else {
                                    "本次耗时 $elapsed，完成于 ${formatTurnCompletionTime(completedAtMillis)}"
                                }
                            },
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(
                                if (stopped) Icons.Default.Stop else Icons.Default.CheckCircle,
                                contentDescription = null,
                                tint = if (stopped) CodexAmber else CodexGreen,
                                modifier = Modifier.size(16.dp),
                            )
                            Spacer(Modifier.width(9.dp))
                            Text(
                                if (stopped) {
                                    "已停止  $elapsed"
                                } else {
                                    "$elapsed  完成于 ${formatTurnCompletionTime(completedAtMillis)}"
                                },
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                    }
                }
                item { Spacer(Modifier.height(6.dp)) }
            }
            if (pullIndicatorVisible) {
                PullToRefreshContainer(
                    state = pullToRefreshState,
                    modifier = Modifier.align(Alignment.TopCenter),
                )
                val pullHint = when {
                    state.olderTurnsLoading -> "加载更多..."
                    pullToRefreshState.progress >= 1f -> "松开加载更多"
                    else -> "下拉加载更多"
                }
                Text(
                    text = pullHint,
                    modifier = Modifier
                        .align(Alignment.TopCenter)
                        // The built-in indicator ends at verticalOffset; keep its hint directly
                        // beneath it so both follow the user's drag together.
                        .offset { IntOffset(0, pullToRefreshState.verticalOffset.roundToInt()) }
                        .semantics { stateDescription = pullHint }
                        .padding(horizontal = 10.dp, vertical = 4.dp),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.labelSmall,
                )
            }
            if (state.timeline.isEmpty() && !state.loading) {
                Column(Modifier.align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(Icons.Default.Terminal, contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(38.dp))
                    Spacer(Modifier.height(12.dp))
                    Text("描述需要完成的工作", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            if (state.loading) {
                CircularProgressIndicator(Modifier.align(Alignment.Center).size(28.dp), strokeWidth = 2.dp)
            }
            AnimatedVisibility(
                visible = !followOutput && state.timeline.isNotEmpty(),
                modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 12.dp),
            ) {
                Surface(
                    color = Color(0xFF111111),
                    shape = CircleShape,
                    modifier = Modifier.size(46.dp).border(1.dp, CodexBorder, CircleShape),
                ) {
                    IconButton(
                        onClick = {
                            followOutput = true
                            coroutineScope.launch {
                                val lastIndex = (listState.layoutInfo.totalItemsCount - 1).coerceAtLeast(0)
                                listState.animateScrollToItem(lastIndex)
                            }
                        },
                    ) {
                        Icon(Icons.Default.ArrowDownward, contentDescription = "跳到最新消息")
                    }
                }
            }
        }
    }

    if (showDebugLogPicker) {
        DiagnosticLogPickerDialog(
            title = "选择要添加的诊断日志",
            confirmLabel = "添加到对话",
            onDismissRequest = { showDebugLogPicker = false },
            onConfirm = { ids ->
                showDebugLogPicker = false
                onAddDebugLog(ids)
            },
        )
    }

    selectedDiff?.let { change ->
        DiffViewer(change = change, onDismiss = { selectedDiff = null })
    }

    imagePreview?.let { preview ->
        RemoteImagePreviewDialog(
            preview = preview,
            saving = imageSaving,
            onSave = { requestImageSave(preview) },
            onDismiss = { imagePreview = null },
        )
    }

    imageLoadingPath?.let { path ->
        Dialog(onDismissRequest = {}) {
            Surface(shape = RoundedCornerShape(8.dp), color = CodexSurfaceRaised) {
                Row(
                    modifier = Modifier.padding(horizontal = 18.dp, vertical = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(12.dp))
                    Text("正在加载 ${path.substringAfterLast('/').ifBlank { "图片" }}")
                }
            }
        }
    }

    imagePreviewError?.let { message ->
        AlertDialog(
            onDismissRequest = { imagePreviewError = null },
            title = { Text("无法查看图片") },
            text = { Text(message) },
            confirmButton = { TextButton(onClick = { imagePreviewError = null }) { Text("关闭") } },
        )
    }

    imageSaveError?.let { message ->
        AlertDialog(
            onDismissRequest = { imageSaveError = null },
            title = { Text("保存图片失败") },
            text = { Text(message) },
            confirmButton = { TextButton(onClick = { imageSaveError = null }) { Text("关闭") } },
        )
    }

    linkToOpen?.let { link ->
        AlertDialog(
            onDismissRequest = { linkToOpen = null },
            title = { Text("打开链接") },
            text = { Text(link) },
            confirmButton = {
                TextButton(onClick = {
                    linkToOpen = null
                    try {
                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(link)))
                    } catch (error: Throwable) {
                        linkOpenError = error.message ?: "系统中没有可打开链接的应用"
                    }
                }) { Text("打开") }
            },
            dismissButton = {
                TextButton(onClick = { linkToOpen = null }) { Text("取消") }
            },
        )
    }

    linkOpenError?.let { message ->
        AlertDialog(
            onDismissRequest = { linkOpenError = null },
            title = { Text("无法打开链接") },
            text = { Text(message) },
            confirmButton = { TextButton(onClick = { linkOpenError = null }) { Text("关闭") } },
        )
    }

    if (showModels && state.activeAgentCapabilities.models) {
        ModelSheet(
            models = state.models,
            selectedModel = state.selectedModel,
            selectedEffort = state.selectedEffort,
            onSelectModel = onSelectModel,
            onSelectEffort = onSelectEffort,
            showReasoningEffort = state.activeAgentCapabilities.reasoningEffort,
            onManageModels = {
                showModels = false
                showModelManager = true
            },
            onDismiss = { showModels = false },
        )
    }

    if (showModelManager && state.activeAgentCapabilities.models) {
        val profile = state.profiles.firstOrNull { it.id == state.selectedProfileId }
        val modelSettings = profile?.modelSettings(state.activeAgent)
        ModelManagerSheet(
            models = state.models,
            customModels = modelSettings?.customModels.orEmpty(),
            hiddenModelIds = modelSettings?.hiddenModelIds.orEmpty(),
            apiModelOptions = state.apiModelOptions.takeIf {
                state.apiModelOptionsProfileId == state.selectedProfileId
            }.orEmpty(),
            apiModelOptionsLoading = state.apiModelOptionsLoading &&
                state.apiModelOptionsProfileId == state.selectedProfileId,
            apiModelOptionsError = state.apiModelOptionsError.takeIf {
                state.apiModelOptionsProfileId == state.selectedProfileId
            },
            canFetchApiModels = state.activeAgentCapabilities.globalSettings,
            onSaveCustomModel = onSaveCustomModel,
            onDeleteCustomModel = onDeleteCustomModel,
            onSetModelHidden = onSetModelHidden,
            onFetchApiModelOptions = onFetchApiModelOptions,
            onDismiss = { showModelManager = false },
        )
    }

    if (showPermissions && state.activeAgentCapabilities.approvals) {
        ModalBottomSheet(onDismissRequest = { showPermissions = false }) {
            Text(
                "应如何批准 ${state.activeAgent.label} 操作?",
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp),
            )
            ApprovalMode.entries.forEach { mode ->
                val selected = mode == state.approvalMode
                val accent = mode == ApprovalMode.FullAccess
                Row(
                    modifier = Modifier.fillMaxWidth().clickable {
                        if (mode == ApprovalMode.FullAccess) {
                            fullAccessRequested = true
                        } else {
                            onSelectApprovalMode(mode)
                        }
                        showPermissions = false
                    }.padding(horizontal = 20.dp, vertical = 15.dp).semantics {
                        stateDescription = if (selected) "已选择" else "未选择"
                    },
                    verticalAlignment = Alignment.Top,
                ) {
                    Icon(
                        when (mode) {
                            ApprovalMode.RequestApproval -> Icons.Default.PanTool
                            ApprovalMode.AutoApprove -> Icons.Default.Terminal
                            ApprovalMode.FullAccess -> Icons.Default.Shield
                        },
                        contentDescription = null,
                        tint = if (accent) CodexAmber else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(20.dp),
                    )
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            mode.menuLabel,
                            color = if (accent) CodexAmber else MaterialTheme.colorScheme.onSurface,
                            style = MaterialTheme.typography.bodyLarge,
                        )
                        Text(
                            mode.description,
                            color = if (accent) CodexAmber else MaterialTheme.colorScheme.onSurfaceVariant,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                    if (selected) {
                        Icon(
                            Icons.Default.CheckCircle,
                            contentDescription = null,
                            tint = if (accent) CodexAmber else CodexGreen,
                            modifier = Modifier.size(19.dp),
                        )
                    }
                }
            }
            Spacer(Modifier.height(24.dp).navigationBarsPadding())
        }
    }

    if (fullAccessRequested) {
        AlertDialog(
            onDismissRequest = { fullAccessRequested = false },
            title = { Text("启用完全访问") },
            text = { Text("${state.activeAgent.label} 将不受工作区沙箱限制。") },
            confirmButton = {
                TextButton(onClick = {
                    onSelectApprovalMode(ApprovalMode.FullAccess)
                    fullAccessRequested = false
                }) { Text("启用", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { fullAccessRequested = false }) { Text("取消") } },
        )
    }

    if (compactRequested && state.activeAgentCapabilities.compactThread) {
        AlertDialog(
            onDismissRequest = { compactRequested = false },
            title = { Text("压缩会话") },
            text = { Text("是否压缩当前会话？压缩后可以释放一部分上下文空间。") },
            confirmButton = {
                TextButton(onClick = {
                    compactRequested = false
                    onCompact()
                }) { Text("压缩") }
            },
            dismissButton = {
                TextButton(onClick = { compactRequested = false }) { Text("取消") }
            },
        )
    }

    if (stopRequested && state.running) {
        AlertDialog(
            onDismissRequest = { stopRequested = false },
            icon = { Icon(Icons.Default.Stop, contentDescription = null) },
            title = { Text("停止当前回复") },
            text = { Text("确定停止当前正在运行的回复吗？已经生成的内容会保留。") },
            confirmButton = {
                TextButton(onClick = {
                    stopRequested = false
                    if (state.running) onStop()
                }) { Text("停止", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { stopRequested = false }) { Text("取消") }
            },
        )
    }

    if (goalEditorVisible && state.activeAgentCapabilities.threadGoals) {
        var objective by remember(state.activeThread?.id, state.activeGoal?.objective) {
            mutableStateOf(state.activeGoal?.objective.orEmpty())
        }
        AlertDialog(
            modifier = Modifier.imePadding(),
            onDismissRequest = { goalEditorVisible = false },
            icon = { Icon(Icons.Default.TrackChanges, contentDescription = null) },
            title = { Text(if (state.activeGoal == null) "设置目标" else "编辑目标") },
            text = {
                OutlinedTextField(
                    value = objective,
                    onValueChange = { objective = it.take(4_000) },
                    modifier = Modifier.fillMaxWidth(),
                    minLines = 3,
                    maxLines = 6,
                    label = { Text("目标") },
                    placeholder = { Text("设置要持续追逐的目标") },
                )
            },
            confirmButton = {
                TextButton(
                    enabled = objective.trim().isNotBlank() && !state.submitting,
                    onClick = {
                        onSetGoal(objective)
                        goalEditorVisible = false
                    },
                ) { Text("保存") }
            },
            dismissButton = {
                TextButton(onClick = { goalEditorVisible = false }) { Text("取消") }
            },
        )
    }

    if (goalPauseRequested && shouldConfirmGoalPause(state.activeGoal?.status) &&
        state.activeAgentCapabilities.threadGoals
    ) {
        AlertDialog(
            onDismissRequest = { goalPauseRequested = false },
            icon = { Icon(Icons.Default.PauseCircleOutline, contentDescription = null) },
            title = { Text("暂停目标") },
            text = { Text("确定暂停当前目标吗？之后可以随时继续。") },
            confirmButton = {
                TextButton(
                    enabled = !state.submitting,
                    onClick = {
                        goalPauseRequested = false
                        if (shouldConfirmGoalPause(state.activeGoal?.status)) onToggleGoalPause()
                    },
                ) { Text("暂停") }
            },
            dismissButton = {
                TextButton(onClick = { goalPauseRequested = false }) { Text("取消") }
            },
        )
    }

    if (goalDeleteRequested && state.activeAgentCapabilities.threadGoals) {
        AlertDialog(
            onDismissRequest = { goalDeleteRequested = false },
            icon = { Icon(Icons.Default.DeleteOutline, contentDescription = null) },
            title = { Text("删除目标") },
            text = { Text("删除当前会话的目标？") },
            confirmButton = {
                TextButton(
                    enabled = !state.submitting,
                    onClick = {
                        onClearGoal()
                        goalDeleteRequested = false
                    },
                ) { Text("删除", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { goalDeleteRequested = false }) { Text("取消") }
            },
        )
    }

    if (renameRequested) {
        var name by remember { mutableStateOf(state.activeThread?.title.orEmpty()) }
        AlertDialog(
            modifier = Modifier.imePadding(),
            onDismissRequest = { renameRequested = false },
            title = { Text("重命名任务") },
            text = {
                Column(
                    modifier = Modifier.fillMaxWidth().heightIn(max = 240.dp)
                        .verticalScroll(rememberScrollState()),
                ) {
                    OutlinedTextField(
                        value = name,
                        onValueChange = { name = it },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = { onRename(name); renameRequested = false }) { Text("保存") }
            },
            dismissButton = { TextButton(onClick = { renameRequested = false }) { Text("取消") } },
        )
    }

    if (archiveRequested) {
        AlertDialog(
            onDismissRequest = { archiveRequested = false },
            title = { Text("归档任务") },
            text = { Text(state.activeThread?.title.orEmpty()) },
            confirmButton = {
                TextButton(onClick = { archiveRequested = false; onArchive() }) { Text("归档") }
            },
            dismissButton = { TextButton(onClick = { archiveRequested = false }) { Text("取消") } },
        )
    }

    if (rollbackRequested && state.activeAgentCapabilities.rollbackThread) {
        AlertDialog(
            onDismissRequest = { rollbackRequested = false },
            title = { Text("撤销上一轮") },
            text = {
                Text("这只会回退 Agent 会话历史，不会自动恢复服务器上的本地文件。需要恢复文件时，请使用版本控制或手动编辑。")
            },
            confirmButton = {
                TextButton(onClick = {
                    rollbackRequested = false
                    onRollback()
                }) { Text("继续撤销") }
            },
            dismissButton = {
                TextButton(onClick = { rollbackRequested = false }) { Text("取消") }
            },
        )
    }
}

@Composable
private fun TimelineItem(
    entry: TimelineEntry,
    onOpenDiff: (FileChange) -> Unit,
    onReview: () -> Unit,
    canReview: Boolean,
    canRollback: Boolean,
    onRollback: () -> Unit,
    onOpenImage: (String) -> Unit,
    imageLoadingPath: String?,
    onOpenLink: (String) -> Unit,
    onOpenSubAgent: (threadId: String, agentName: String) -> Unit,
    canOpenSubAgents: Boolean,
) {
    when (entry.kind) {
        TimelineKind.UserMessage -> UserMessageBlock(entry, onOpenImage, imageLoadingPath)

        TimelineKind.AgentMessage -> MarkdownText(
            text = entry.text,
            modifier = Modifier.fillMaxWidth(),
            onOpenLink = onOpenLink,
        )
        TimelineKind.Reasoning, TimelineKind.Plan -> CollapsibleText(entry)
        TimelineKind.Command -> CommandBlock(entry)
        TimelineKind.FileChange -> FileChangeBlock(
            entry,
            onOpenDiff,
            onReview,
            canReview,
            canRollback,
            onRollback,
        )
        TimelineKind.Tool -> ToolBlock(entry, onOpenImage, imageLoadingPath)
        TimelineKind.SubAgent -> SubAgentActivityGroupBlock(
            entries = listOf(entry),
            onOpenSubAgent = onOpenSubAgent,
            enabled = canOpenSubAgents,
        )
        TimelineKind.Review -> Surface(
            color = MaterialTheme.colorScheme.surfaceVariant,
            shape = RoundedCornerShape(6.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.padding(12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.RateReview, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(entry.title, fontWeight = FontWeight.Medium)
                }
                if (entry.text.isNotBlank()) {
                    Spacer(Modifier.height(8.dp))
                    MarkdownText(text = entry.text, onOpenLink = onOpenLink)
                }
            }
        }

        TimelineKind.Notice -> Text(
            entry.text.ifBlank { entry.title },
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodySmall,
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun UserMessageBlock(
    entry: TimelineEntry,
    onOpenImage: (String) -> Unit,
    imageLoadingPath: String?,
) {
    val displayEntry = remember(entry) { entry.withCompactAttachmentDisplay() }
    Surface(
        color = MaterialTheme.colorScheme.surfaceVariant,
        shape = RoundedCornerShape(6.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (displayEntry.text.isNotBlank()) {
                SelectionContainer { Text(displayEntry.text) }
            }
            if (displayEntry.attachments.isNotEmpty()) {
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(7.dp),
                    verticalArrangement = Arrangement.spacedBy(7.dp),
                ) {
                    displayEntry.attachments.forEach { attachment ->
                        UserMessageAttachment(attachment, onOpenImage, imageLoadingPath)
                    }
                }
            }
        }
    }
}

@Composable
private fun UserMessageAttachment(
    attachment: MessageAttachment,
    onOpenImage: (String) -> Unit,
    imageLoadingPath: String?,
) {
    val isImage = attachment.mimeType.startsWith("image/") && attachment.remotePath.isNotBlank()
    val displayName = attachment.name.ifBlank { if (isImage) "图片" else "文件" }
    Surface(
        color = MaterialTheme.colorScheme.surface,
        shape = RoundedCornerShape(6.dp),
        modifier = if (isImage) {
            Modifier.clickable { onOpenImage(attachment.remotePath) }
        } else {
            Modifier
        },
    ) {
        Row(
            modifier = Modifier.widthIn(max = 260.dp).padding(horizontal = 9.dp, vertical = 7.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (isImage && imageLoadingPath == attachment.remotePath) {
                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
            } else {
                Icon(
                    imageVector = if (isImage) Icons.Default.Photo else Icons.Default.Description,
                    contentDescription = if (isImage) "查看图片 $displayName" else null,
                    modifier = Modifier.size(17.dp),
                    tint = if (isImage) CodexGreen else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Spacer(Modifier.width(6.dp))
            Text(
                text = displayName,
                style = MaterialTheme.typography.bodySmall,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun CollapsibleText(entry: TimelineEntry) {
    var expanded by remember(entry.id) { mutableStateOf(entry.kind == TimelineKind.Plan) }
    Column(Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier.fillMaxWidth().clickable { expanded = !expanded }
                .padding(vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(if (entry.kind == TimelineKind.Plan) Icons.Default.Pending else Icons.Default.Search,
                contentDescription = null, modifier = Modifier.size(17.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.width(8.dp))
            Text(entry.title.ifBlank { "思考过程" }, style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
            Icon(if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                contentDescription = null, modifier = Modifier.size(18.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        AnimatedVisibility(expanded) {
            Text(entry.text, style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 25.dp, top = 4.dp))
        }
    }
}

@Composable
private fun CommandBlock(entry: TimelineEntry) {
    var expanded by remember(entry.id) { mutableStateOf(false) }
    Surface(
        color = CodexSurfaceRaised,
        shape = RoundedCornerShape(6.dp),
        modifier = Modifier.fillMaxWidth().border(1.dp, CodexBorder, RoundedCornerShape(6.dp)),
    ) {
        Column {
            Row(
                modifier = Modifier.fillMaxWidth().clickable { expanded = !expanded }
                    .padding(horizontal = 11.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Default.Terminal, contentDescription = null, modifier = Modifier.size(17.dp))
                Spacer(Modifier.width(8.dp))
                Text("运行了命令", style = MaterialTheme.typography.labelLarge, modifier = Modifier.weight(1f))
                StatusText(entry.status)
                Icon(if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                    contentDescription = if (expanded) "收起命令详情" else "展开命令详情",
                    modifier = Modifier.size(18.dp))
            }
            AnimatedVisibility(expanded) {
                Column {
                    SelectionContainer {
                        Text(
                            entry.command.ifBlank { "未提供命令内容" },
                            style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                            color = MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier.fillMaxWidth().background(Color(0xFF151515))
                                .padding(horizontal = 11.dp, vertical = 9.dp),
                        )
                    }
                    if (entry.output.isNotBlank()) {
                        HorizontalDivider(color = CodexBorder)
                        SelectionContainer {
                            Text(
                                entry.output,
                                style = TextStyle(
                                    fontFamily = FontFamily.Monospace,
                                    fontSize = 12.sp,
                                    letterSpacing = 0.sp,
                                ),
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.fillMaxWidth().heightIn(max = 340.dp)
                                    .verticalScroll(rememberScrollState())
                                    .horizontalScroll(rememberScrollState())
                                    .padding(horizontal = 11.dp, vertical = 10.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ContextUsageRing(
    usage: ContextUsageSummary?,
    modifier: Modifier = Modifier,
) {
    var detailsVisible by remember { mutableStateOf(false) }
    Box(
        modifier = modifier.size(32.dp),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier.fillMaxSize().clip(CircleShape).clickable {
                detailsVisible = !detailsVisible
            }.semantics {
                contentDescription = "上下文用量，点击查看详情"
                stateDescription = usage?.let {
                    "${it.usedPercent}% 已用，剩余 ${it.remainingPercent}%（${formatContextTokenCount(it.remainingTokens)} 标记）"
                } ?: "等待服务器用量数据"
            },
            contentAlignment = Alignment.Center,
        ) {
            CircularProgressIndicator(
                progress = { usage?.fraction ?: 0f },
                modifier = Modifier.size(18.dp),
                strokeWidth = 2.dp,
                color = Color.White.copy(alpha = 0.94f),
                trackColor = Color(0xFF555555),
            )
        }
        DropdownMenu(
            expanded = detailsVisible,
            onDismissRequest = { detailsVisible = false },
            offset = DpOffset(x = (-200).dp, y = 0.dp),
            modifier = Modifier
                .widthIn(min = 210.dp, max = 260.dp)
                .background(CodexSurfaceRaised, RoundedCornerShape(8.dp)),
        ) {
            Column(
                modifier = Modifier.padding(horizontal = 14.dp, vertical = 11.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(
                    "背景信息窗口：",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (usage == null) {
                    Text(
                        "等待服务器返回上下文用量",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                } else {
                    Text(
                        "${usage.usedPercent}% 已用（剩余 ${usage.remainingPercent}%）",
                        style = MaterialTheme.typography.bodyMedium,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        "已用 ${formatContextTokenCount(usage.usedTokens)} 标记，剩余 " +
                            "${formatContextTokenCount(usage.remainingTokens)}，共 " +
                            "${formatContextTokenCount(usage.windowTokens)}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

@Composable
private fun FileChangeBlock(
    entry: TimelineEntry,
    onOpenDiff: (FileChange) -> Unit,
    onReview: () -> Unit,
    canReview: Boolean,
    canRollback: Boolean,
    onRollback: () -> Unit,
) {
    val additions = entry.changes.sumOf { it.additions }
    val deletions = entry.changes.sumOf { it.deletions }
    var expanded by remember(entry.id) { mutableStateOf(false) }
    val visibleChanges = if (expanded) entry.changes else entry.changes.take(3)
    val hiddenCount = entry.changes.size - visibleChanges.size
    Surface(
        color = Color(0xFF1B1B1B),
        shape = RoundedCornerShape(8.dp),
        modifier = Modifier.fillMaxWidth().border(1.dp, CodexBorder, RoundedCornerShape(8.dp)),
    ) {
        Column {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 11.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    modifier = Modifier.size(38.dp).clip(RoundedCornerShape(7.dp))
                        .background(CodexSurfaceRaised),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.Default.Description, contentDescription = null, modifier = Modifier.size(20.dp))
                }
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        "已编辑 ${entry.changes.size} 个文件",
                        fontWeight = FontWeight.Medium,
                        style = MaterialTheme.typography.bodyLarge,
                    )
                    Row {
                        Text("+$additions", color = CodexGreen, style = MaterialTheme.typography.bodySmall)
                        Spacer(Modifier.width(6.dp))
                        Text("-$deletions", color = CodexRed, style = MaterialTheme.typography.bodySmall)
                    }
                }
                if (canRollback) {
                    IconButton(
                        onClick = onRollback,
                        enabled = entry.status != "inProgress" && entry.changes.isNotEmpty(),
                        modifier = Modifier.size(36.dp),
                    ) {
                        Icon(
                            Icons.AutoMirrored.Filled.Undo,
                            contentDescription = "撤销上一轮会话",
                            modifier = Modifier.size(19.dp),
                        )
                    }
                }
                if (canReview) {
                    Spacer(Modifier.width(4.dp))
                    OutlinedButton(
                        onClick = onReview,
                        modifier = Modifier.height(36.dp),
                        shape = RoundedCornerShape(7.dp),
                        contentPadding = PaddingValues(horizontal = 12.dp),
                    ) {
                        Text("审核", style = MaterialTheme.typography.labelLarge)
                    }
                }
            }
            visibleChanges.forEach { change ->
                HorizontalDivider(color = CodexBorder)
                Row(
                    modifier = Modifier.fillMaxWidth().clickable { onOpenDiff(change) }
                        .padding(horizontal = 11.dp, vertical = 9.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(change.path, modifier = Modifier.weight(1f), maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace))
                    Spacer(Modifier.width(8.dp))
                    Text("+${change.additions}", color = CodexGreen, style = MaterialTheme.typography.bodySmall)
                    Spacer(Modifier.width(5.dp))
                    Text("-${change.deletions}", color = CodexRed, style = MaterialTheme.typography.bodySmall)
                }
            }
            if (entry.changes.size > 3) {
                HorizontalDivider(color = CodexBorder)
                Row(
                    modifier = Modifier.fillMaxWidth().clickable { expanded = !expanded }
                        .padding(horizontal = 11.dp, vertical = 9.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        if (expanded) "收起文件" else "再显示 $hiddenCount 个文件",
                        modifier = Modifier.weight(1f),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    Icon(
                        if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                        contentDescription = if (expanded) "收起" else "展开",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(19.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun AggregateDiffBlock(change: FileChange, onOpen: () -> Unit) {
    Surface(
        color = CodexSurfaceRaised,
        shape = RoundedCornerShape(6.dp),
        modifier = Modifier.fillMaxWidth().border(1.dp, CodexBorder, RoundedCornerShape(6.dp)),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().clickable(onClick = onOpen)
                .padding(horizontal = 12.dp, vertical = 11.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Default.Code, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(9.dp))
            Column(Modifier.weight(1f)) {
                Text("工作区差异", fontWeight = FontWeight.Medium)
                Row {
                    Text("+${change.additions}", color = CodexGreen, style = MaterialTheme.typography.bodySmall)
                    Spacer(Modifier.width(7.dp))
                    Text("-${change.deletions}", color = CodexRed, style = MaterialTheme.typography.bodySmall)
                }
            }
            TextButton(onClick = onOpen) { Text("查看差异") }
        }
    }
}

@Composable
private fun ToolBlock(
    entry: TimelineEntry,
    onOpenImage: (String) -> Unit,
    imageLoadingPath: String?,
) {
    val imagePath = imagePreviewPath(entry)
    val loadingImage = imagePath != null && imagePath == imageLoadingPath
    Surface(
        color = MaterialTheme.colorScheme.surfaceVariant,
        shape = RoundedCornerShape(6.dp),
        modifier = Modifier.fillMaxWidth().let { modifier ->
            if (imagePath != null) modifier.clickable { onOpenImage(imagePath) } else modifier
        },
    ) {
        Column(Modifier.padding(11.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    if (imagePath != null) Icons.Default.Visibility else Icons.Default.Code,
                    contentDescription = null,
                    modifier = Modifier.size(17.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(entry.title.ifBlank { "工具" }, modifier = Modifier.weight(1f),
                    style = MaterialTheme.typography.labelLarge)
                if (imagePath == null) {
                    StatusText(entry.status)
                } else if (loadingImage) {
                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                } else {
                    IconButton(onClick = { onOpenImage(imagePath) }, modifier = Modifier.size(30.dp)) {
                        Icon(Icons.Default.Visibility, contentDescription = "查看图片", modifier = Modifier.size(18.dp))
                    }
                }
            }
            if (entry.text.isNotBlank()) {
                Spacer(Modifier.height(7.dp))
                if (imagePath != null) {
                    Text(
                        entry.text,
                        style = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 12.sp, letterSpacing = 0.sp),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.fillMaxWidth().heightIn(max = 260.dp)
                            .verticalScroll(rememberScrollState())
                            .horizontalScroll(rememberScrollState()),
                    )
                } else {
                    SelectionContainer {
                        Text(
                            entry.text,
                            style = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 12.sp, letterSpacing = 0.sp),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.fillMaxWidth().heightIn(max = 260.dp)
                                .verticalScroll(rememberScrollState())
                                .horizontalScroll(rememberScrollState()),
                        )
                    }
                }
            }
        }
    }
}

internal fun imagePreviewPath(entry: TimelineEntry): String? {
    if (entry.kind != TimelineKind.Tool) return null
    val toolName = entry.title.trim().lowercase()
    if (toolName !in setOf("imageview", "view_image", "image viewer", "查看图片", "查看了图片")) return null
    listOf(entry.text, entry.output).forEach { content ->
        content.lineSequence().forEach { line ->
            val path = line.trim().removePrefix("file://").removeSurrounding("\"")
            if (path.startsWith('/') && IMAGE_EXTENSIONS.any { path.endsWith(it, ignoreCase = true) }) {
                return path
            }
        }
    }
    return null
}

private val IMAGE_EXTENSIONS = setOf(".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp")

private data class RemoteImagePreview(
    val path: String,
    val bytes: ByteArray,
    val bitmap: Bitmap,
)

private fun decodeImagePreview(bytes: ByteArray): Bitmap {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    require(bounds.outWidth > 0 && bounds.outHeight > 0) { "文件不是可显示的图片" }
    val options = BitmapFactory.Options().apply {
        inSampleSize = previewSampleSize(bounds.outWidth, bounds.outHeight)
    }
    return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        ?: throw IllegalArgumentException("文件不是可显示的图片")
}

private fun previewSampleSize(width: Int, height: Int): Int {
    var sample = 1
    while (width / sample > 2_048 || height / sample > 2_048) sample *= 2
    return sample
}

internal fun imageMimeType(path: String): String = when (path.substringAfterLast('.', "").lowercase()) {
    "jpg", "jpeg" -> "image/jpeg"
    "webp" -> "image/webp"
    "gif" -> "image/gif"
    "bmp" -> "image/bmp"
    else -> "image/png"
}

private fun saveImageToPhone(context: Context, preview: RemoteImagePreview) {
    val resolver = context.contentResolver
    val displayName = preview.path.substringAfterLast('/').take(120).ifBlank {
        "codex-${System.currentTimeMillis()}.png"
    }
    val values = ContentValues().apply {
        put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
        put(MediaStore.Images.Media.MIME_TYPE, imageMimeType(preview.path))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/Codex")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
    }
    val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
        ?: throw IllegalStateException("无法创建图片文件")
    try {
        resolver.openOutputStream(uri)?.use { output -> output.write(preview.bytes) }
            ?: throw IllegalStateException("无法写入图片文件")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            resolver.update(
                uri,
                ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) },
                null,
                null,
            )
        }
    } catch (error: Throwable) {
        resolver.delete(uri, null, null)
        throw error
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun RemoteImagePreviewDialog(
    preview: RemoteImagePreview,
    saving: Boolean,
    onSave: () -> Unit,
    onDismiss: () -> Unit,
) {
    var saveRequested by remember(preview.path) { mutableStateOf(false) }
    Dialog(onDismissRequest = onDismiss) {
        Surface(
            color = Color.Black,
            shape = RoundedCornerShape(8.dp),
            modifier = Modifier.fillMaxSize().padding(10.dp),
        ) {
            Column {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 6.dp, top = 7.dp, bottom = 7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        preview.path.substringAfterLast('/').ifBlank { "图片" },
                        modifier = Modifier.weight(1f),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        color = Color.White,
                    )
                    IconButton(onClick = onDismiss) {
                        Icon(Icons.Default.Close, contentDescription = "关闭图片", tint = Color.White)
                    }
                }
                Box(
                    modifier = Modifier.fillMaxWidth().weight(1f).background(Color.Black),
                    contentAlignment = Alignment.Center,
                ) {
                    Image(
                        bitmap = preview.bitmap.asImageBitmap(),
                        contentDescription = preview.path,
                        contentScale = ContentScale.Fit,
                        modifier = Modifier.fillMaxSize().padding(8.dp).combinedClickable(
                            enabled = !saving,
                            onClick = {},
                            onLongClick = { saveRequested = true },
                        ),
                    )
                    if (saving) {
                        Surface(shape = RoundedCornerShape(8.dp), color = CodexSurfaceRaised) {
                            Row(
                                modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                                Spacer(Modifier.width(10.dp))
                                Text("正在保存")
                            }
                        }
                    }
                }
            }
        }
    }
    if (saveRequested) {
        AlertDialog(
            onDismissRequest = { saveRequested = false },
            title = { Text("保存图片") },
            text = { Text("保存到手机相册？") },
            confirmButton = {
                TextButton(onClick = {
                    saveRequested = false
                    onSave()
                }) { Text("保存") }
            },
            dismissButton = {
                TextButton(onClick = { saveRequested = false }) { Text("取消") }
            },
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun SubAgentActivityGroupBlock(
    entries: List<TimelineEntry>,
    onOpenSubAgent: (threadId: String, agentName: String) -> Unit,
    enabled: Boolean,
) {
    val agents = remember(entries) { entries.toSubAgentPresentations() }
    if (agents.isEmpty()) return
    FlowRow(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 3.dp, vertical = 1.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        agents.forEach { agent ->
            SubAgentStatusChip(
                agent = agent,
                onOpenSubAgent = onOpenSubAgent,
                enabled = enabled,
            )
        }
    }
}

@Composable
private fun SubAgentStatusChip(
    agent: SubAgentPresentation,
    onOpenSubAgent: (threadId: String, agentName: String) -> Unit,
    enabled: Boolean,
) {
    val canOpen = agent.isOpenable && enabled
    AssistChip(
        onClick = {
            if (agent.isOpenable) onOpenSubAgent(agent.threadId, agent.name)
        },
        enabled = canOpen,
        leadingIcon = { SubAgentAvatar(agent = agent, size = 18.dp) },
        label = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    agent.name,
                    modifier = Modifier.widthIn(max = 160.dp),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.width(7.dp))
                SubAgentStatusVisual(agent = agent, spinnerSize = 14.dp)
            }
        },
        modifier = Modifier.semantics {
            contentDescription = if (agent.path.isNotBlank()) {
                "${agent.name}，${agent.path}"
            } else {
                agent.name
            }
            stateDescription = agent.status.label
        },
    )
}

/** Keeps each collaborator's state in its own row instead of deriving a misleading group state. */
@Composable
private fun SubAgentStatusRow(
    agent: SubAgentPresentation,
    onOpenSubAgent: (threadId: String, agentName: String) -> Unit,
    enabled: Boolean,
    framed: Boolean,
    avatarSize: Dp,
    horizontalPadding: Dp,
    verticalPadding: Dp,
    modifier: Modifier = Modifier,
) {
    val canOpen = agent.isOpenable && enabled
    val rowModifier = Modifier
        .fillMaxWidth()
        .then(
            if (canOpen) {
                Modifier.clickable { onOpenSubAgent(agent.threadId, agent.name) }
            } else {
                Modifier
            },
        )
        .padding(horizontal = horizontalPadding, vertical = verticalPadding)
        .semantics {
            contentDescription = if (canOpen) {
                "打开 ${agent.name} 的工作页面"
            } else if (agent.path.isNotBlank()) {
                "${agent.name}，${agent.path}"
            } else {
                agent.name
            }
            stateDescription = agent.status.label
        }

    if (framed) {
        val shape = RoundedCornerShape(8.dp)
        Surface(
            color = CodexSurfaceRaised,
            shape = shape,
            modifier = modifier.fillMaxWidth().border(1.dp, CodexBorder, shape),
        ) {
            SubAgentStatusRowContent(agent = agent, avatarSize = avatarSize, modifier = rowModifier)
        }
    } else {
        SubAgentStatusRowContent(
            agent = agent,
            avatarSize = avatarSize,
            modifier = modifier.then(rowModifier),
        )
    }
}

@Composable
private fun SubAgentStatusRowContent(
    agent: SubAgentPresentation,
    avatarSize: Dp,
    modifier: Modifier,
) {
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SubAgentAvatar(agent = agent, size = avatarSize)
        Spacer(Modifier.width(9.dp))
        Text(
            agent.name,
            modifier = Modifier.weight(1f),
            style = MaterialTheme.typography.bodyMedium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Spacer(Modifier.width(10.dp))
        SubAgentStatusVisual(agent = agent, spinnerSize = 16.dp)
    }
}

@Composable
private fun SubAgentStatusVisual(
    agent: SubAgentPresentation,
    spinnerSize: Dp,
) {
    val statusColor = subAgentStatusColor(agent.status)
    if (agent.status.isActive) {
        CircularProgressIndicator(
            modifier = Modifier.size(spinnerSize),
            strokeWidth = 2.dp,
            color = statusColor,
        )
    } else {
        Text(
            agent.status.label,
            style = MaterialTheme.typography.bodySmall,
            color = statusColor,
            maxLines = 1,
        )
    }
}

private val subAgentAvatarPalette = listOf(
    Color(0xFF71A7F7),
    Color(0xFF9A8CFF),
    Color(0xFF51C7C7),
    Color(0xFFE38CC4),
    Color(0xFFE5A65E),
    Color(0xFF78C98A),
    Color(0xFFA78BFA),
)

@Composable
private fun SubAgentAvatar(
    agent: SubAgentPresentation,
    size: Dp,
    modifier: Modifier = Modifier,
) {
    val color = subAgentAvatarPalette[agent.avatarColorIndex(subAgentAvatarPalette.size)]
    Box(
        modifier = modifier
            .size(size)
            .clip(CircleShape)
            .background(color.copy(alpha = 0.2f)),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            Icons.Default.SmartToy,
            contentDescription = null,
            tint = color,
            modifier = Modifier.size(size * 0.62f),
        )
    }
}

@Composable
private fun subAgentStatusColor(status: SubAgentDisplayStatus): Color = when (status) {
    SubAgentDisplayStatus.Preparing,
    SubAgentDisplayStatus.Started,
    SubAgentDisplayStatus.Updated,
    SubAgentDisplayStatus.Working -> CodexAmber

    SubAgentDisplayStatus.Completed -> CodexGreen
    SubAgentDisplayStatus.Interrupted,
    SubAgentDisplayStatus.Failed,
    SubAgentDisplayStatus.Unavailable -> CodexRed

    SubAgentDisplayStatus.Stopped -> MaterialTheme.colorScheme.onSurfaceVariant
}

@Composable
private fun StatusText(status: String) {
    if (status.isBlank()) return
    val color = when (status) {
        "completed" -> CodexGreen
        "failed", "declined" -> CodexRed
        "inProgress" -> CodexAmber
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    Text(
        when (status) {
            "completed" -> "完成"
            "failed" -> "失败"
            "declined" -> "已拒绝"
            "inProgress" -> "运行中"
            else -> status
        },
        color = color,
        style = MaterialTheme.typography.bodySmall,
        modifier = Modifier.padding(end = 8.dp),
    )
}

@Composable
private fun BackgroundAgentsPanel(
    sessionId: String,
    agents: List<SubAgentPresentation>,
    onOpenSubAgent: (threadId: String, agentName: String) -> Unit,
    enabled: Boolean,
) {
    var expanded by remember(sessionId) { mutableStateOf(false) }
    val headerLabel = "${agents.size} 个后台智能体"
    Surface(
        color = CodexSurfaceRaised,
        shape = RoundedCornerShape(8.dp),
        modifier = Modifier.fillMaxWidth().border(1.dp, CodexBorder, RoundedCornerShape(8.dp)),
    ) {
        Column {
            Row(
                modifier = Modifier.fillMaxWidth().clickable { expanded = !expanded }
                    .padding(horizontal = 11.dp, vertical = 9.dp).semantics {
                        contentDescription = headerLabel
                        stateDescription = if (expanded) "已展开" else "已折叠"
                    },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    Icons.Default.SmartToy,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(17.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    headerLabel,
                    style = MaterialTheme.typography.labelLarge,
                    modifier = Modifier.weight(1f),
                )
                Icon(
                    if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                    contentDescription = if (expanded) "收起后台智能体" else "展开后台智能体",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(20.dp),
                )
            }
            AnimatedVisibility(visible = expanded) {
                Column {
                    HorizontalDivider(color = CodexBorder)
                    Column(
                        modifier = Modifier.fillMaxWidth().heightIn(max = 176.dp)
                            .verticalScroll(rememberScrollState()).padding(vertical = 3.dp),
                    ) {
                        agents.forEach { agent ->
                            SubAgentStatusRow(
                                agent = agent,
                                onOpenSubAgent = onOpenSubAgent,
                                enabled = enabled,
                                framed = false,
                                avatarSize = 25.dp,
                                horizontalPadding = 11.dp,
                                verticalPadding = 7.dp,
                            )
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun WorkComposer(
    state: AppUiState,
    value: String,
    onValueChange: (String) -> Unit,
    onAttachImage: () -> Unit,
    onAttachFile: () -> Unit,
    onRemoveAttachment: (String) -> Unit,
    onSend: () -> Unit,
    onStop: () -> Unit,
    onShowModels: () -> Unit,
    onShowPermissions: () -> Unit,
    onCompact: () -> Unit,
    onEditGoal: () -> Unit,
    onToggleGoalPause: () -> Unit,
    onClearGoal: () -> Unit,
    agents: List<SubAgentPresentation>,
    onOpenSubAgent: (threadId: String, agentName: String) -> Unit,
    canOpenSubAgents: Boolean,
) {
    val composerScroll = rememberScrollState()
    var actionMenuVisible by remember { mutableStateOf(false) }
    var attachmentMenuVisible by remember { mutableStateOf(false) }
    val modelName = state.models.firstOrNull { it.model == state.selectedModel }?.displayName
        ?: state.selectedModel ?: "模型"
    val effortName = when (state.selectedEffort) {
        "minimal" -> "极低"
        "low" -> "低"
        "medium" -> "中"
        "high" -> "高"
        "xhigh" -> "极高"
        else -> state.selectedEffort.orEmpty()
    }
    val modelLabel = listOf(modelName.removePrefix("GPT-"), effortName)
        .filter { it.isNotBlank() }.joinToString(" ")
    Surface(color = MaterialTheme.colorScheme.background) {
        Column(
            modifier = Modifier.fillMaxWidth().imePadding().navigationBarsPadding()
                .padding(horizontal = 8.dp, vertical = 5.dp),
        ) {
            if (state.attachments.isNotEmpty()) {
                Row(
                    modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(7.dp),
                ) {
                    state.attachments.forEach { attachment ->
                        AssistChip(
                            onClick = { onRemoveAttachment(attachment.remotePath) },
                            label = { Text(attachment.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                            leadingIcon = { Icon(Icons.Default.Description, contentDescription = null,
                                modifier = Modifier.size(16.dp)) },
                            trailingIcon = { Icon(Icons.Default.Close, contentDescription = "移除",
                                modifier = Modifier.size(15.dp)) },
                        )
                    }
                }
                Spacer(Modifier.height(6.dp))
            }
            state.activeGoal?.takeIf { state.activeAgentCapabilities.threadGoals }?.let { goal ->
                ThreadGoalBar(
                    goal = goal,
                    mutationInProgress = state.submitting,
                    onEdit = onEditGoal,
                    onTogglePause = onToggleGoalPause,
                    onDelete = onClearGoal,
                )
                Spacer(Modifier.height(6.dp))
            }
            if (agents.isNotEmpty()) {
                BackgroundAgentsPanel(
                    sessionId = state.activeThread?.id.orEmpty(),
                    agents = agents,
                    onOpenSubAgent = onOpenSubAgent,
                    enabled = canOpenSubAgents,
                )
                Spacer(Modifier.height(6.dp))
            }
            Surface(
                shape = RoundedCornerShape(8.dp),
                color = Color(0xFF1B1B1B),
                modifier = Modifier.fillMaxWidth().border(1.dp, CodexBorder, RoundedCornerShape(8.dp)),
            ) {
                Column(Modifier.padding(horizontal = 10.dp, vertical = 8.dp)) {
                    BasicTextField(
                        value = value,
                        onValueChange = onValueChange,
                        enabled = !state.submitting,
                        modifier = Modifier.fillMaxWidth().heightIn(min = 72.dp, max = 150.dp)
                            .verticalScroll(composerScroll),
                        textStyle = MaterialTheme.typography.bodyMedium.copy(color = MaterialTheme.colorScheme.onSurface),
                        cursorBrush = androidx.compose.ui.graphics.SolidColor(MaterialTheme.colorScheme.onSurface),
                        decorationBox = { inner ->
                            Box {
                                if (value.isBlank()) {
                                    Text(
                                        if (state.running) "提出后续变更要求" else "描述任务",
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        style = MaterialTheme.typography.bodyMedium,
                                    )
                                }
                                inner()
                            }
                        },
                    )
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box {
                            IconButton(
                                onClick = { attachmentMenuVisible = true },
                                enabled = !state.loading,
                                modifier = Modifier.size(36.dp),
                            ) {
                                Icon(Icons.Default.Add, contentDescription = "添加附件", modifier = Modifier.size(20.dp))
                            }
                            DropdownMenu(
                                expanded = attachmentMenuVisible,
                                onDismissRequest = { attachmentMenuVisible = false },
                            ) {
                                DropdownMenuItem(
                                    text = { Text("上传图片") },
                                    leadingIcon = { Icon(Icons.Default.Photo, contentDescription = null) },
                                    onClick = {
                                        attachmentMenuVisible = false
                                        onAttachImage()
                                    },
                                )
                                DropdownMenuItem(
                                    text = { Text("上传文件") },
                                    leadingIcon = { Icon(Icons.Default.FolderOpen, contentDescription = null) },
                                    onClick = {
                                        attachmentMenuVisible = false
                                        onAttachFile()
                                    },
                                )
                            }
                        }
                        Box {
                            IconButton(
                                onClick = { actionMenuVisible = true },
                                enabled = !state.loading,
                                modifier = Modifier.size(36.dp),
                            ) {
                                Icon(
                                    Icons.Default.MoreVert,
                                    contentDescription = "会话操作",
                                    modifier = Modifier.size(20.dp),
                                )
                            }
                            DropdownMenu(
                                expanded = actionMenuVisible,
                                onDismissRequest = { actionMenuVisible = false },
                            ) {
                                val canMutateGoal = !state.loading && !state.submitting
                                if (state.activeAgentCapabilities.threadGoals) {
                                    DropdownMenuItem(
                                        text = { Text(if (state.activeGoal == null) "设置目标" else "编辑目标") },
                                        leadingIcon = {
                                            Icon(Icons.Default.TrackChanges, contentDescription = null)
                                        },
                                        enabled = canMutateGoal,
                                        onClick = {
                                            actionMenuVisible = false
                                            onEditGoal()
                                        },
                                    )
                                }
                                state.activeGoal?.takeIf {
                                    state.activeAgentCapabilities.threadGoals
                                }?.let { goal ->
                                    if (goal.status == ThreadGoalStatus.Active ||
                                        goal.status == ThreadGoalStatus.Paused
                                    ) {
                                        val paused = goal.status == ThreadGoalStatus.Paused
                                        DropdownMenuItem(
                                            text = { Text(if (paused) "继续目标" else "暂停目标") },
                                            leadingIcon = {
                                                Icon(
                                                    if (paused) {
                                                        Icons.Default.PlayCircleOutline
                                                    } else {
                                                        Icons.Default.PauseCircleOutline
                                                    },
                                                    contentDescription = null,
                                                )
                                            },
                                            enabled = canMutateGoal,
                                            onClick = {
                                                actionMenuVisible = false
                                                onToggleGoalPause()
                                            },
                                        )
                                    }
                                    DropdownMenuItem(
                                        text = { Text("删除目标") },
                                        leadingIcon = {
                                            Icon(Icons.Default.DeleteOutline, contentDescription = null)
                                        },
                                        enabled = canMutateGoal,
                                        onClick = {
                                            actionMenuVisible = false
                                            onClearGoal()
                                        },
                                    )
                                }
                                if (state.activeAgentCapabilities.compactThread ||
                                    state.activeAgentCapabilities.models || state.activeAgentCapabilities.approvals
                                ) {
                                    HorizontalDivider()
                                }
                                if (state.activeAgentCapabilities.compactThread) {
                                    DropdownMenuItem(
                                        text = { Text("压缩会话") },
                                        leadingIcon = { Icon(Icons.Default.Pending, contentDescription = null) },
                                        enabled = !state.loading && !state.submitting && !state.running,
                                        onClick = {
                                            actionMenuVisible = false
                                            onCompact()
                                        },
                                    )
                                }
                                if (state.activeAgentCapabilities.models) {
                                    DropdownMenuItem(
                                        text = { Text("选择模型") },
                                        leadingIcon = { Icon(Icons.Default.SmartToy, contentDescription = null) },
                                        enabled = !state.loading,
                                        onClick = {
                                            actionMenuVisible = false
                                            onShowModels()
                                        },
                                    )
                                }
                                if (state.activeAgentCapabilities.approvals) {
                                    DropdownMenuItem(
                                        text = { Text("权限") },
                                        leadingIcon = {
                                            Icon(approvalModeIcon(state.approvalMode), contentDescription = null)
                                        },
                                        enabled = !state.loading,
                                        onClick = {
                                            actionMenuVisible = false
                                            onShowPermissions()
                                        },
                                    )
                                }
                            }
                        }
                        if (state.activeAgentCapabilities.approvals) {
                            TextButton(
                                onClick = onShowPermissions,
                                modifier = Modifier.widthIn(max = 64.dp),
                                contentPadding = PaddingValues(horizontal = 2.dp),
                            ) {
                                val permissionColor = if (state.approvalMode == ApprovalMode.FullAccess) {
                                    CodexAmber
                                } else MaterialTheme.colorScheme.onSurfaceVariant
                                Icon(
                                    approvalModeIcon(state.approvalMode),
                                    contentDescription = "权限：${state.approvalMode.label}",
                                    modifier = Modifier.size(16.dp),
                                    tint = permissionColor,
                                )
                                Spacer(Modifier.width(3.dp))
                                Text(
                                    "权限",
                                    style = MaterialTheme.typography.labelMedium,
                                    color = permissionColor,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                        ContextUsageRing(
                            usage = contextUsageSummary(state.tokenUsage),
                        )
                        Spacer(Modifier.width(2.dp))
                        if (state.activeAgentCapabilities.models) {
                            TextButton(
                                onClick = onShowModels,
                                modifier = Modifier.weight(1f).widthIn(min = 0.dp),
                                contentPadding = PaddingValues(horizontal = 4.dp),
                            ) {
                                Text(
                                    modelLabel,
                                    style = MaterialTheme.typography.labelMedium,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        } else {
                            Spacer(Modifier.weight(1f))
                        }
                        Spacer(Modifier.width(6.dp))
                        val canSend = (value.isNotBlank() || state.attachments.isNotEmpty()) &&
                            !state.loading && !state.submitting
                        val actionEnabled = when {
                            state.submitting -> false
                            state.running -> !state.loading
                            else -> canSend
                        }
                        val actionActive = actionEnabled || state.submitting
                        IconButton(
                            onClick = {
                                if (state.running) onStop() else onSend()
                            },
                            enabled = actionEnabled,
                            modifier = Modifier.size(36.dp).clip(RoundedCornerShape(18.dp))
                                .background(
                                    if (actionActive) MaterialTheme.colorScheme.primary else Color(0xFF555555),
                                ),
                        ) {
                            if (state.submitting) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(18.dp),
                                    strokeWidth = 2.dp,
                                    color = MaterialTheme.colorScheme.onPrimary,
                                )
                            } else {
                                Icon(
                                    imageVector = if (state.running) Icons.Default.Stop else Icons.Default.ArrowUpward,
                                    contentDescription = if (state.running) "停止" else "发送",
                                    tint = if (actionEnabled) {
                                        MaterialTheme.colorScheme.onPrimary
                                    } else {
                                        Color(0xFFB0B0B0)
                                    },
                                    modifier = Modifier.size(if (state.running) 18.dp else 20.dp),
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

private fun approvalModeIcon(mode: ApprovalMode) = when (mode) {
    ApprovalMode.RequestApproval -> Icons.Default.PanTool
    ApprovalMode.AutoApprove -> Icons.Default.CheckCircle
    ApprovalMode.FullAccess -> Icons.Default.Shield
}

@Composable
private fun ThreadGoalBar(
    goal: ThreadGoal,
    mutationInProgress: Boolean,
    onEdit: () -> Unit,
    onTogglePause: () -> Unit,
    onDelete: () -> Unit,
) {
    var nowMillis by remember(goal.threadId, goal.updatedAt, goal.timeUsedSeconds) {
        mutableStateOf(System.currentTimeMillis())
    }
    LaunchedEffect(goal.threadId, goal.status, goal.updatedAt, goal.timeUsedSeconds) {
        nowMillis = System.currentTimeMillis()
        if (goal.status == ThreadGoalStatus.Active) {
            while (true) {
                delay(1_000)
                nowMillis = System.currentTimeMillis()
            }
        }
    }
    val pausable = goal.status == ThreadGoalStatus.Active || goal.status == ThreadGoalStatus.Paused
    val accent = when (goal.status) {
        ThreadGoalStatus.Active -> MaterialTheme.colorScheme.primary
        ThreadGoalStatus.Paused -> CodexAmber
        ThreadGoalStatus.Complete -> CodexGreen
        ThreadGoalStatus.Blocked, ThreadGoalStatus.UsageLimited, ThreadGoalStatus.BudgetLimited -> CodexRed
        ThreadGoalStatus.Unknown -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    Surface(
        shape = RoundedCornerShape(8.dp),
        color = Color(0xFF202020),
        modifier = Modifier.fillMaxWidth().border(1.dp, CodexBorder, RoundedCornerShape(8.dp)),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(start = 10.dp, end = 3.dp, top = 5.dp, bottom = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Default.TrackChanges,
                contentDescription = null,
                tint = accent,
                modifier = Modifier.size(18.dp),
            )
            Spacer(Modifier.width(8.dp))
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        goalStatusLabel(goal.status),
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        formatGoalElapsed(goal, nowMillis),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                    )
                }
                Text(
                    goal.objective,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (mutationInProgress) {
                CircularProgressIndicator(
                    modifier = Modifier.size(18.dp).padding(2.dp),
                    strokeWidth = 2.dp,
                )
            } else {
                IconButton(onClick = onEdit, modifier = Modifier.size(34.dp)) {
                    Icon(Icons.Default.Edit, contentDescription = "编辑目标", modifier = Modifier.size(18.dp))
                }
                if (pausable) {
                    IconButton(onClick = onTogglePause, modifier = Modifier.size(34.dp)) {
                        val paused = goal.status == ThreadGoalStatus.Paused
                        Icon(
                            if (paused) Icons.Default.PlayCircleOutline else Icons.Default.PauseCircleOutline,
                            contentDescription = if (paused) "继续目标" else "暂停目标",
                            modifier = Modifier.size(19.dp),
                        )
                    }
                }
                IconButton(onClick = onDelete, modifier = Modifier.size(34.dp)) {
                    Icon(Icons.Default.DeleteOutline, contentDescription = "删除目标", modifier = Modifier.size(19.dp))
                }
            }
        }
    }
}

private fun goalStatusLabel(status: ThreadGoalStatus): String = when (status) {
    ThreadGoalStatus.Active -> "进行中的目标"
    ThreadGoalStatus.Paused -> "已暂停的目标"
    ThreadGoalStatus.Blocked -> "已阻塞的目标"
    ThreadGoalStatus.UsageLimited -> "已达用量限制"
    ThreadGoalStatus.BudgetLimited -> "已达预算限制"
    ThreadGoalStatus.Complete -> "已完成目标"
    ThreadGoalStatus.Unknown -> "目标"
}

internal fun shouldConfirmGoalPause(status: ThreadGoalStatus?): Boolean =
    status == ThreadGoalStatus.Active

private fun formatGoalElapsed(goal: ThreadGoal, nowMillis: Long): String {
    val updatedAtMillis = normalizeEpochMillis(goal.updatedAt) ?: nowMillis
    val secondsSinceUpdate = if (goal.status == ThreadGoalStatus.Active) {
        ((nowMillis - updatedAtMillis).coerceAtLeast(0L) / 1_000L)
    } else {
        0L
    }
    val seconds = (goal.timeUsedSeconds.coerceAtLeast(0L) + secondsSinceUpdate)
    return when {
        seconds < 60L -> "${seconds}s"
        seconds < 3_600L -> "${seconds / 60}m ${seconds % 60}s"
        else -> "${seconds / 3_600}h ${(seconds % 3_600) / 60}m"
    }
}

@Composable
private fun ProcessingStatusText(elapsed: String?) {
    val transition = rememberInfiniteTransition(label = "processing-text-gradient")
    val gradientOffset by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 2_000, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "processing-text-gradient-offset",
    )
    val baseTextColor = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.64f)
    val softHighlightColor = Color.White.copy(alpha = 0.68f)
    val brightHighlightColor = Color.White.copy(alpha = 0.92f)
    val sweepHalfWidth = with(LocalDensity.current) { 24.dp.toPx() }
    val statusTextWidth = with(LocalDensity.current) { 56.dp.toPx() }
    val gradientCenter = -sweepHalfWidth + gradientOffset * (statusTextWidth + sweepHalfWidth * 2f)
    val textBrush = Brush.linearGradient(
        colorStops = arrayOf(
            0f to baseTextColor,
            0.16f to baseTextColor,
            0.34f to softHighlightColor,
            0.5f to brightHighlightColor,
            0.66f to softHighlightColor,
            0.84f to baseTextColor,
            1f to baseTextColor,
        ),
        start = Offset(gradientCenter - sweepHalfWidth, 0f),
        end = Offset(gradientCenter + sweepHalfWidth, 0f),
    )
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            text = "正在处理",
            style = MaterialTheme.typography.bodySmall.copy(brush = textBrush),
        )
        if (elapsed != null) {
            Spacer(Modifier.width(6.dp))
            Text(
                text = elapsed,
                style = MaterialTheme.typography.bodySmall,
                color = baseTextColor,
            )
        }
    }
}

internal fun formatTurnElapsed(startedAtMillis: Long, endedAtMillis: Long): String {
    val normalizedStart = normalizeEpochMillis(startedAtMillis) ?: endedAtMillis
    val seconds = ((endedAtMillis - normalizedStart).coerceAtLeast(0L) / 1_000L)
    val hours = seconds / 3_600L
    val minutes = (seconds % 3_600L) / 60L
    val remainderSeconds = seconds % 60L
    return when {
        hours > 0L -> "${hours}h ${minutes}m ${remainderSeconds}s"
        minutes > 0L -> "${minutes}m ${remainderSeconds}s"
        else -> "${remainderSeconds}s"
    }
}

private fun formatTurnCompletionTime(completedAtMillis: Long): String =
    Instant.ofEpochMilli(completedAtMillis)
        .atZone(ZoneId.systemDefault())
        .format(TURN_COMPLETION_TIME_FORMATTER)

private val TURN_COMPLETION_TIME_FORMATTER: DateTimeFormatter = DateTimeFormatter.ofPattern("HH:mm:ss")

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ModelSheet(
    models: List<CodexModel>,
    selectedModel: String?,
    selectedEffort: String?,
    onSelectModel: (String, String?) -> Unit,
    onSelectEffort: (String) -> Unit,
    showReasoningEffort: Boolean,
    onManageModels: () -> Unit,
    onDismiss: () -> Unit,
) {
    val selected = models.firstOrNull { it.model == selectedModel || it.id == selectedModel }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp, top = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("模型", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
            IconButton(onClick = onManageModels) {
                Icon(Icons.Default.Settings, contentDescription = "管理模型")
            }
        }
        if (models.isEmpty()) {
            Text(
                "暂无可用模型",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 28.dp),
            )
        } else {
            LazyColumn(Modifier.fillMaxWidth().fillMaxHeight(0.55f)) {
                items(models, key = { "${it.id}:${it.model}" }) { model ->
                    Row(
                        modifier = Modifier.fillMaxWidth().clickable {
                            onSelectModel(model.model, model.defaultEffort)
                        }.padding(horizontal = 20.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text(model.displayName, fontWeight = FontWeight.Medium)
                            if (model.model != model.displayName) {
                                Text(
                                    model.model,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                            if (model.description.isNotBlank()) {
                                Text(
                                    model.description,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 2,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                            ModelCapabilityText(
                                contextWindowTokens = model.contextWindowTokens,
                                maxOutputTokens = model.maxOutputTokens,
                            )
                        }
                        if (model == selected) {
                            Icon(
                                Icons.Default.CheckCircle,
                                contentDescription = null,
                                tint = CodexGreen,
                                modifier = Modifier.size(18.dp),
                            )
                        }
                    }
                }
            }
        }
        selected?.efforts?.takeIf { showReasoningEffort && it.isNotEmpty() }?.let { efforts ->
            HorizontalDivider(color = CodexBorder)
            Text("思考强度", style = MaterialTheme.typography.labelLarge,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp))
            Row(
                modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
                    .padding(horizontal = 20.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                efforts.forEach { effort ->
                    FilterChip(
                        selected = effort == selectedEffort,
                        onClick = { onSelectEffort(effort) },
                        label = { Text(reasoningEffortLabel(effort)) },
                    )
                }
            }
        }
        Spacer(Modifier.height(22.dp).navigationBarsPadding())
    }
}

private fun reasoningEffortLabel(effort: String): String = when (effort) {
    "minimal" -> "极低"
    "low" -> "低"
    "medium" -> "中"
    "high" -> "高"
    "xhigh" -> "极高"
    else -> effort
}

private data class ModelEditorRequest(
    val originalModelId: String? = null,
    val definition: CustomModelDefinition = CustomModelDefinition(),
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ModelManagerSheet(
    models: List<CodexModel>,
    customModels: List<CustomModelDefinition>,
    hiddenModelIds: List<String>,
    apiModelOptions: List<ApiModelOption>,
    apiModelOptionsLoading: Boolean,
    apiModelOptionsError: String?,
    canFetchApiModels: Boolean,
    onSaveCustomModel: (String?, CustomModelDefinition) -> Unit,
    onDeleteCustomModel: (String) -> Unit,
    onSetModelHidden: (String, Boolean) -> Unit,
    onFetchApiModelOptions: () -> Unit,
    onDismiss: () -> Unit,
) {
    var editorRequest by remember { mutableStateOf<ModelEditorRequest?>(null) }
    var deleteRequested by remember { mutableStateOf<CustomModelDefinition?>(null) }
    val modelListState = remember(customModels.map(CustomModelDefinition::modelId)) { LazyListState() }
    val remoteModels = models.filterNot { it.isCustom }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text("模型管理", style = MaterialTheme.typography.titleMedium)
                Text(
                    "仅影响当前服务器",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            OutlinedButton(onClick = { editorRequest = ModelEditorRequest() }) {
                Icon(Icons.Default.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text("新增模型")
            }
        }
        LazyColumn(
            state = modelListState,
            modifier = Modifier.fillMaxWidth().fillMaxHeight(0.68f),
            contentPadding = PaddingValues(bottom = 8.dp),
        ) {
            if (customModels.isNotEmpty()) {
                item(key = "custom-title") {
                    ModelManagerSectionTitle("自定义模型")
                }
                items(customModels, key = { "custom-${it.modelId}" }) { definition ->
                    ModelManagerCustomRow(
                        definition = definition,
                        onEdit = {
                            editorRequest = ModelEditorRequest(
                                originalModelId = definition.modelId,
                                definition = definition,
                            )
                        },
                        onDelete = { deleteRequested = definition },
                    )
                }
            }
            if (remoteModels.isNotEmpty()) {
                item(key = "remote-title") {
                    ModelManagerSectionTitle("远端模型")
                }
                items(remoteModels, key = { "remote-${it.id}:${it.model}" }) { model ->
                    ModelManagerRemoteRow(
                        model = model,
                        onHide = { onSetModelHidden(model.model, true) },
                    )
                }
            }
            if (hiddenModelIds.isNotEmpty()) {
                item(key = "hidden-title") {
                    ModelManagerSectionTitle("已隐藏模型")
                }
                items(hiddenModelIds, key = { "hidden-$it" }) { modelId ->
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp, top = 8.dp, bottom = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            modelId,
                            modifier = Modifier.weight(1f),
                            style = MaterialTheme.typography.bodyMedium,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        IconButton(onClick = { onSetModelHidden(modelId, false) }) {
                            Icon(Icons.Default.Visibility, contentDescription = "显示模型")
                        }
                    }
                }
            }
            if (customModels.isEmpty() && remoteModels.isEmpty() && hiddenModelIds.isEmpty()) {
                item(key = "empty") {
                    Text(
                        "暂无模型，可新增模型或重新连接服务器刷新远端列表",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 20.dp, vertical = 24.dp),
                    )
                }
            }
        }
        Spacer(Modifier.height(16.dp).navigationBarsPadding())
    }
    editorRequest?.let { request ->
        CustomModelEditorDialog(
            request = request,
            existingModelIds = customModels.map { it.modelId },
            apiModelOptions = apiModelOptions,
            apiModelOptionsLoading = apiModelOptionsLoading,
            apiModelOptionsError = apiModelOptionsError,
            canFetchApiModels = canFetchApiModels,
            onFetchApiModelOptions = onFetchApiModelOptions,
            onSave = { definition ->
                onSaveCustomModel(request.originalModelId, definition)
                editorRequest = null
            },
            onDismiss = { editorRequest = null },
        )
    }
    deleteRequested?.let { definition ->
        AlertDialog(
            onDismissRequest = { deleteRequested = null },
            title = { Text("删除自定义模型？") },
            text = { Text(definition.displayName.ifBlank { definition.modelId }) },
            confirmButton = {
                TextButton(onClick = {
                    onDeleteCustomModel(definition.modelId)
                    deleteRequested = null
                }) { Text("删除", color = CodexRed) }
            },
            dismissButton = { TextButton(onClick = { deleteRequested = null }) { Text("取消") } },
        )
    }
}

@Composable
private fun ModelManagerSectionTitle(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp),
    )
}

@Composable
private fun ModelManagerCustomRow(
    definition: CustomModelDefinition,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(start = 20.dp, end = 4.dp, top = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(definition.displayName.ifBlank { definition.modelId }, fontWeight = FontWeight.Medium)
            if (definition.displayName.isNotBlank()) {
                Text(
                    definition.modelId,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            ModelCapabilityText(definition.contextWindowTokens, definition.maxOutputTokens)
        }
        IconButton(onClick = onEdit) {
            Icon(Icons.Default.Edit, contentDescription = "编辑自定义模型")
        }
        IconButton(onClick = onDelete) {
            Icon(Icons.Default.DeleteOutline, contentDescription = "删除自定义模型", tint = CodexRed)
        }
    }
}

@Composable
private fun ModelManagerRemoteRow(model: CodexModel, onHide: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp, top = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(model.displayName, fontWeight = FontWeight.Medium)
            if (model.model != model.displayName) {
                Text(
                    model.model,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            ModelCapabilityText(model.contextWindowTokens, model.maxOutputTokens)
        }
        IconButton(onClick = onHide) {
            Icon(Icons.Default.VisibilityOff, contentDescription = "隐藏模型")
        }
    }
}

@Composable
private fun ModelCapabilityText(contextWindowTokens: Long, maxOutputTokens: Long) {
    val details = buildList {
        if (contextWindowTokens > 0L) add("上下文 ${formatModelTokenLimit(contextWindowTokens)}")
        if (maxOutputTokens > 0L) add("输出 ${formatModelTokenLimit(maxOutputTokens)}")
    }
    if (details.isNotEmpty()) {
        Text(
            details.joinToString(" · "),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun CustomModelEditorDialog(
    request: ModelEditorRequest,
    existingModelIds: List<String>,
    apiModelOptions: List<ApiModelOption>,
    apiModelOptionsLoading: Boolean,
    apiModelOptionsError: String?,
    canFetchApiModels: Boolean,
    onFetchApiModelOptions: () -> Unit,
    onSave: (CustomModelDefinition) -> Unit,
    onDismiss: () -> Unit,
) {
    var modelId by remember(request) { mutableStateOf(request.definition.modelId) }
    var displayName by remember(request) { mutableStateOf(request.definition.displayName) }
    var contextWindow by remember(request) {
        mutableStateOf(request.definition.contextWindowTokens.takeIf { it > 0L }?.toString().orEmpty())
    }
    var maxOutput by remember(request) {
        mutableStateOf(request.definition.maxOutputTokens.takeIf { it > 0L }?.toString().orEmpty())
    }
    var apiSearch by remember(request) { mutableStateOf("") }
    val normalizedId = modelId.trim()
    val contextValue = contextWindow.trim().toLongOrNull()
    val maxOutputValue = maxOutput.trim().toLongOrNull()
    val invalidContext = contextWindow.isNotBlank() && (contextValue == null || contextValue < 0L)
    val invalidMaxOutput = maxOutput.isNotBlank() && (maxOutputValue == null || maxOutputValue < 0L)
    val duplicateId = normalizedId.isNotBlank() && normalizedId != request.originalModelId &&
        normalizedId in existingModelIds
    val modelIdValid = normalizedId.matches(Regex("[A-Za-z0-9._:/@+\\-]+")) && normalizedId.length <= 200
    val canSave = modelIdValid && !duplicateId && !invalidContext && !invalidMaxOutput
    val visibleApiOptions = apiModelOptions.asSequence()
        .filter { option ->
            val query = apiSearch.trim()
            query.isBlank() || option.modelId.contains(query, ignoreCase = true) ||
                option.displayName.contains(query, ignoreCase = true)
        }
        .take(80)
        .toList()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (request.originalModelId == null) "新增模型" else "编辑自定义模型") },
        text = {
            Column(
                modifier = Modifier.heightIn(max = 500.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                if (canFetchApiModels) {
                    OutlinedButton(
                        onClick = onFetchApiModelOptions,
                        enabled = !apiModelOptionsLoading,
                    ) {
                        if (apiModelOptionsLoading) {
                            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                        } else {
                            Icon(Icons.Default.Refresh, contentDescription = null, modifier = Modifier.size(18.dp))
                        }
                        Spacer(Modifier.width(7.dp))
                        Text("获取 API 模型列表")
                    }
                    apiModelOptionsError?.let { message ->
                        Text(message, style = MaterialTheme.typography.bodySmall, color = CodexRed)
                    }
                }
                if (apiModelOptions.isNotEmpty()) {
                    Text("从 API 列表选择", style = MaterialTheme.typography.labelLarge)
                    OutlinedTextField(
                        value = apiSearch,
                        onValueChange = { apiSearch = it },
                        label = { Text("筛选模型") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    visibleApiOptions.forEach { option ->
                        Row(
                            modifier = Modifier.fillMaxWidth().clickable {
                                modelId = option.modelId
                                if (displayName.isBlank()) displayName = option.displayName
                                if (option.contextWindowTokens > 0L) {
                                    contextWindow = option.contextWindowTokens.toString()
                                }
                                if (option.maxOutputTokens > 0L) {
                                    maxOutput = option.maxOutputTokens.toString()
                                }
                            }.padding(vertical = 7.dp),
                        ) {
                            Column {
                                Text(option.displayName.ifBlank { option.modelId }, fontWeight = FontWeight.Medium)
                                if (option.displayName.isNotBlank()) {
                                    Text(
                                        option.modelId,
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                }
                                ModelCapabilityText(option.contextWindowTokens, option.maxOutputTokens)
                            }
                        }
                    }
                }
                HorizontalDivider(color = CodexBorder)
                OutlinedTextField(
                    value = modelId,
                    onValueChange = { modelId = it },
                    label = { Text("模型 ID") },
                    singleLine = true,
                    isError = modelId.isNotBlank() && (!modelIdValid || duplicateId),
                    supportingText = {
                        when {
                            duplicateId -> Text("已有相同的自定义模型 ID")
                            modelId.isNotBlank() && !modelIdValid -> Text("仅支持字母、数字及 . _ - / : @ +")
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = displayName,
                    onValueChange = { displayName = it },
                    label = { Text("显示名称（可选）") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = contextWindow,
                    onValueChange = { contextWindow = it },
                    label = { Text("上下文长度（tokens，可选）") },
                    singleLine = true,
                    isError = invalidContext,
                    supportingText = { if (invalidContext) Text("请输入非负整数") },
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = maxOutput,
                    onValueChange = { maxOutput = it },
                    label = { Text("最大输出长度（tokens，可选）") },
                    singleLine = true,
                    isError = invalidMaxOutput,
                    supportingText = { if (invalidMaxOutput) Text("请输入非负整数") },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            Button(
                onClick = {
                    onSave(
                        CustomModelDefinition(
                            modelId = normalizedId,
                            displayName = displayName.trim(),
                            contextWindowTokens = contextValue ?: 0L,
                            maxOutputTokens = maxOutputValue ?: 0L,
                        ),
                    )
                },
                enabled = canSave,
            ) { Text("保存") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}

private fun formatModelTokenLimit(value: Long): String = when {
    value >= 1_000L && value % 1_000L == 0L -> "${value / 1_000L}K"
    else -> value.toString()
}
