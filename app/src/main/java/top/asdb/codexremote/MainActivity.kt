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
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import top.asdb.codexremote.data.ConnectionPhase
import top.asdb.codexremote.ui.CodexRemoteApp
import top.asdb.codexremote.ui.theme.CodexRemoteTheme

class MainActivity : ComponentActivity() {
    private val viewModel by viewModels<AppViewModel>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        observeConnectionProtection()
        enableEdgeToEdge()
        setContent {
            CodexRemoteTheme {
                CodexRemoteApp(viewModel)
            }
        }
    }

    override fun onDestroy() {
        if (isFinishing && !isChangingConfigurations) {
            ConnectionForegroundService.stop(this)
        }
        super.onDestroy()
    }

    private fun observeConnectionProtection() {
        lifecycleScope.launch {
            viewModel.state
                .map { state ->
                    state.connectionStates.values.any { it.phase.keepsBackgroundConnection() } ||
                        state.connection.phase.keepsBackgroundConnection()
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
