package top.asdb.codexremote.ui

import android.content.Context
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.material.icons.filled.RateReview
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.SmartToy
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.TrackChanges
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.nestedscroll.nestedScroll
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
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import kotlin.math.roundToInt
import top.asdb.codexremote.data.AppUiState
import top.asdb.codexremote.data.AppScreen
import top.asdb.codexremote.data.ApprovalMode
import top.asdb.codexremote.data.CodexModel
import top.asdb.codexremote.data.FileChange
import top.asdb.codexremote.data.ThreadGoal
import top.asdb.codexremote.data.ThreadGoalStatus
import top.asdb.codexremote.data.TimelineEntry
import top.asdb.codexremote.data.TimelineKind
import top.asdb.codexremote.ui.components.MarkdownText
import top.asdb.codexremote.ui.theme.CodexAmber
import top.asdb.codexremote.ui.theme.CodexBorder
import top.asdb.codexremote.ui.theme.CodexGreen
import top.asdb.codexremote.ui.theme.CodexRed
import top.asdb.codexremote.ui.theme.CodexSurfaceRaised

@OptIn(
    ExperimentalMaterial3Api::class,
    ExperimentalLayoutApi::class,
    ExperimentalComposeUiApi::class,
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
    onUpload: (Context, Uri) -> Unit,
    onRemoveAttachment: (String) -> Unit,
    onComposerChange: (String) -> Unit,
    onSelectModel: (String, String?) -> Unit,
    onSelectEffort: (String) -> Unit,
    onSelectApprovalMode: (ApprovalMode) -> Unit,
    onSetGoal: (String) -> Unit,
    onToggleGoalPause: () -> Unit,
    onClearGoal: () -> Unit,
    onCompact: () -> Unit = {},
    onLoadOlder: () -> Unit = {},
    onOpenSubAgent: (threadId: String, agentName: String) -> Unit = { _, _ -> },
) {
    val timelineRows = remember(state.timeline) { state.timeline.toTimelineRenderRows() }
    val backgroundAgents = remember(state.timeline) { state.timeline.toSubAgentPresentations() }
    val canOpenSubAgents = !state.loading && !state.submitting && state.approvalQueue.isEmpty()
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
    var showPermissions by remember { mutableStateOf(false) }
    var showMenu by remember { mutableStateOf(false) }
    var renameRequested by remember { mutableStateOf(false) }
    var rollbackRequested by remember { mutableStateOf(false) }
    var archiveRequested by remember { mutableStateOf(false) }
    var fullAccessRequested by remember { mutableStateOf(false) }
    var compactRequested by remember { mutableStateOf(false) }
    var goalEditorVisible by remember { mutableStateOf(false) }
    var goalDeleteRequested by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val filePicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let { onUpload(context, it) }
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
    val lastEntry = state.timeline.lastOrNull()
    val latestFileChangeId = state.timeline.lastOrNull { it.kind == TimelineKind.FileChange }?.id
    var followOutput by remember(state.activeThread?.id) { mutableStateOf(true) }
    val trailingItemIndex = timelineRows.size +
        (if (state.aggregateDiff.isNotBlank()) 1 else 0) +
        (if (state.running) 1 else 0)

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

    // Track whether the reader is at the end before a streaming update arrives.
    // New deltas should not pull a user away from an earlier part of the transcript.
    LaunchedEffect(listState) {
        snapshotFlow {
            val layout = listState.layoutInfo
            val lastVisible = layout.visibleItemsInfo.lastOrNull()?.index ?: -1
            val atEnd = layout.totalItemsCount == 0 || lastVisible >= layout.totalItemsCount - 1
            atEnd to listState.isScrollInProgress
        }.distinctUntilChanged().collect { (atEnd, userScrolling) ->
            when {
                atEnd -> followOutput = true
                userScrolling -> followOutput = false
            }
        }
    }

    LaunchedEffect(
        state.timeline.size,
        lastEntry?.text?.length,
        lastEntry?.output?.length,
        lastEntry?.changes?.size,
        state.aggregateDiff.length,
    ) {
        if (followOutput && trailingItemIndex > 0) {
            // Scroll to the fixed spacer after the timeline, aggregate diff, and running indicator.
            listState.animateScrollToItem(trailingItemIndex)
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
                            DropdownMenuItem(
                                text = { Text("重命名") },
                                leadingIcon = { Icon(Icons.Default.Edit, contentDescription = null) },
                                enabled = !state.loading && !state.submitting,
                                onClick = { showMenu = false; renameRequested = true },
                            )
                            if (state.screen != AppScreen.AgentWork) {
                                DropdownMenuItem(
                                    text = { Text("归档") },
                                    leadingIcon = { Icon(Icons.Default.Archive, contentDescription = null) },
                                    enabled = !state.loading && !state.submitting && !state.running,
                                    onClick = { showMenu = false; archiveRequested = true },
                                )
                            }
                            DropdownMenuItem(
                                text = { Text(if (state.activeGoal == null) "设置目标" else "编辑目标") },
                                leadingIcon = { Icon(Icons.Default.TrackChanges, contentDescription = null) },
                                enabled = !state.loading && !state.submitting,
                                onClick = { showMenu = false; goalEditorVisible = true },
                            )
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
                onAttach = { filePicker.launch(arrayOf("image/*", "text/*", "application/pdf")) },
                onRemoveAttachment = onRemoveAttachment,
                onSend = { onSend(state.composerDraft) },
                onStop = onStop,
                onShowModels = { showModels = true },
                onShowPermissions = { showPermissions = true },
                onCompact = { compactRequested = true },
                onEditGoal = { goalEditorVisible = true },
                onToggleGoalPause = onToggleGoalPause,
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
                                canMutate = !state.loading && !state.submitting && !state.running,
                                canRollback = !state.loading && !state.submitting &&
                                    !state.running && entry.id == latestFileChangeId,
                                onRollback = { rollbackRequested = true },
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
                        Row(
                            modifier = Modifier.semantics {
                                contentDescription = "Codex 正在处理"
                            },
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                            Spacer(Modifier.width(9.dp))
                            Text("正在处理", color = MaterialTheme.colorScheme.onSurfaceVariant,
                                style = MaterialTheme.typography.bodySmall)
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

    selectedDiff?.let { change ->
        DiffViewer(change = change, onDismiss = { selectedDiff = null })
    }

    if (showModels) {
        ModelSheet(
            models = state.models,
            selectedModel = state.selectedModel,
            selectedEffort = state.selectedEffort,
            onSelectModel = onSelectModel,
            onSelectEffort = onSelectEffort,
            onDismiss = { showModels = false },
        )
    }

    if (showPermissions) {
        ModalBottomSheet(onDismissRequest = { showPermissions = false }) {
            Text(
                "应如何批准 Codex 操作?",
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
            text = { Text("Codex 将不受工作区沙箱限制。") },
            confirmButton = {
                TextButton(onClick = {
                    onSelectApprovalMode(ApprovalMode.FullAccess)
                    fullAccessRequested = false
                }) { Text("启用", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { fullAccessRequested = false }) { Text("取消") } },
        )
    }

    if (compactRequested) {
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

    if (goalEditorVisible) {
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

    if (goalDeleteRequested) {
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

    if (rollbackRequested) {
        AlertDialog(
            onDismissRequest = { rollbackRequested = false },
            title = { Text("撤销上一轮") },
            text = {
                Text("这只会回退 Codex 会话历史，不会自动恢复服务器上的本地文件。需要恢复文件时，请使用版本控制或手动编辑。")
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
    canMutate: Boolean,
    canRollback: Boolean,
    onRollback: () -> Unit,
    onOpenSubAgent: (threadId: String, agentName: String) -> Unit,
    canOpenSubAgents: Boolean,
) {
    when (entry.kind) {
        TimelineKind.UserMessage -> Surface(
            color = MaterialTheme.colorScheme.surfaceVariant,
            shape = RoundedCornerShape(6.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            SelectionContainer {
                Text(entry.text, modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp))
            }
        }

        TimelineKind.AgentMessage -> MarkdownText(entry.text, Modifier.fillMaxWidth())
        TimelineKind.Reasoning, TimelineKind.Plan -> CollapsibleText(entry)
        TimelineKind.Command -> CommandBlock(entry)
        TimelineKind.FileChange -> FileChangeBlock(entry, onOpenDiff, onReview, canMutate, canRollback, onRollback)
        TimelineKind.Tool -> ToolBlock(entry)
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
                    MarkdownText(entry.text)
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
                    "${it.usedPercent}% 已用，剩余 ${it.remainingPercent}%"
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
                        "已用 ${formatContextTokenCount(usage.usedTokens)} 标记，共 " +
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
    canMutate: Boolean,
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
                IconButton(
                    onClick = onRollback,
                    enabled = canRollback && entry.status != "inProgress" && entry.changes.isNotEmpty(),
                    modifier = Modifier.size(36.dp),
                ) {
                    Icon(
                        Icons.AutoMirrored.Filled.Undo,
                        contentDescription = "撤销上一轮会话",
                        modifier = Modifier.size(19.dp),
                    )
                }
                Spacer(Modifier.width(4.dp))
                OutlinedButton(
                    onClick = onReview,
                    enabled = canMutate,
                    modifier = Modifier.height(36.dp),
                    shape = RoundedCornerShape(7.dp),
                    contentPadding = PaddingValues(horizontal = 12.dp),
                ) {
                    Text("审核", style = MaterialTheme.typography.labelLarge)
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
private fun ToolBlock(entry: TimelineEntry) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceVariant,
        shape = RoundedCornerShape(6.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(11.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Code, contentDescription = null, modifier = Modifier.size(17.dp))
                Spacer(Modifier.width(8.dp))
                Text(entry.title.ifBlank { "工具" }, modifier = Modifier.weight(1f),
                    style = MaterialTheme.typography.labelLarge)
                StatusText(entry.status)
            }
            if (entry.text.isNotBlank()) {
                Spacer(Modifier.height(7.dp))
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

@Composable
private fun SubAgentActivityGroupBlock(
    entries: List<TimelineEntry>,
    onOpenSubAgent: (threadId: String, agentName: String) -> Unit,
    enabled: Boolean,
) {
    val agents = remember(entries) { entries.toSubAgentPresentations() }
    if (agents.isEmpty()) return
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 3.dp, vertical = 1.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        agents.forEach { agent ->
            SubAgentStatusRow(
                agent = agent,
                onOpenSubAgent = onOpenSubAgent,
                enabled = enabled,
                framed = true,
                avatarSize = 22.dp,
                horizontalPadding = 10.dp,
                verticalPadding = 7.dp,
            )
        }
    }
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
    val statusColor = subAgentStatusColor(agent.status)
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
        if (agent.status.isActive) {
            CircularProgressIndicator(
                modifier = Modifier.size(16.dp),
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
    onAttach: () -> Unit,
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
    val modelName = state.models.firstOrNull { it.model == state.selectedModel }?.displayName
        ?: state.selectedModel ?: "模型"
    val effortName = when (state.selectedEffort) {
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
            state.activeGoal?.let { goal ->
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
                        IconButton(onClick = onAttach, enabled = !state.loading,
                            modifier = Modifier.size(36.dp)) {
                            Icon(Icons.Default.Add, contentDescription = "添加附件", modifier = Modifier.size(20.dp))
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
                                state.activeGoal?.let { goal ->
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
                                HorizontalDivider()
                                DropdownMenuItem(
                                    text = { Text("压缩会话") },
                                    leadingIcon = { Icon(Icons.Default.Pending, contentDescription = null) },
                                    enabled = !state.loading && !state.submitting && !state.running,
                                    onClick = {
                                        actionMenuVisible = false
                                        onCompact()
                                    },
                                )
                                DropdownMenuItem(
                                    text = { Text("选择模型") },
                                    leadingIcon = { Icon(Icons.Default.SmartToy, contentDescription = null) },
                                    enabled = !state.loading,
                                    onClick = {
                                        actionMenuVisible = false
                                        onShowModels()
                                    },
                                )
                                DropdownMenuItem(
                                    text = { Text("权限") },
                                    leadingIcon = { Icon(Icons.Default.Shield, contentDescription = null) },
                                    enabled = !state.loading,
                                    onClick = {
                                        actionMenuVisible = false
                                        onShowPermissions()
                                    },
                                )
                            }
                        }
                        TextButton(
                            onClick = onShowPermissions,
                            modifier = Modifier.widthIn(max = 82.dp),
                            contentPadding = PaddingValues(horizontal = 5.dp),
                        ) {
                            val permissionColor = if (state.approvalMode == ApprovalMode.FullAccess) {
                                CodexAmber
                            } else MaterialTheme.colorScheme.onSurfaceVariant
                            Icon(
                                Icons.Default.Shield,
                                contentDescription = null,
                                modifier = Modifier.size(16.dp),
                                tint = permissionColor,
                            )
                            Spacer(Modifier.width(4.dp))
                            Text(
                                state.approvalMode.label,
                                style = MaterialTheme.typography.labelMedium,
                                color = permissionColor,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        Spacer(Modifier.weight(1f))
                        ContextUsageRing(
                            usage = contextUsageSummary(state.tokenUsage),
                        )
                        Spacer(Modifier.width(2.dp))
                        TextButton(
                            onClick = onShowModels,
                            modifier = Modifier.widthIn(max = 116.dp),
                            contentPadding = PaddingValues(horizontal = 5.dp),
                        ) {
                            Text(
                                modelLabel,
                                style = MaterialTheme.typography.labelMedium,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        Spacer(Modifier.width(6.dp))
                        val canSend = (value.isNotBlank() || state.attachments.isNotEmpty()) &&
                            !state.loading && !state.submitting
                        val actionEnabled = if (state.running) !state.loading else canSend
                        IconButton(
                            onClick = {
                                if (state.running) onStop() else onSend()
                            },
                            enabled = actionEnabled,
                            modifier = Modifier.size(36.dp).clip(RoundedCornerShape(18.dp))
                                .background(
                                    if (actionEnabled) MaterialTheme.colorScheme.primary else Color(0xFF555555),
                                ),
                        ) {
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

private fun formatGoalElapsed(goal: ThreadGoal, nowMillis: Long): String {
    val updatedAtMillis = when {
        goal.updatedAt <= 0L -> nowMillis
        goal.updatedAt < 100_000_000_000L -> goal.updatedAt * 1_000L
        else -> goal.updatedAt
    }
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ModelSheet(
    models: List<CodexModel>,
    selectedModel: String?,
    selectedEffort: String?,
    onSelectModel: (String, String?) -> Unit,
    onSelectEffort: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val selected = models.firstOrNull { it.model == selectedModel || it.id == selectedModel }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Text("模型", style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp))
        LazyColumn(Modifier.fillMaxWidth().fillMaxHeight(0.55f)) {
            items(models, key = { it.id }) { model ->
                Row(
                    modifier = Modifier.fillMaxWidth().clickable {
                        onSelectModel(model.model, model.defaultEffort)
                    }.padding(horizontal = 20.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(model.displayName, fontWeight = FontWeight.Medium)
                        if (model.description.isNotBlank()) {
                            Text(model.description, style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 2, overflow = TextOverflow.Ellipsis)
                        }
                    }
                    if (model == selected) {
                        Icon(Icons.Default.CheckCircle, contentDescription = null, tint = CodexGreen,
                            modifier = Modifier.size(18.dp))
                    }
                }
            }
        }
        selected?.efforts?.takeIf { it.isNotEmpty() }?.let { efforts ->
            HorizontalDivider(color = CodexBorder)
            Text("推理强度", style = MaterialTheme.typography.labelLarge,
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
                        label = { Text(effort) },
                    )
                }
            }
        }
        Spacer(Modifier.height(22.dp).navigationBarsPadding())
    }
}
