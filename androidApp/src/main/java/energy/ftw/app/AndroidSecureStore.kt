@file:Suppress("DEPRECATION")

package energy.ftw.app

import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import energy.ftw.identity.KeyValueStore

/**
 * Keystore-backed get/put. Not PRF-wrapped, so cold start can paint
 * before a biometric prompt.
 */
class AndroidSecureStore(context: Context) : KeyValueStore {
    private val prefs: SharedPreferences

    init {
        val app = context.applicationContext
        val masterKey = MasterKey.Builder(app)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        prefs = EncryptedSharedPreferences.create(
            app,
            PREFS_NAME,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    override fun get(key: String): ByteArray? = synchronized(this) {
        val encoded = prefs.getString(key, null) ?: return null
        Base64.decode(encoded, Base64.NO_WRAP)
    }

    override fun put(key: String, value: ByteArray) {
        synchronized(this) {
            prefs.edit().putString(key, Base64.encodeToString(value, Base64.NO_WRAP)).commit()
        }
    }

    override fun remove(key: String) {
        synchronized(this) {
            prefs.edit().remove(key).commit()
        }
    }

    companion object {
        private const val PREFS_NAME = "ftw-secure"
    }
}
