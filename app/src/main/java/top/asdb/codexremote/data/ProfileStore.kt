package top.asdb.codexremote.data

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class ProfileStore(context: Context) {
    private val json = Json { ignoreUnknownKeys = true }
    private val masterKey = MasterKey.Builder(context)
        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
        .build()
    private val preferences = EncryptedSharedPreferences.create(
        context,
        "codex_remote_profiles",
        masterKey,
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    fun load(): StoredProfiles {
        val raw = preferences.getString(KEY_PROFILES, null) ?: return StoredProfiles()
        return runCatching { json.decodeFromString<StoredProfiles>(raw) }.getOrDefault(StoredProfiles())
    }

    fun save(value: StoredProfiles) {
        preferences.edit().putString(KEY_PROFILES, json.encodeToString(value)).apply()
    }

    companion object {
        private const val KEY_PROFILES = "profiles_v1"
    }
}
