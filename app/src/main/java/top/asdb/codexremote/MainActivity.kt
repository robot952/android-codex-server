package top.asdb.codexremote

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import top.asdb.codexremote.data.ConnectionPhase
import top.asdb.codexremote.diagnostics.DiagnosticLogger
import top.asdb.codexremote.ssh.SshTerminalPhase
import top.asdb.codexremote.ui.CodexRemoteApp
import top.asdb.codexremote.ui.theme.CodexRemoteTheme

class MainActivity : ComponentActivity() {
    private val viewModel by viewModels<AppViewModel>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        DiagnosticLogger.info("Activity", "created restored=${savedInstanceState != null}")
        observeConnectionProtection()
        observeDiagnosticState()
        enableEdgeToEdge()
        setContent {
            CodexRemoteTheme {
                CodexRemoteApp(viewModel)
            }
        }
    }

    override fun onDestroy() {
        DiagnosticLogger.info("Activity", "destroyed finishing=$isFinishing changing_config=$isChangingConfigurations")
        if (isFinishing && !isChangingConfigurations) {
            ConnectionForegroundService.stop(this)
        }
        super.onDestroy()
    }

    override fun onStart() {
        super.onStart()
        DiagnosticLogger.info("Activity", "started")
    }

    override fun onResume() {
        super.onResume()
        DiagnosticLogger.info("Activity", "resumed")
    }

    override fun onPause() {
        DiagnosticLogger.info("Activity", "paused")
        super.onPause()
    }

    override fun onStop() {
        DiagnosticLogger.info("Activity", "stopped")
        super.onStop()
    }

    private fun observeConnectionProtection() {
        lifecycleScope.launch {
            combine(viewModel.state, viewModel.terminalState) { state, terminal ->
                state.connectionStates.values.any { it.phase.keepsBackgroundConnection() } ||
                    state.connection.phase.keepsBackgroundConnection() ||
                    terminal.sessions.values.any {
                        it.phase in setOf(SshTerminalPhase.Connecting, SshTerminalPhase.Connected)
                    }
                }
                .distinctUntilChanged()
                .collect { required ->
                    if (required) {
                        ConnectionForegroundService.start(this@MainActivity)
                        requestNotificationPermission()
                    } else {
                        ConnectionForegroundService.stop(this@MainActivity)
                    }
                }
        }
    }

    private fun observeDiagnosticState() {
        lifecycleScope.launch {
            viewModel.state
                .map { state ->
                    DiagnosticUiState(
                        screen = state.screen.name,
                        profile = state.selectedProfileId?.take(8).orEmpty(),
                        connection = state.connection.phase.name,
                        connectedProfiles = state.connectionStates.values.count {
                            it.phase == ConnectionPhase.Connected
                        },
                        thread = state.activeThread?.id?.take(8).orEmpty(),
                        loading = state.loading,
                        submitting = state.submitting,
                        running = state.running,
                    )
                }
                .distinctUntilChanged()
                .collect { state ->
                    DiagnosticLogger.info(
                        "UI",
                        "screen=${state.screen} profile=${state.profile.ifBlank { "none" }} " +
                            "connection=${state.connection} connected=${state.connectedProfiles} " +
                            "thread=${state.thread.ifBlank { "none" }} loading=${state.loading} " +
                            "submitting=${state.submitting} running=${state.running}",
                    )
                }
        }
    }

    private fun requestNotificationPermission() {
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_PERMISSION_REQUEST,
            )
        }
    }

    private companion object {
        const val NOTIFICATION_PERMISSION_REQUEST = 1001
    }
}

private data class DiagnosticUiState(
    val screen: String,
    val profile: String,
    val connection: String,
    val connectedProfiles: Int,
    val thread: String,
    val loading: Boolean,
    val submitting: Boolean,
    val running: Boolean,
)

private fun ConnectionPhase.keepsBackgroundConnection(): Boolean = when (this) {
    ConnectionPhase.Connecting,
    ConnectionPhase.Installing,
    ConnectionPhase.Connected,
    -> true

    ConnectionPhase.Probing,
    ConnectionPhase.Disconnected,
    ConnectionPhase.Failed,
    -> false
}
