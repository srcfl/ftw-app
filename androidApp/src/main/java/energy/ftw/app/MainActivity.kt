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
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import energy.ftw.RELAY_URL
import energy.ftw.carrier.AndroidSockets
import energy.ftw.client.ConnectError
import energy.ftw.client.FtwClient
import energy.ftw.format.nowNumbers
import energy.ftw.identity.EnrollmentError
import energy.ftw.identity.PairedSite
import energy.ftw.identity.Vault
import energy.ftw.protocol.LiveReadings
import energy.ftw.protocol.Session
import energy.ftw.protocol.headlineOf
import energy.ftw.store.ReadingsCache
import energy.ftw.store.SiteStore
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private lateinit var vault: Vault
    private lateinit var sites: SiteStore
    private lateinit var readings: ReadingsCache
    private lateinit var client: FtwClient

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val store = AndroidSecureStore(applicationContext)
        vault = Vault(store)
        sites = SiteStore(store)
        readings = ReadingsCache(store)
        val passkey = AndroidPasskey(this)
        client = FtwClient(
            vault = vault,
            sites = sites,
            sockets = AndroidSockets(),
            passkeys = passkey,
            relayUrl = RELAY_URL,
            build = "android",
        )
        val initialSite = sites.all().firstOrNull()
        val cached = readings.get()
        setContent {
            FtwRoot(
                client = client,
                passkey = passkey,
                vault = vault,
                sites = sites,
                readings = readings,
                initialSite = initialSite,
                cached = cached,
            )
        }
    }
}

private val Surface = Color(0xFF0D0D0D)
private val Fg = Color(0xFFE8E8E8)
private val Dim = Color(0xFFA0A0A0)

@Composable
private fun FtwRoot(
    client: FtwClient,
    passkey: AndroidPasskey,
    vault: Vault,
    sites: SiteStore,
    readings: ReadingsCache,
    initialSite: PairedSite?,
    cached: LiveReadings?,
) {
    val cachedNumbers = cached?.let { nowNumbers(it.fields) }
    var site by remember { mutableStateOf(initialSite) }
    var session by remember { mutableStateOf<Session?>(null) }
    var paste by remember { mutableStateOf("") }
    var help by remember { mutableStateOf<String?>(null) }
    var headline by remember {
        mutableStateOf(cached?.let { headlineOf(it) } ?: "Waiting for the first reading.")
    }
    var carrier by remember { mutableStateOf(if (cached != null) "cache" else "none") }
    var srcState by remember { mutableStateOf("never") }
    var grid by remember { mutableStateOf(cachedNumbers?.grid ?: "—") }
    var pv by remember { mutableStateOf(cachedNumbers?.pv ?: "—") }
    var battery by remember { mutableStateOf(cachedNumbers?.battery ?: "—") }
    var load by remember { mutableStateOf(cachedNumbers?.load ?: "—") }
    var scanning by remember { mutableStateOf(initialSite == null) }
    val scope = rememberCoroutineScope()
    val epoch = remember { intArrayOf(0) }

    val main = Handler(Looper.getMainLooper())
    fun bind(s: Session) {
        session?.close()
        val mine = ++epoch[0]
        session = s
        readings.get()?.let { s.restore(it) }
        s.subscribe { snap ->
            val n = nowNumbers(snap.readings.fields)
            val hasFields = snap.readings.fields.isNotEmpty()
            main.post {
                if (mine != epoch[0]) return@post
                headline = snap.headline
                carrier = snap.carrier.name.lowercase()
                srcState = snap.srcState.name.lowercase()
                if (hasFields) {
                    grid = n.grid
                    pv = n.pv
                    battery = n.battery
                    load = n.load
                    readings.put(snap.readings)
                }
            }
        }
    }

    fun go(raw: String) {
        help = null
        scope.launch {
            try {
                val wrapping = passkey.enrollAsync()
                site = client.pair(raw, wrapping)
            } catch (e: EnrollmentError) {
                help = e.help
            } catch (e: Exception) {
                help = e.message ?: "Could not pair."
            }
        }
    }

    fun forget() {
        epoch[0]++
        session?.close()
        session = null
        vault.clear()
        sites.clear()
        readings.clear()
        site = null
        headline = "Waiting for the first reading."
        carrier = "none"
        srcState = "never"
        grid = "—"
        pv = "—"
        battery = "—"
        load = "—"
        help = null
        paste = ""
        scanning = true
    }

    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(session, lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) session?.wake()
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    LaunchedEffect(site) {
        val current = site ?: return@LaunchedEffect
        try {
            bind(client.connect(current))
        } catch (e: ConnectError) {
            help = e.help
        } catch (e: Exception) {
            help = e.message ?: "Could not reach your box."
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
            Text("via $carrier · $srcState", color = Dim, fontSize = 12.sp)
            Text(headline, color = Fg, fontSize = 18.sp)
            reading("Grid", grid)
            reading("Solar", pv)
            reading("Battery", battery)
            reading("House", load)
            help?.let { Text(it, color = Color(0xFFC44)) }
            Button(onClick = { forget() }) { Text("Forget this home") }
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
