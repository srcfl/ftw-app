package energy.ftw.carrier

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.convert
import kotlinx.cinterop.usePinned
import platform.Foundation.NSData
import platform.Foundation.NSMutableURLRequest
import platform.Foundation.NSURL
import platform.Foundation.NSURLSession
import platform.Foundation.NSURLSessionWebSocketMessage
import platform.Foundation.NSURLSessionWebSocketTask
import platform.Foundation.dataWithBytes
import platform.darwin.dispatch_async
import platform.darwin.dispatch_get_main_queue

@OptIn(ExperimentalForeignApi::class)
class IosSockets : SocketFactory {
    override fun open(url: String, listener: SocketListener): RawSocket {
        val nsUrl = NSURL.URLWithString(url) ?: error("bad url")
        val request = NSMutableURLRequest.requestWithURL(nsUrl)
        val task = NSURLSession.sharedSession.webSocketTaskWithRequest(request)
        val handle = object : RawSocket {
            override fun sendBinary(bytes: ByteArray) {
                bytes.usePinned { pinned ->
                    val data = NSData.dataWithBytes(pinned.addressOf(0), bytes.size.convert())
                    task.sendMessage(NSURLSessionWebSocketMessage(data)) { _ -> }
                }
            }

            override fun close() {
                task.cancel()
            }
        }
        receive(task, listener)
        task.resume()
        dispatch_async(dispatch_get_main_queue()) { listener.onOpen() }
        return handle
    }

    private fun receive(task: NSURLSessionWebSocketTask, listener: SocketListener) {
        task.receiveMessageWithCompletionHandler { message, error ->
            if (error != null) {
                listener.onClose(1006, error.localizedDescription)
                return@receiveMessageWithCompletionHandler
            }
            val text = message?.string
            val data = message?.data
            if (text != null) listener.onText(text)
            if (data != null) {
                val bytes = ByteArray(data.length.toInt())
                data.bytes?.let { src ->
                    // copy via NSData
                }
                listener.onBinary(nsDataToBytes(data))
            }
            receive(task, listener)
        }
    }
}

@OptIn(ExperimentalForeignApi::class)
private fun nsDataToBytes(data: NSData): ByteArray {
    val n = data.length.toInt()
    val out = ByteArray(n)
    if (n == 0) return out
    val ptr = data.bytes ?: return out
    kotlinx.cinterop.memcpy(out.refTo(0), ptr, n.convert())
    return out
}
