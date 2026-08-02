package top.asdb.codexremote

import android.app.Application
import top.asdb.codexremote.diagnostics.DiagnosticLogger
import top.asdb.codexremote.update.AppUpdateManager

class CodexRemoteApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        DiagnosticLogger.initialize(this)
        AppUpdateManager.initialize(this)
    }
}
