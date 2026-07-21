package top.asdb.codexremote

import android.app.Application
import top.asdb.codexremote.diagnostics.DiagnosticLogger

class CodexRemoteApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        DiagnosticLogger.initialize(this)
    }
}
