package top.asdb.agent

import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LEGACY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "readLegacyProfiles" -> runCatching { readLegacyProfiles() }
                        .onSuccess(result::success)
                        .onFailure {
                            result.error("legacy_profile_read_failed", "无法读取旧版服务器配置", null)
                        }

                    "clearLegacyProfiles" -> runCatching { clearLegacyProfiles() }
                        .onSuccess { result.success(null) }
                        .onFailure {
                            result.error("legacy_profile_clear_failed", "无法清理旧版服务器配置", null)
                        }

                    else -> result.notImplemented()
                }
            }
    }

    private fun readLegacyProfiles(): String? = legacyPreferences().getString(LEGACY_KEY, null)

    private fun clearLegacyProfiles() {
        check(legacyPreferences().edit().remove(LEGACY_KEY).commit()) {
            "Legacy profile removal was not committed"
        }
    }

    private fun legacyPreferences() = run {
        val masterKey = MasterKey.Builder(this)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            this,
            LEGACY_PREFERENCES,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    private companion object {
        const val LEGACY_CHANNEL = "top.asdb.agent/legacy"
        const val LEGACY_PREFERENCES = "codex_remote_profiles"
        const val LEGACY_KEY = "profiles_v1"
    }
}
