package energy.ftw

/** The one origin, QR host and WebAuthn RP ID. They must stay the same string. */
const val APP_HOST = "app.ftw.energy"
const val APP_ORIGIN = "https://$APP_HOST"
const val RP_ID = APP_HOST
const val RP_NAME = "FTW"

const val RELAY_HOST = "relay.ftw.energy"
const val RELAY_URL = "wss://$RELAY_HOST"

const val ENROLLMENT_PATH = "/p"

fun isDevHost(hostname: String): Boolean =
    hostname == "localhost" || hostname == "127.0.0.1" || hostname.endsWith(".localhost")
