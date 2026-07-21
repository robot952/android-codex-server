package top.asdb.codexremote.ui

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Color as AndroidColor
import android.util.Base64
import android.view.View
import android.view.ViewGroup
import android.webkit.JavascriptInterface
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Toast
import java.io.ByteArrayOutputStream
import java.util.Collections
import java.util.IdentityHashMap
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import top.asdb.codexremote.diagnostics.DiagnosticLogger
import top.asdb.codexremote.ssh.SshTerminalOutputBatch
import top.asdb.codexremote.ssh.SshTerminalOutputChunk
import top.asdb.codexremote.ssh.SshTerminalOutputSignal
import top.asdb.codexremote.ssh.SshTerminalPhase
import top.asdb.codexremote.ssh.SshTerminalSessionState
import top.asdb.codexremote.ui.theme.CodexGreen

@OptIn(ExperimentalComposeUiApi::class)
@Composable
internal fun SshTerminalScreen(
    session: SshTerminalSessionState,
    outputSignals: SharedFlow<SshTerminalOutputSignal>,
    onReadOutput: (String, Long, Long) -> SshTerminalOutputBatch,
    onSend: (String, ByteArray) -> Boolean,
    onResize: (String, Int, Int) -> Unit,
    onRetry: (String) -> Unit,
    onHide: () -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val focusManager = LocalFocusManager.current
    val keyboardController = LocalSoftwareKeyboardController.current
    var closeRequested by remember(session.profileId) { mutableStateOf(false) }
    var terminalWebView by remember(session.profileId) { mutableStateOf<WebView?>(null) }
    var controlEnabled by remember(session.profileId) { mutableStateOf(false) }
    var altEnabled by remember(session.profileId) { mutableStateOf(false) }

    fun hideTerminal() {
        terminalWebView?.clearFocus()
        focusManager.clearFocus(force = true)
        keyboardController?.hide()
        onHide()
    }

    fun sendInput(value: String) {
        if (value.isEmpty()) return
        val maxPayloadBytes = MAX_TERMINAL_INPUT_BYTES - if (altEnabled) 1 else 0
        val limited = limitTerminalUtf8(value, maxPayloadBytes)
        val encoded = encodeTerminalInput(limited.value, controlEnabled, altEnabled)
        controlEnabled = false
        altEnabled = false
        if (limited.truncated) {
            Toast.makeText(context, "输入内容过大，已限制为 512 KiB", Toast.LENGTH_SHORT).show()
        }
        if (!onSend(session.profileId, encoded)) {
            Toast.makeText(context, "终端输入队列已满，请稍后重试", Toast.LENGTH_SHORT).show()
        }
    }

    BackHandler(onBack = ::hideTerminal)

    Surface(color = Color.Black, modifier = Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().imePadding(),
        ) {
            TerminalTopBar(
                session = session,
                onCopy = {
                    terminalWebView?.evaluateJavascript("window.enterCopyMode()", null)
                },
                onPaste = {
                    clipboardText(context)?.takeIf(String::isNotEmpty)?.let { value ->
                        val limited = limitTerminalUtf8(value, MAX_TERMINAL_INPUT_BYTES)
                        if (limited.truncated) {
                            Toast.makeText(context, "粘贴内容过大，已限制为 512 KiB", Toast.LENGTH_SHORT).show()
                        }
                        if (!onSend(session.profileId, limited.bytes)) {
                            Toast.makeText(context, "终端输入队列已满，请稍后重试", Toast.LENGTH_SHORT).show()
                        }
                    }
                },
                onHide = ::hideTerminal,
                onClose = { closeRequested = true },
            )
            HorizontalDivider(color = Color(0xFF303030))
            Box(Modifier.fillMaxWidth().weight(1f)) {
                when (session.phase) {
                    SshTerminalPhase.Connected -> TerminalWebView(
                        profileId = session.profileId,
                        generation = session.generation,
                        outputSignals = outputSignals,
                        onReadOutput = onReadOutput,
                        onInput = ::sendInput,
                        onResize = onResize,
                        onCopy = { value -> copyToClipboard(context, value) },
                        onWebViewChanged = { terminalWebView = it },
                    )

                    SshTerminalPhase.Connecting -> TerminalStatus(
                        loading = true,
                        title = "正在连接 SSH",
                        detail = session.endpoint,
                        onRetry = null,
                    )

                    SshTerminalPhase.Failed -> TerminalStatus(
                        loading = false,
                        title = "SSH 终端连接失败",
                        detail = session.message,
                        onRetry = { onRetry(session.profileId) },
                    )

                    SshTerminalPhase.Disconnected -> TerminalStatus(
                        loading = false,
                        title = "SSH 终端已断开",
                        detail = session.message,
                        onRetry = { onRetry(session.profileId) },
                    )
                }
            }
            if (session.phase == SshTerminalPhase.Connected) {
                TerminalKeyBar(
                    controlEnabled = controlEnabled,
                    altEnabled = altEnabled,
                    onToggleControl = { controlEnabled = !controlEnabled },
                    onToggleAlt = { altEnabled = !altEnabled },
                    onSend = ::sendInput,
                )
            }
        }
    }

    if (closeRequested) {
        AlertDialog(
            onDismissRequest = { closeRequested = false },
            icon = { Icon(Icons.Default.Terminal, contentDescription = null) },
            title = { Text("关闭 SSH 终端?") },
            text = { Text("将断开 ${session.endpoint} 的命令行连接，Codex 会话不会受到影响。") },
            confirmButton = {
                TextButton(onClick = {
                    closeRequested = false
                    terminalWebView?.clearFocus()
                    focusManager.clearFocus(force = true)
                    keyboardController?.hide()
                    onClose()
                }) { Text("关闭并断开") }
            },
            dismissButton = {
                TextButton(onClick = { closeRequested = false }) { Text("取消") }
            },
        )
    }
}

@Composable
private fun TerminalTopBar(
    session: SshTerminalSessionState,
    onCopy: () -> Unit,
    onPaste: () -> Unit,
    onHide: () -> Unit,
    onClose: () -> Unit,
) {
    val actionTint = MaterialTheme.colorScheme.onSurfaceVariant
    Row(
        modifier = Modifier.fillMaxWidth().height(64.dp).background(Color(0xFF151515))
            .padding(start = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            Icons.Default.Terminal,
            contentDescription = null,
            tint = if (session.phase == SshTerminalPhase.Connected) CodexGreen else Color(0xFFAAAAAA),
            modifier = Modifier.size(21.dp),
        )
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(
                session.profileName.ifBlank { "SSH 终端" },
                color = Color.White,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.bodyMedium,
            )
            Text(
                session.endpoint,
                color = Color(0xFF9A9A9A),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
            )
        }
        if (session.phase == SshTerminalPhase.Connected) {
            IconButton(onClick = onCopy, modifier = Modifier.size(48.dp)) {
                Icon(
                    Icons.Default.ContentCopy,
                    contentDescription = "复制终端文字",
                    tint = actionTint,
                    modifier = Modifier.size(24.dp),
                )
            }
            IconButton(onClick = onPaste, modifier = Modifier.size(48.dp)) {
                Icon(
                    Icons.Default.ContentPaste,
                    contentDescription = "粘贴到终端",
                    tint = actionTint,
                    modifier = Modifier.size(24.dp),
                )
            }
        }
        IconButton(onClick = onHide, modifier = Modifier.size(48.dp)) {
            Icon(
                Icons.Default.KeyboardArrowDown,
                contentDescription = "隐藏 SSH 终端",
                tint = actionTint,
                modifier = Modifier.size(24.dp),
            )
        }
        IconButton(onClick = onClose, modifier = Modifier.size(48.dp)) {
            Icon(
                Icons.Default.Close,
                contentDescription = "关闭 SSH 终端",
                tint = actionTint,
                modifier = Modifier.size(24.dp),
            )
        }
    }
}

@Composable
private fun TerminalStatus(
    loading: Boolean,
    title: String,
    detail: String,
    onRetry: (() -> Unit)?,
) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        if (loading) {
            CircularProgressIndicator(modifier = Modifier.size(28.dp), strokeWidth = 2.dp, color = CodexGreen)
            Spacer(Modifier.height(16.dp))
        } else {
            Icon(Icons.Default.Terminal, contentDescription = null, tint = Color(0xFF888888), modifier = Modifier.size(32.dp))
            Spacer(Modifier.height(12.dp))
        }
        Text(title, color = Color.White, style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.height(6.dp))
        Text(
            detail,
            color = Color(0xFF9A9A9A),
            style = MaterialTheme.typography.bodySmall,
            maxLines = 4,
            overflow = TextOverflow.Ellipsis,
        )
        if (onRetry != null) {
            Spacer(Modifier.height(14.dp))
            TextButton(onClick = onRetry) {
                Icon(Icons.Default.Refresh, contentDescription = null, modifier = Modifier.size(17.dp))
                Spacer(Modifier.width(6.dp))
                Text("重新连接")
            }
        }
    }
}

@Composable
private fun TerminalKeyBar(
    controlEnabled: Boolean,
    altEnabled: Boolean,
    onToggleControl: () -> Unit,
    onToggleAlt: () -> Unit,
    onSend: (String) -> Unit,
) {
    Surface(color = Color(0xFF171717)) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 3.dp, vertical = 3.dp),
            verticalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            TerminalKeyRow(TERMINAL_KEY_ROW_ONE) { key -> onSend(key.sequence) }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                TerminalKey("CTRL", active = controlEnabled, modifier = Modifier.weight(1f), onClick = onToggleControl)
                TerminalKey("ALT", active = altEnabled, modifier = Modifier.weight(1f), onClick = onToggleAlt)
                TERMINAL_KEY_ROW_TWO.forEach { key ->
                    TerminalKey(key.label, modifier = Modifier.weight(1f)) { onSend(key.sequence) }
                }
            }
        }
    }
}

@Composable
private fun TerminalKeyRow(keys: List<TerminalKeySpec>, onClick: (TerminalKeySpec) -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        keys.forEach { key ->
            TerminalKey(key.label, modifier = Modifier.weight(1f)) { onClick(key) }
        }
    }
}

@Composable
private fun TerminalKey(
    label: String,
    modifier: Modifier = Modifier,
    active: Boolean = false,
    onClick: () -> Unit,
) {
    Box(
        modifier = modifier.height(34.dp).clip(RoundedCornerShape(4.dp))
            .background(if (active) Color(0xFF315D35) else Color(0xFF292929))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            color = if (active) Color.White else Color(0xFFD0D0D0),
            fontSize = 11.sp,
            letterSpacing = 0.sp,
            maxLines = 1,
        )
    }
}

@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun TerminalWebView(
    profileId: String,
    generation: Long,
    outputSignals: SharedFlow<SshTerminalOutputSignal>,
    onReadOutput: (String, Long, Long) -> SshTerminalOutputBatch,
    onInput: (String) -> Unit,
    onResize: (String, Int, Int) -> Unit,
    onCopy: (String) -> Unit,
    onWebViewChanged: (WebView?) -> Unit,
) {
    val context = LocalContext.current
    val currentOnInput by rememberUpdatedState(onInput)
    val currentOnResize by rememberUpdatedState(onResize)
    val currentOnCopy by rememberUpdatedState(onCopy)
    var webView by remember(profileId, generation) { mutableStateOf<WebView?>(null) }
    var readyNonce by remember(profileId, generation) { mutableIntStateOf(0) }
    var lastSequence by remember(profileId, generation) { mutableLongStateOf(-1L) }
    var renderEpoch by remember(profileId, generation) { mutableIntStateOf(0) }
    val writeAcknowledgements = remember(profileId, generation, renderEpoch) {
        TerminalWriteAcknowledgements()
    }
    val rendererGoneViews = remember(profileId, generation) {
        Collections.newSetFromMap(IdentityHashMap<WebView, Boolean>())
    }

    key(renderEpoch) {
        AndroidView(
            modifier = Modifier.fillMaxSize().background(Color.Black),
            factory = {
                lateinit var created: WebView
                val bridge = TerminalJavascriptBridge(
                    dispatch = { action -> created.post(action) },
                    inputCallback = { value -> currentOnInput(value) },
                    resizeCallback = { columns, rows -> currentOnResize(profileId, columns, rows) },
                    copyCallback = { value -> currentOnCopy(value) },
                    readyCallback = { readyNonce += 1 },
                    writeCompleteCallback = writeAcknowledgements::acknowledge,
                )
                created = WebView(context).apply {
                    setBackgroundColor(AndroidColor.BLACK)
                    overScrollMode = View.OVER_SCROLL_NEVER
                    isVerticalScrollBarEnabled = false
                    isHorizontalScrollBarEnabled = false
                    isFocusable = true
                    isFocusableInTouchMode = true
                    layoutParams = ViewGroup.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT,
                    )
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = false
                    settings.allowContentAccess = false
                    settings.allowFileAccess = true
                    settings.blockNetworkLoads = true
                    webViewClient = object : WebViewClient() {
                        override fun shouldOverrideUrlLoading(
                            view: WebView?,
                            request: WebResourceRequest?,
                        ): Boolean = request?.url?.toString()?.startsWith(TERMINAL_ASSET_ROOT) != true

                        override fun onRenderProcessGone(
                            view: WebView,
                            detail: RenderProcessGoneDetail,
                        ): Boolean {
                            rendererGoneViews.add(view)
                            writeAcknowledgements.failPending()
                            DiagnosticLogger.warn(
                                "Terminal",
                                "webview_renderer_gone crashed=${detail.didCrash()}",
                            )
                            if (webView === view) {
                                onWebViewChanged(null)
                                webView = null
                                readyNonce = 0
                                renderEpoch += 1
                            }
                            return true
                        }
                    }
                    addJavascriptInterface(bridge, TERMINAL_BRIDGE_NAME)
                    loadUrl(TERMINAL_PAGE_URL)
                }
                webView = created
                onWebViewChanged(created)
                created
            },
            update = { view ->
                if (webView !== view) {
                    webView = view
                    onWebViewChanged(view)
                }
            },
            onRelease = { view ->
                if (webView === view) {
                    onWebViewChanged(null)
                    webView = null
                }
                if (rendererGoneViews.remove(view)) {
                    // A renderer-gone WebView must not be used again; destroy is the only valid call.
                    view.destroy()
                } else {
                    view.removeJavascriptInterface(TERMINAL_BRIDGE_NAME)
                    view.stopLoading()
                    view.loadUrl("about:blank")
                    view.destroy()
                }
            },
        )
    }

    LaunchedEffect(profileId, generation, readyNonce, webView) {
        val target = webView ?: return@LaunchedEffect
        if (readyNonce <= 0) return@LaunchedEffect
        lastSequence = -1L

        suspend fun flushOutput(): Boolean {
            val batch = onReadOutput(profileId, generation, lastSequence)
            if (batch.generation != generation) return true
            if (batch.resetRequired) {
                target.evaluateJavascript("window.resetTerminal()", null)
                if (batch.historyTruncated) {
                    if (!writeTerminalBytes(
                            webView = target,
                            bytes = OUTPUT_TRUNCATED_NOTICE.toByteArray(Charsets.UTF_8),
                            acknowledgements = writeAcknowledgements,
                            profileId = profileId,
                            generation = generation,
                        )
                    ) {
                        return false
                    }
                }
            }
            mergeTerminalChunks(batch.chunks).forEach { bytes ->
                if (!writeTerminalBytes(
                        webView = target,
                        bytes = bytes,
                        acknowledgements = writeAcknowledgements,
                        profileId = profileId,
                        generation = generation,
                    )
                ) {
                    return false
                }
            }
            lastSequence = batch.latestSequence
            return true
        }

        fun restartRenderer() {
            if (webView !== target) return
            onWebViewChanged(null)
            webView = null
            readyNonce = 0
            renderEpoch += 1
        }

        val wakeups = Channel<Unit>(Channel.CONFLATED)
        val signalCollector = launch(start = CoroutineStart.UNDISPATCHED) {
            outputSignals.filter { signal ->
                signal.profileId == profileId && signal.generation == generation
            }.collect {
                wakeups.trySend(Unit)
            }
        }
        try {
            if (!flushOutput()) {
                restartRenderer()
                return@LaunchedEffect
            }
            target.evaluateJavascript("window.focusTerminal()", null)
            while (true) {
                wakeups.receive()
                if (!flushOutput()) {
                    restartRenderer()
                    return@LaunchedEffect
                }
            }
        } finally {
            signalCollector.cancel()
            wakeups.close()
        }
    }
}

private class TerminalJavascriptBridge(
    private val dispatch: (() -> Unit) -> Unit,
    private val inputCallback: (String) -> Unit,
    private val resizeCallback: (Int, Int) -> Unit,
    private val copyCallback: (String) -> Unit,
    private val readyCallback: () -> Unit,
    private val writeCompleteCallback: (String, Boolean) -> Unit,
) {
    @JavascriptInterface
    fun sendData(value: String) = dispatch { inputCallback(value) }

    @JavascriptInterface
    fun onResize(columns: Int, rows: Int) = dispatch { resizeCallback(columns, rows) }

    @JavascriptInterface
    fun onCopy(value: String) = dispatch { copyCallback(value) }

    @JavascriptInterface
    fun onReady() = dispatch(readyCallback)

    @JavascriptInterface
    fun onWriteComplete(token: String, succeeded: Boolean) = dispatch {
        writeCompleteCallback(token, succeeded)
    }
}

private class TerminalWriteAcknowledgements {
    private val lock = Any()
    private var nextToken = 0L
    private var pending: PendingTerminalWrite? = null

    fun begin(): PendingTerminalWrite = synchronized(lock) {
        check(pending == null) { "A terminal write is already in flight" }
        nextToken += 1
        PendingTerminalWrite(
            token = nextToken.toString(),
            completion = CompletableDeferred(),
        ).also { pending = it }
    }

    fun acknowledge(token: String, succeeded: Boolean) {
        val completion = synchronized(lock) {
            pending?.takeIf { it.token == token }?.completion
        }
        completion?.complete(succeeded)
    }

    fun failPending() {
        val completion = synchronized(lock) { pending?.completion }
        completion?.complete(false)
    }

    fun finish(value: PendingTerminalWrite) {
        synchronized(lock) {
            if (pending === value) pending = null
        }
    }
}

private data class PendingTerminalWrite(
    val token: String,
    val completion: CompletableDeferred<Boolean>,
)

internal fun encodeTerminalInput(value: String, control: Boolean, alt: Boolean): ByteArray {
    val payload = if (control && value.length == 1) {
        val character = value[0].uppercaseChar()
        if (character in '@'..'_') {
            byteArrayOf((character.code and 0x1f).toByte())
        } else {
            value.toByteArray(Charsets.UTF_8)
        }
    } else {
        value.toByteArray(Charsets.UTF_8)
    }
    return if (alt) byteArrayOf(0x1b) + payload else payload
}

internal data class LimitedTerminalInput(
    val value: String,
    val bytes: ByteArray,
    val truncated: Boolean,
)

internal fun limitTerminalUtf8(value: String, maxBytes: Int): LimitedTerminalInput {
    val safeLimit = maxBytes.coerceAtLeast(0)
    val complete = value.toByteArray(Charsets.UTF_8)
    if (complete.size <= safeLimit) return LimitedTerminalInput(value, complete, truncated = false)
    if (safeLimit == 0) return LimitedTerminalInput("", byteArrayOf(), truncated = value.isNotEmpty())

    var index = 0
    var usedBytes = 0
    while (index < value.length) {
        val codePoint = Character.codePointAt(value, index)
        val characterBytes = when {
            codePoint <= 0x7f -> 1
            codePoint <= 0x7ff -> 2
            codePoint in 0xd800..0xdfff -> 1
            codePoint <= 0xffff -> 3
            else -> 4
        }
        if (usedBytes + characterBytes > safeLimit) break
        usedBytes += characterBytes
        index += Character.charCount(codePoint)
    }
    val limitedValue = value.substring(0, index)
    return LimitedTerminalInput(
        value = limitedValue,
        bytes = limitedValue.toByteArray(Charsets.UTF_8),
        truncated = index < value.length,
    )
}

private fun mergeTerminalChunks(chunks: List<SshTerminalOutputChunk>): List<ByteArray> {
    if (chunks.isEmpty()) return emptyList()
    val result = ArrayList<ByteArray>()
    var pending = ByteArrayOutputStream(MAX_JAVASCRIPT_CHUNK_BYTES)
    chunks.forEach { chunk ->
        var offset = 0
        while (offset < chunk.bytes.size) {
            if (pending.size() == MAX_JAVASCRIPT_CHUNK_BYTES) {
                result += pending.toByteArray()
                pending = ByteArrayOutputStream(MAX_JAVASCRIPT_CHUNK_BYTES)
            }
            val count = minOf(
                chunk.bytes.size - offset,
                MAX_JAVASCRIPT_CHUNK_BYTES - pending.size(),
            )
            pending.write(chunk.bytes, offset, count)
            offset += count
        }
    }
    if (pending.size() > 0) result += pending.toByteArray()
    return result
}

private suspend fun writeTerminalBytes(
    webView: WebView,
    bytes: ByteArray,
    acknowledgements: TerminalWriteAcknowledgements,
    profileId: String,
    generation: Long,
): Boolean {
    val pending = acknowledgements.begin()
    val encoded = Base64.encodeToString(bytes, Base64.NO_WRAP)
    val acknowledged = try {
        webView.evaluateJavascript("window.writeBase64('$encoded', '${pending.token}')", null)
        withTimeoutOrNull(TERMINAL_WRITE_ACK_TIMEOUT_MS) {
            pending.completion.await()
        }
    } catch (error: CancellationException) {
        throw error
    } catch (error: Throwable) {
        DiagnosticLogger.warn(
            "Terminal",
            "write_bridge_failed profile=${profileId.take(8)} generation=$generation " +
                "bytes=${bytes.size} error=${error.message.orEmpty()}",
        )
        false
    } finally {
        acknowledgements.finish(pending)
    }
    return when (acknowledged) {
        true -> true
        false -> {
            DiagnosticLogger.warn(
                "Terminal",
                "write_ack_failed profile=${profileId.take(8)} generation=$generation bytes=${bytes.size}",
            )
            false
        }

        null -> {
            DiagnosticLogger.warn(
                "Terminal",
                "write_ack_timeout profile=${profileId.take(8)} generation=$generation bytes=${bytes.size}",
            )
            false
        }
    }
}

private fun copyToClipboard(context: Context, value: String) {
    if (value.isBlank()) return
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    clipboard.setPrimaryClip(ClipData.newPlainText("SSH terminal", value))
}

private fun clipboardText(context: Context): String? {
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    val clip = clipboard.primaryClip ?: return null
    if (clip.itemCount == 0) return null
    return clip.getItemAt(0).coerceToText(context)?.toString()
}

private data class TerminalKeySpec(val label: String, val sequence: String)

private val TERMINAL_KEY_ROW_ONE = listOf(
    TerminalKeySpec("ESC", "\u001b"),
    TerminalKeySpec("TAB", "\t"),
    TerminalKeySpec("↑", "\u001b[A"),
    TerminalKeySpec("↓", "\u001b[B"),
    TerminalKeySpec("←", "\u001b[D"),
    TerminalKeySpec("→", "\u001b[C"),
    TerminalKeySpec("HOME", "\u001b[1~"),
    TerminalKeySpec("END", "\u001b[4~"),
)

private val TERMINAL_KEY_ROW_TWO = listOf(
    TerminalKeySpec("/", "/"),
    TerminalKeySpec("|", "|"),
    TerminalKeySpec("-", "-"),
    TerminalKeySpec("~", "~"),
    TerminalKeySpec(":", ":"),
    TerminalKeySpec("_", "_"),
)

private const val TERMINAL_BRIDGE_NAME = "Android"
private const val TERMINAL_ASSET_ROOT = "file:///android_asset/terminal/"
private const val TERMINAL_PAGE_URL = "${TERMINAL_ASSET_ROOT}terminal.html"
internal const val MAX_TERMINAL_INPUT_BYTES = 512 * 1024
private const val MAX_JAVASCRIPT_CHUNK_BYTES = 64 * 1024
private const val TERMINAL_WRITE_ACK_TIMEOUT_MS = 10_000L
private const val OUTPUT_TRUNCATED_NOTICE = "\r\n[较早的终端输出已省略]\r\n"
