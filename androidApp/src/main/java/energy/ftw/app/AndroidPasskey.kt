package energy.ftw.app

import android.app.Activity
import android.util.Base64
import androidx.credentials.CreatePublicKeyCredentialRequest
import androidx.credentials.CreatePublicKeyCredentialResponse
import androidx.credentials.CredentialManager
import androidx.credentials.GetCredentialRequest
import androidx.credentials.GetPublicKeyCredentialOption
import androidx.credentials.PublicKeyCredential
import energy.ftw.identity.LOCAL_CREDENTIAL_ID
import energy.ftw.identity.PRF_SALT_VAULT
import energy.ftw.identity.PasskeyHost
import energy.ftw.identity.WrappingKey
import energy.ftw.identity.WrappingSource
import org.json.JSONArray
import org.json.JSONObject
import java.security.SecureRandom

/**
 * Credential Manager passkey. RP ID app.ftw.energy, PRF salt ftw.prf.v1.vault.
 */
class AndroidPasskey(private val activity: Activity) : PasskeyHost {
    private val manager = CredentialManager.create(activity)

    override fun enroll(label: String): WrappingKey = runBlockingHost {
        enrollAsync(label)
    }

    override fun unlock(label: String): WrappingKey = runBlockingHost {
        unlockAsync(label)
    }

    suspend fun enrollAsync(label: String = "FTW"): WrappingKey {
        val challenge = randomB64(32)
        val userId = randomB64(16)
        val salt = Base64.encodeToString(PRF_SALT_VAULT.encodeToByteArray(), Base64.NO_WRAP or Base64.NO_PADDING or Base64.URL_SAFE)
        val json = JSONObject()
            .put("challenge", challenge)
            .put("rp", JSONObject().put("id", rpId).put("name", rpName))
            .put(
                "user",
                JSONObject().put("id", userId).put("name", label).put("displayName", label),
            )
            .put(
                "pubKeyCredParams",
                JSONArray().put(JSONObject().put("type", "public-key").put("alg", -7)),
            )
            .put(
                "authenticatorSelection",
                JSONObject().put("residentKey", "required").put("userVerification", "required"),
            )
            .put("attestation", "none")
            .put(
                "extensions",
                JSONObject().put("prf", JSONObject().put("eval", JSONObject().put("first", salt))),
            )
        val req = CreatePublicKeyCredentialRequest(requestJson = json.toString())
        val res = manager.createCredential(activity, req) as CreatePublicKeyCredentialResponse
        return wrappingFromJson(res.registrationResponseJson)
    }

    suspend fun unlockAsync(label: String = "FTW"): WrappingKey {
        val challenge = randomB64(32)
        val salt = Base64.encodeToString(PRF_SALT_VAULT.encodeToByteArray(), Base64.NO_WRAP or Base64.NO_PADDING or Base64.URL_SAFE)
        val json = JSONObject()
            .put("challenge", challenge)
            .put("rpId", rpId)
            .put("userVerification", "required")
            .put(
                "extensions",
                JSONObject().put("prf", JSONObject().put("eval", JSONObject().put("first", salt))),
            )
        val opt = GetPublicKeyCredentialOption(requestJson = json.toString())
        val res = manager.getCredential(activity, GetCredentialRequest(listOf(opt)))
        val cred = res.credential as PublicKeyCredential
        return wrappingFromJson(cred.authenticationResponseJson)
    }

    private fun wrappingFromJson(raw: String): WrappingKey {
        val obj = JSONObject(raw)
        val id = obj.optString("id", LOCAL_CREDENTIAL_ID)
        val prf = obj.optJSONObject("clientExtensionResults")
            ?.optJSONObject("prf")
            ?.optJSONObject("results")
            ?.optString("first")
        val key = if (prf.isNullOrBlank()) {
            ByteArray(32).also { SecureRandom().nextBytes(it) }
        } else {
            Base64.decode(prf, Base64.NO_WRAP or Base64.NO_PADDING or Base64.URL_SAFE)
        }
        val source = if (prf.isNullOrBlank()) WrappingSource.Local else WrappingSource.Prf
        return WrappingKey(id, source, key)
    }

    private fun randomB64(n: Int): String {
        val bytes = ByteArray(n)
        SecureRandom().nextBytes(bytes)
        return Base64.encodeToString(bytes, Base64.NO_WRAP or Base64.NO_PADDING or Base64.URL_SAFE)
    }
}

private fun <T> runBlockingHost(block: suspend () -> T): T =
    kotlinx.coroutines.runBlocking { block() }
