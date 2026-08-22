package energy.ftw.carrier

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.util.concurrent.TimeUnit

class AndroidSockets : SocketFactory {
    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.SECONDS)
        .build()

    override fun open(url: String, listener: SocketListener): RawSocket {
        val req = Request.Builder().url(url).build()
        val ws = client.newWebSocket(
            req,
            object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    listener.onOpen()
                }

                override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                    listener.onBinary(bytes.toByteArray())
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    listener.onText(text)
                }

                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                    listener.onClose(code, reason)
                    webSocket.close(code, reason)
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    listener.onClose(1006, t.message ?: "error")
                }
            },
        )
        return object : RawSocket {
            override fun sendBinary(bytes: ByteArray) {
                ws.send(bytes.toByteString())
            }

            override fun close() {
                ws.close(1000, "bye")
            }
        }
    }
}
