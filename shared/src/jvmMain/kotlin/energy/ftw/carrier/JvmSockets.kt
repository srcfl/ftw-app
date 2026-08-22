package energy.ftw.carrier

import java.net.URI
import java.net.http.HttpClient
import java.net.http.WebSocket
import java.nio.ByteBuffer
import java.time.Duration
import java.util.concurrent.CompletionStage
import java.util.concurrent.CompletableFuture

class JvmSockets : SocketFactory {
    private val client: HttpClient = HttpClient.newBuilder()
        .connectTimeout(Duration.ofSeconds(15))
        .build()

    override fun open(url: String, listener: SocketListener): RawSocket {
        val ws = client.newWebSocketBuilder()
            .buildAsync(
                URI.create(url),
                object : WebSocket.Listener {
                    private val binary = java.io.ByteArrayOutputStream()
                    private val text = StringBuilder()

                    override fun onOpen(webSocket: WebSocket) {
                        listener.onOpen()
                        webSocket.request(1)
                    }

                    override fun onBinary(webSocket: WebSocket, data: ByteBuffer, last: Boolean): CompletionStage<*>? {
                        val bytes = ByteArray(data.remaining())
                        data.get(bytes)
                        binary.write(bytes)
                        if (last) {
                            listener.onBinary(binary.toByteArray())
                            binary.reset()
                        }
                        webSocket.request(1)
                        return null
                    }

                    override fun onText(webSocket: WebSocket, data: CharSequence, last: Boolean): CompletionStage<*>? {
                        text.append(data)
                        if (last) {
                            listener.onText(text.toString())
                            text.setLength(0)
                        }
                        webSocket.request(1)
                        return null
                    }

                    override fun onClose(webSocket: WebSocket, statusCode: Int, reason: String): CompletionStage<*>? {
                        listener.onClose(statusCode, reason)
                        return CompletableFuture.completedFuture(null)
                    }

                    override fun onError(webSocket: WebSocket, error: Throwable) {
                        listener.onClose(1006, error.message ?: "error")
                    }
                },
            ).join()
        return object : RawSocket {
            override fun sendBinary(bytes: ByteArray) {
                ws.sendBinary(ByteBuffer.wrap(bytes), true)
            }

            override fun close() {
                try {
                    ws.sendClose(WebSocket.NORMAL_CLOSURE, "bye")
                } catch (_: Throwable) {
                }
            }
        }
    }
}
