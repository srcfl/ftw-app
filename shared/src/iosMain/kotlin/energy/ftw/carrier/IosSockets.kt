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
import platform.posix.memcpy

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
                val code = task.closeCode.toInt()
                val reasonBytes = task.closeReason
                val reason = if (reasonBytes != null && reasonBytes.length.toInt() > 0) {
                    nsDataToBytes(reasonBytes).decodeToString()
                } else {
                    error.localizedDescription
                }
                listener.onClose(if (code == 0) 1006 else code, reason)
                return@receiveMessageWithCompletionHandler
            }
            val text = message?.string
            val data = message?.data
            if (text != null) listener.onText(text)
            if (data != null) {
                listener.onBinary(nsDataToBytes(data))
            }
            receive(task, listener)
        }
    }
}

@OptIn(ExperimentalForeignApi::class)
private fun nsDataToBytes(data: NSData): ByteArray {
    val n = data.length.toInt()
    if (n == 0) return ByteArray(0)
    val out = ByteArray(n)
    out.usePinned { pinned ->
        memcpy(pinned.addressOf(0), data.bytes, n.convert())
    }
    return out
}
