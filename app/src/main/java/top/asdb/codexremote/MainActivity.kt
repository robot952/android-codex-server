package top.asdb.codexremote

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import top.asdb.codexremote.ui.CodexRemoteApp
import top.asdb.codexremote.ui.theme.CodexRemoteTheme

class MainActivity : ComponentActivity() {
    private val viewModel by viewModels<AppViewModel>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            CodexRemoteTheme {
                CodexRemoteApp(viewModel)
            }
        }
    }
}
