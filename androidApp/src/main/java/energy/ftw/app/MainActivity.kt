package energy.ftw.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import energy.ftw.RELAY_URL
import energy.ftw.carrier.AndroidSockets
import energy.ftw.client.ConnectError
import energy.ftw.client.FtwClient
import energy.ftw.format.nowNumbers
import energy.ftw.identity.EnrollmentError
import energy.ftw.identity.MemoryStore
import energy.ftw.identity.PairedSite
import energy.ftw.identity.Vault
import energy.ftw.protocol.Session
import energy.ftw.store.SiteStore
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val passkey = AndroidPasskey(this)
        val client = FtwClient(
            vault = Vault(MemoryStore()),
            sites = SiteStore(MemoryStore()),
            sockets = AndroidSockets(),
            passkeys = passkey,
            relayUrl = RELAY_URL,
            build = "android",
        )
        setContent { FtwRoot(client, passkey) }
    }
}

private val Surface = Color(0xFF0D0D0D)
private val Fg = Color(0xFFE8E8E8)
private val Dim = Color(0xFFA0A0A0)

@Composable
private fun FtwRoot(client: FtwClient, passkey: AndroidPasskey) {
    var site by remember { mutableStateOf<PairedSite?>(null) }
    var session by remember { mutableStateOf<Session?>(null) }
    var paste by remember { mutableStateOf("") }
    var help by remember { mutableStateOf<String?>(null) }
    var headline by remember { mutableStateOf("Waiting for the first reading.") }
    var carrier by remember { mutableStateOf("none") }
    var grid by remember { mutableStateOf("—") }
    var pv by remember { mutableStateOf("—") }
    var battery by remember { mutableStateOf("—") }
    var load by remember { mutableStateOf("—") }
    var scanning by remember { mutableStateOf(true) }
    val scope = rememberCoroutineScope()

    fun bind(s: Session) {
        session = s
        s.subscribe { snap ->
            headline = snap.headline
            carrier = snap.carrier.name.lowercase()
            val n = nowNumbers(snap.readings.fields)
            grid = n.grid
            pv = n.pv
            battery = n.battery
            load = n.load
        }
    }

    fun go(raw: String) {
        help = null
        scope.launch {
            try {
                val wrapping = passkey.enrollAsync()
                val paired = client.pair(raw, wrapping)
                site = paired
                bind(client.connect(paired))
            } catch (e: EnrollmentError) {
                help = e.help
            } catch (e: ConnectError) {
                help = e.help
            } catch (e: Exception) {
                help = e.message ?: "Could not pair."
            }
        }
    }

    Column(
        modifier = Modifier.fillMaxSize().background(Surface).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        val current = site
        if (current == null) {
            Spacer(Modifier.height(24.dp))
            Text("FTW", color = Fg, fontSize = 32.sp)
            Text("Scan the pairing code on your box.", color = Dim)
            if (scanning) {
                QrScanner { code ->
                    scanning = false
                    paste = code
                    go(code)
                }
            }
            OutlinedTextField(
                value = paste,
                onValueChange = { paste = it },
                label = { Text("Or paste a pairing link") },
            )
            Button(onClick = { go(paste) }) { Text("Continue") }
            help?.let { Text(it, color = Color(0xFFC44)) }
        } else {
            Text(current.label, color = Fg, fontSize = 22.sp)
            Text("via $carrier", color = Dim, fontSize = 12.sp)
            Text(headline, color = Fg, fontSize = 18.sp)
            reading("Grid", grid)
            reading("Solar", pv)
            reading("Battery", battery)
            reading("House", load)
            Button(onClick = {
                session?.close()
                session = null
                site = null
                scanning = true
            }) { Text("Forget this home") }
        }
    }
}

@Composable
private fun reading(name: String, value: String) {
    Row {
        Text(name, color = Dim, modifier = Modifier.padding(end = 12.dp))
        Text(value, color = Fg)
    }
}
